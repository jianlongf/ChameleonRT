#include <iostream>
#include <vector>
#include <array>
#include <SDL.h>
#include <ospray/ospray.h>
#define TINYOBJLOADER_IMPLEMENTATION
#include "tiny_obj_loader.h"
#include "gl_core_4_5.h"
#include "imgui.h"
#include "imgui_impl_sdl.h"
#include "imgui_impl_opengl3.h"
#include "arcball_camera.h"
#include "shader.h"

const std::string fullscreen_quad_vs = R"(
#version 450 core

const vec4 pos[4] = vec4[4](
	vec4(-1, 1, 0.5, 1),
	vec4(-1, -1, 0.5, 1),
	vec4(1, 1, 0.5, 1),
	vec4(1, -1, 0.5, 1)
);

void main(void){
	gl_Position = pos[gl_VertexID];
}
)";

const std::string display_texture_fs = R"(
#version 450 core

layout(binding=0) uniform sampler2D img;

out vec4 color;

void main(void){ 
	ivec2 uv = ivec2(gl_FragCoord.xy);
	color = texelFetch(img, uv, 0);
})";

void run_app(int argc, const char **argv, SDL_Window *window);

int main(int argc, const char **argv) {
	if (argc < 2) {
		std::cout << "Usage: " << argv[0] << " <obj file>\n";
		return 1;
	}

    if (SDL_Init(SDL_INIT_EVERYTHING) != 0) {
		std::cerr << "Failed to init SDL: " << SDL_GetError() << "\n";
        return -1;
    }

    const char* glsl_version = "#version 450 core";
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 5);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_DEBUG_FLAG);

    // Create window with graphics context
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

    SDL_Window* window = SDL_CreateWindow("rtobj",
			SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 720,
			SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);

    SDL_GLContext gl_context = SDL_GL_CreateContext(window);
    SDL_GL_SetSwapInterval(1);
	SDL_GL_MakeCurrent(window, gl_context);

    if (ogl_LoadFunctions() == ogl_LOAD_FAILED) {
		std::cerr << "Failed to initialize OpenGL\n";
        return 1;
    }

    // Setup Dear ImGui context
    ImGui::CreateContext();

    // Setup Dear ImGui style
    ImGui::StyleColorsDark();

    // Setup Platform/Renderer bindings
    ImGui_ImplSDL2_InitForOpenGL(window, gl_context);
    ImGui_ImplOpenGL3_Init(glsl_version);

	run_app(argc, argv, window);

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();

    SDL_GL_DeleteContext(gl_context);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}

void run_app(int argc, const char **argv, SDL_Window *window) {
    ImGuiIO& io = ImGui::GetIO();

	ArcballCamera camera(glm::vec3(0.f), 100.f, {1280, 720});

	// Load the model w/ tinyobjloader. We just take any OBJ groups etc. stuff
	// that may be in the file and dump them all into a single OBJ model.
	tinyobj::attrib_t attrib;
	std::vector<tinyobj::shape_t> shapes;
	std::vector<tinyobj::material_t> materials;
	std::string err, warn;
	bool ret = tinyobj::LoadObj(&attrib, &shapes, &materials, &warn, &err, argv[1]);
	if (!warn.empty()) {
		std::cout << "Warning loading model: " << warn << "\n";
	}
	if (!err.empty()) {
		std::cerr << "Error loading model: " << err << "\n";
		std::exit(1);
	}
	if (!ret) {
		std::cerr << "Failed to load OBJ model '" << argv[1] << "', aborting\n";
		std::exit(1);
	}

	const std::vector<float> &vertices = attrib.vertices;
	std::vector<int32_t> indices;
	for (size_t s = 0; s < shapes.size(); ++s) {
		const tinyobj::mesh_t &mesh = shapes[s].mesh;
		std::cout << "Loading shape " << shapes[s].name
			<< ", has " << shapes[s].mesh.indices.size() / 3 << " triangles\n";

		for (size_t i = 0; i < mesh.indices.size(); ++i) {
			indices.push_back(mesh.indices[i].vertex_index);
		}
	}

	if (ospInit(&argc, argv) != OSP_NO_ERROR) {
		std::cout << "Failed to init OSPRay\n";
		throw std::runtime_error("Failed to init OSPRay");
	}

	OSPData verts_data = ospNewData(vertices.size() / 3, OSP_FLOAT3, vertices.data());
	ospCommit(verts_data);
	OSPData indices_data = ospNewData(indices.size() / 3, OSP_INT3, indices.data());
	ospCommit(indices_data);

	OSPGeometry geom = ospNewGeometry("triangles");
	ospSetObject(geom, "vertex", verts_data);
	ospSetObject(geom, "index", indices_data);
	ospCommit(geom);

	OSPModel world = ospNewModel();
	ospAddGeometry(world, geom);
	ospCommit(world);

	glm::vec3 cam_pos = camera.eye_pos();
	glm::vec3 cam_dir = camera.eye_dir();
	glm::vec3 cam_up = camera.up_dir();

	OSPCamera osp_camera = ospNewCamera("perspective");
	ospSet1f(osp_camera, "fovy", 65.f);
	ospSet1f(osp_camera, "aspect", 1280.f / 720.f);
	ospSet3fv(osp_camera, "pos", &cam_pos.x);
	ospSet3fv(osp_camera, "dir", &cam_dir.x);
	ospSet3fv(osp_camera, "up", &cam_up.x);
	ospCommit(osp_camera);

	OSPRenderer renderer = ospNewRenderer("raycast_Ns");
	ospSetObject(renderer, "model", world);
	ospSetObject(renderer, "camera", osp_camera);
	ospCommit(renderer);

	OSPFrameBuffer osp_fb = ospNewFrameBuffer(osp::vec2i{1280, 720}, OSP_FB_SRGBA, OSP_FB_COLOR);

	Shader display_render(fullscreen_quad_vs, display_texture_fs);

	GLuint render_texture;
	glGenTextures(1, &render_texture);
	// Setup the render textures for color and normals
	glBindTexture(GL_TEXTURE_2D, render_texture);
	glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 1280, 720);

	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

	GLuint vao;
	glCreateVertexArrays(1, &vao);
	glBindVertexArray(vao);

	glClearColor(0.0, 0.0, 0.0, 0.0);
	glDisable(GL_DEPTH_TEST);

    bool done = false;
    while (!done) {
        // Poll and handle events (inputs, window resize, etc.)
        // You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to
		// tell if dear imgui wants to use your inputs.
        // - When io.WantCaptureMouse is true, do not dispatch mouse input data
		//     to your main application.
        // - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data
		//     to your main application.
        // Generally you may always pass all inputs to dear imgui, and hide them from your
		// application based on those two flags.
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) {
                done = true;
			}
			if (!io.WantCaptureKeyboard && event.type == SDL_KEYDOWN
					&& event.key.keysym.sym == SDLK_ESCAPE)
			{
				done = true;
			}
            if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE
					&& event.window.windowID == SDL_GetWindowID(window)) {
				done = true;
			}
			if (!io.WantCaptureMouse && (event.type == SDL_MOUSEMOTION || event.type == SDL_MOUSEWHEEL)) {
				camera.mouse(event, 0.016f);
			}
        }

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame(window);
        ImGui::NewFrame();

		ImGui::Begin("Debug Panel");
		ImGui::Text("Application average %.3f ms/frame (%.1f FPS)",
				1000.0f / ImGui::GetIO().Framerate, ImGui::GetIO().Framerate);
		ImGui::End();

        // Rendering
        ImGui::Render();
        glViewport(0, 0, (int)io.DisplaySize.x, (int)io.DisplaySize.y);

		cam_pos = camera.eye_pos();
		cam_dir = camera.eye_dir();
		cam_up = camera.up_dir();

		ospSet3fv(osp_camera, "pos", &cam_pos.x);
		ospSet3fv(osp_camera, "dir", &cam_dir.x);
		ospSet3fv(osp_camera, "up", &cam_up.x);
		ospCommit(osp_camera);

		ospSetObject(renderer, "camera", osp_camera);
		ospCommit(renderer);

		ospFrameBufferClear(osp_fb, OSP_FB_COLOR);
		ospRenderFrame(osp_fb, renderer, OSP_FB_COLOR);

		const uint32_t *fb = static_cast<const uint32_t*>(ospMapFrameBuffer(osp_fb, OSP_FB_COLOR));
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1280, 720, GL_RGBA,
				GL_UNSIGNED_BYTE, fb);
		ospUnmapFrameBuffer(fb, osp_fb);

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glUseProgram(display_render.program);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

        SDL_GL_SwapWindow(window);
    }
}

