#include "render_metal.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <Metal/Metal.h>
#include "metalrt_utils.h"
#include "render_metal_embedded_metallib.h"
#include "shader_types.h"
#include "util.h"
#include <glm/ext.hpp>

RenderMetal::RenderMetal()
{
    context = std::make_shared<metal::Context>();

    std::cout << "Selected Metal device " << context->device_name() << "\n";

    shader_library = std::make_shared<metal::ShaderLibrary>(
        *context, render_metal_metallib, sizeof(render_metal_metallib));

    // Setup the compute pipeline
    pipeline = std::make_shared<metal::ComputePipeline>(
        *context, shader_library->new_function(@"raygen"));
}

std::string RenderMetal::name()
{
    return "Metal Ray Tracing";
}

void RenderMetal::initialize(const int fb_width, const int fb_height)
{
    frame_id = 0;
    img.resize(fb_width * fb_height);

    render_target = std::make_shared<metal::Texture2D>(*context,
                                                       fb_width,
                                                       fb_height,
                                                       MTLPixelFormatRGBA8Unorm_sRGB,
                                                       MTLTextureUsageShaderWrite);
}

void RenderMetal::set_scene(const Scene &scene)
{
    // Create a heap to hold all the data we'll need to upload
    data_heap = allocate_heap(scene);
    std::cout << "Data heap size: " << pretty_print_count(data_heap->size()) << "b\n";

    // Upload the geometry for each mesh and build its BLAS
    std::vector<std::shared_ptr<metal::BottomLevelBVH>> meshes = build_meshes(scene);

    bvh = std::make_shared<metal::TopLevelBVH>(scene.instances, meshes);
    {
        id<MTLCommandBuffer> command_buffer = context->command_buffer();
        id<MTLAccelerationStructureCommandEncoder> command_encoder =
            [command_buffer accelerationStructureCommandEncoder];

        bvh->enqueue_build(*context, command_encoder);

        [command_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        [command_encoder release];
        [command_buffer release];

        command_buffer = context->command_buffer();
        command_encoder = [command_buffer accelerationStructureCommandEncoder];

        bvh->enqueue_compaction(*context, command_encoder);

        [command_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        [command_encoder release];
        [command_buffer release];
    }

    // Upload the instance material id buffers to the heap
    for (const auto &i : scene.instances) {
        metal::Buffer upload(
            *context, sizeof(uint32_t) * i.material_ids.size(), MTLResourceStorageModeManaged);
        std::memcpy(upload.data(), i.material_ids.data(), upload.size());
        upload.mark_modified();

        auto material_id_buffer = std::make_shared<metal::Buffer>(
            *data_heap, upload.size(), MTLResourceStorageModePrivate);

        id<MTLCommandBuffer> command_buffer = context->command_buffer();
        id<MTLBlitCommandEncoder> blit_encoder = command_buffer.blitCommandEncoder;

        [blit_encoder copyFromBuffer:upload.buffer
                        sourceOffset:0
                            toBuffer:material_id_buffer->buffer
                   destinationOffset:0
                                size:material_id_buffer->size()];

        [blit_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];

        [command_buffer release];

        instance_material_ids.push_back(material_id_buffer);
    }

    // Build the argument buffer for the instance. Each instance is passed its
    // inverse object transform (not provided by Metal), and a buffer of material IDs
    // for each of its mesh's geometries
    metal::ArgumentEncoderBuilder instance_args_encoder_builder(*context);
    instance_args_encoder_builder.add_constant(0, MTLDataTypeFloat4x4)
        .add_buffer(1, MTLArgumentAccessReadOnly);
    const size_t instance_args_size = instance_args_encoder_builder.encoded_length();

    instance_args_buffer = std::make_shared<metal::Buffer>(
        *context, scene.instances.size() * instance_args_size, MTLResourceStorageModeManaged);

    size_t instance_args_offset = 0;
    for (size_t i = 0; i < scene.instances.size(); ++i) {
        auto encoder = instance_args_encoder_builder.encoder_for_buffer(*instance_args_buffer,
                                                                        instance_args_offset);
        glm::mat4 *inverse_tfm = reinterpret_cast<glm::mat4 *>(encoder->constant_data_at(0));
        *inverse_tfm = glm::inverse(scene.instances[i].transform);

        encoder->set_buffer(*instance_material_ids[i], 0, 1);

        instance_args_offset += instance_args_size;
    }
    instance_args_buffer->mark_modified();

    // Upload the material data
    material_buffer = std::make_shared<metal::Buffer>(
        *context, sizeof(glm::vec3) * scene.materials.size(), MTLResourceStorageModeManaged);
    glm::vec3 *material_colors = reinterpret_cast<glm::vec3 *>(material_buffer->data());
    for (size_t i = 0; i < scene.materials.size(); ++i) {
        material_colors[i] = scene.materials[i].base_color;
    }
    material_buffer->mark_modified();

    textures = upload_textures(scene.textures);

    // Pass the handles of the textures through an argument buffer
    metal::ArgumentEncoderBuilder tex_args_encoder_builder(*context);
    tex_args_encoder_builder.add_texture(0, MTLArgumentAccessReadOnly);
    const size_t tex_args_size = tex_args_encoder_builder.encoded_length();

    texture_arg_buffer = std::make_shared<metal::Buffer>(
        *context, tex_args_size * textures.size(), MTLResourceStorageModeManaged);

    size_t tex_args_offset = 0;
    for (const auto &t : textures) {
        auto encoder =
            tex_args_encoder_builder.encoder_for_buffer(*texture_arg_buffer, tex_args_offset);
        encoder->set_texture(*t, 0);
        tex_args_offset += tex_args_size;
    }
    texture_arg_buffer->mark_modified();
}

RenderStats RenderMetal::render(const glm::vec3 &pos,
                                const glm::vec3 &dir,
                                const glm::vec3 &up,
                                const float fovy,
                                const bool camera_changed,
                                const bool readback_framebuffer)
{
    using namespace std::chrono;
    RenderStats stats;

    if (camera_changed) {
        frame_id = 0;
    }

    ViewParams view_params = compute_view_parameters(pos, dir, up, fovy);

    auto start = high_resolution_clock::now();
    id<MTLCommandBuffer> command_buffer = context->command_buffer();
    id<MTLComputeCommandEncoder> command_encoder = [command_buffer computeCommandEncoder];

    [command_encoder setTexture:render_target->texture atIndex:0];

    // Embed the view params in the command buffer
    [command_encoder setBytes:&view_params length:sizeof(ViewParams) atIndex:0];

    [command_encoder setAccelerationStructure:bvh->bvh atBufferIndex:1];
    // Also mark all BLAS's used
    // TODO: Seems like we can't do a similar heap thing for the BLAS's to mark
    // them all used at once?
    // It does seem like this isn't the main cause of the perf impact I see on
    // San Miguel with many BLAS's vs. not
    for (auto &mesh : bvh->meshes) {
        [command_encoder useResource:mesh->bvh usage:MTLResourceUsageRead];
    }

    [command_encoder setBuffer:geometry_args_buffer->buffer offset:0 atIndex:2];
    [command_encoder setBuffer:mesh_args_buffer->buffer offset:0 atIndex:3];
    [command_encoder useHeap:data_heap->heap];

    [command_encoder setBuffer:bvh->instance_buffer->buffer offset:0 atIndex:4];
    [command_encoder setBuffer:instance_args_buffer->buffer offset:0 atIndex:5];
    [command_encoder setBuffer:material_buffer->buffer offset:0 atIndex:6];
    [command_encoder setBuffer:texture_arg_buffer->buffer offset:0 atIndex:7];

    [command_encoder setComputePipelineState:pipeline->pipeline];

    // Use Metal's non-uniform dispatch support to divide up into 16x16 thread groups
    const glm::uvec2 fb_dims = render_target->dims();
    [command_encoder dispatchThreads:MTLSizeMake(fb_dims.x, fb_dims.y, 1)
               threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];

    [command_encoder endEncoding];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    auto end = high_resolution_clock::now();
    stats.render_time = duration_cast<nanoseconds>(end - start).count() * 1.0e-6;

    if (readback_framebuffer || !native_display) {
        render_target->readback(img.data());
    }

    [command_encoder release];
    [command_buffer release];

    ++frame_id;
    return stats;
}

ViewParams RenderMetal::compute_view_parameters(const glm::vec3 &pos,
                                                const glm::vec3 &dir,
                                                const glm::vec3 &up,
                                                const float fovy)
{
    const glm::uvec2 fb_dims = render_target->dims();
    glm::vec2 img_plane_size;
    img_plane_size.y = 2.f * std::tan(glm::radians(0.5f * fovy));
    img_plane_size.x = img_plane_size.y * static_cast<float>(fb_dims.x) / fb_dims.y;

    const glm::vec3 dir_du = glm::normalize(glm::cross(dir, up)) * img_plane_size.x;
    const glm::vec3 dir_dv = -glm::normalize(glm::cross(dir_du, dir)) * img_plane_size.y;
    const glm::vec3 dir_top_left = dir - 0.5f * dir_du - 0.5f * dir_dv;

    ViewParams view_params;
    view_params.cam_pos = simd::float4{pos.x, pos.y, pos.z, 1.f};
    view_params.cam_du = simd::float4{dir_du.x, dir_du.y, dir_du.z, 0.f};
    view_params.cam_dv = simd::float4{dir_dv.x, dir_dv.y, dir_dv.z, 0.f};
    view_params.cam_dir_top_left =
        simd::float4{dir_top_left.x, dir_top_left.y, dir_top_left.z, 0.f};
    view_params.fb_dims = simd::uint2{fb_dims.x, fb_dims.y};
    view_params.frame_id = frame_id;

    return view_params;
}

std::shared_ptr<metal::Heap> RenderMetal::allocate_heap(const Scene &scene)
{
    metal::HeapBuilder heap_builder(*context);
    // Allocate enough room to store the data for each mesh
    for (const auto &m : scene.meshes) {
        // Also get enough space to store the mesh's gometry indices buffer
        heap_builder.add_buffer(sizeof(uint32_t) * m.geometries.size(),
                                MTLResourceStorageModePrivate);

        for (const auto &g : m.geometries) {
            heap_builder
                .add_buffer(sizeof(glm::vec3) * g.vertices.size(),
                            MTLResourceStorageModePrivate)
                .add_buffer(sizeof(glm::uvec3) * g.indices.size(),
                            MTLResourceStorageModePrivate);
            if (!g.normals.empty()) {
                heap_builder.add_buffer(sizeof(glm::vec3) * g.normals.size(),
                                        MTLResourceStorageModePrivate);
            }
            if (!g.uvs.empty()) {
                heap_builder.add_buffer(sizeof(glm::vec2) * g.uvs.size(),
                                        MTLResourceStorageModePrivate);
            }
        }
    }

    // Allocate room for the instance's material ID lists
    for (const auto &i : scene.instances) {
        heap_builder.add_buffer(sizeof(uint32_t) * i.material_ids.size(),
                                MTLResourceStorageModePrivate);
    }

    // Reserve space for the texture data in the heap
    for (const auto &t : scene.textures) {
        MTLPixelFormat format =
            t.color_space == LINEAR ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA8Unorm_sRGB;
        heap_builder.add_texture2d(t.width, t.height, format, MTLTextureUsageShaderRead);
    }

    return heap_builder.build();
}

std::vector<std::shared_ptr<metal::BottomLevelBVH>> RenderMetal::build_meshes(
    const Scene &scene)
{
    // We also need to build a list of global geometry indices for each mesh, since
    // all the geometry info will be flattened into a single buffer
    uint32_t total_geometries = 0;
    std::vector<std::shared_ptr<metal::BottomLevelBVH>> meshes;

    for (const auto &m : scene.meshes) {
        // Upload the mesh geometry ids first
        std::shared_ptr<metal::Buffer> geom_id_buffer;
        {
            metal::Buffer geom_id_upload(*context,
                                         sizeof(uint32_t) * m.geometries.size(),
                                         MTLResourceStorageModeManaged);
            uint32_t *geom_ids = reinterpret_cast<uint32_t *>(geom_id_upload.data());
            for (uint32_t i = 0; i < m.geometries.size(); ++i) {
                geom_ids[i] = total_geometries++;
            }
            geom_id_upload.mark_modified();

            geom_id_buffer = std::make_shared<metal::Buffer>(
                *data_heap, geom_id_upload.size(), MTLResourceStorageModePrivate);

            id<MTLCommandBuffer> command_buffer = context->command_buffer();
            id<MTLBlitCommandEncoder> blit_encoder = command_buffer.blitCommandEncoder;

            [blit_encoder copyFromBuffer:geom_id_upload.buffer
                            sourceOffset:0
                                toBuffer:geom_id_buffer->buffer
                       destinationOffset:0
                                    size:geom_id_buffer->size()];

            [blit_encoder endEncoding];
            [command_buffer commit];
            [command_buffer waitUntilCompleted];

            [command_buffer release];
        }

        std::vector<metal::Geometry> geometries;
        for (const auto &g : m.geometries) {
            metal::Buffer vertex_upload(*context,
                                        sizeof(glm::vec3) * g.vertices.size(),
                                        MTLResourceStorageModeManaged);

            std::memcpy(vertex_upload.data(), g.vertices.data(), vertex_upload.size());
            vertex_upload.mark_modified();

            metal::Buffer index_upload(*context,
                                       sizeof(glm::uvec3) * g.indices.size(),
                                       MTLResourceStorageModeManaged);
            std::memcpy(index_upload.data(), g.indices.data(), index_upload.size());
            index_upload.mark_modified();

            // Allocate the buffers from the heap and copy the data into them
            auto vertex_buffer = std::make_shared<metal::Buffer>(
                *data_heap, vertex_upload.size(), MTLResourceStorageModePrivate);

            auto index_buffer = std::make_shared<metal::Buffer>(
                *data_heap, index_upload.size(), MTLResourceStorageModePrivate);

            std::shared_ptr<metal::Buffer> normal_upload = nullptr;
            std::shared_ptr<metal::Buffer> normal_buffer = nullptr;
            if (!g.normals.empty()) {
                normal_upload =
                    std::make_shared<metal::Buffer>(*context,
                                                    sizeof(glm::vec3) * g.normals.size(),
                                                    MTLResourceStorageModeManaged);
                std::memcpy(normal_upload->data(), g.normals.data(), normal_upload->size());
                normal_upload->mark_modified();

                normal_buffer = std::make_shared<metal::Buffer>(
                    *data_heap, normal_upload->size(), MTLResourceStorageModePrivate);
            }

            std::shared_ptr<metal::Buffer> uv_upload = nullptr;
            std::shared_ptr<metal::Buffer> uv_buffer = nullptr;
            if (!g.uvs.empty()) {
                uv_upload = std::make_shared<metal::Buffer>(
                    *context, sizeof(glm::vec2) * g.uvs.size(), MTLResourceStorageModeManaged);
                std::memcpy(uv_upload->data(), g.uvs.data(), uv_upload->size());
                uv_upload->mark_modified();

                uv_buffer = std::make_shared<metal::Buffer>(
                    *data_heap, uv_upload->size(), MTLResourceStorageModePrivate);
            }

            id<MTLCommandBuffer> command_buffer = context->command_buffer();
            id<MTLBlitCommandEncoder> blit_encoder = command_buffer.blitCommandEncoder;

            [blit_encoder copyFromBuffer:vertex_upload.buffer
                            sourceOffset:0
                                toBuffer:vertex_buffer->buffer
                       destinationOffset:0
                                    size:vertex_buffer->size()];

            [blit_encoder copyFromBuffer:index_upload.buffer
                            sourceOffset:0
                                toBuffer:index_buffer->buffer
                       destinationOffset:0
                                    size:index_buffer->size()];

            if (normal_upload) {
                [blit_encoder copyFromBuffer:normal_upload->buffer
                                sourceOffset:0
                                    toBuffer:normal_buffer->buffer
                           destinationOffset:0
                                        size:normal_buffer->size()];
            }

            if (uv_upload) {
                [blit_encoder copyFromBuffer:uv_upload->buffer
                                sourceOffset:0
                                    toBuffer:uv_buffer->buffer
                           destinationOffset:0
                                        size:uv_buffer->size()];
            }

            [blit_encoder endEncoding];
            [command_buffer commit];
            [command_buffer waitUntilCompleted];

            [command_buffer release];

            geometries.emplace_back(vertex_buffer, index_buffer, normal_buffer, uv_buffer);
        }

        // Build the BLAS
        auto mesh = std::make_shared<metal::BottomLevelBVH>(geometries, geom_id_buffer);
        id<MTLCommandBuffer> command_buffer = context->command_buffer();
        id<MTLAccelerationStructureCommandEncoder> command_encoder =
            [command_buffer accelerationStructureCommandEncoder];

        mesh->enqueue_build(*context, command_encoder);

        [command_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        [command_encoder release];
        [command_buffer release];

        command_buffer = context->command_buffer();
        command_encoder = [command_buffer accelerationStructureCommandEncoder];

        mesh->enqueue_compaction(*context, command_encoder);

        [command_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        [command_encoder release];
        [command_buffer release];

        meshes.push_back(mesh);
    }

    // Build the argument buffer for the mesh geometry IDs
    metal::ArgumentEncoderBuilder mesh_args_encoder_builder(*context);
    mesh_args_encoder_builder.add_buffer(0, MTLArgumentAccessReadOnly);

    const uint32_t mesh_args_size = mesh_args_encoder_builder.encoded_length();
    mesh_args_buffer = std::make_shared<metal::Buffer>(
        *context, mesh_args_size * meshes.size(), MTLResourceStorageModeManaged);

    // Build the argument buffer for each geometry
    metal::ArgumentEncoderBuilder geom_args_encoder_builder(*context);
    geom_args_encoder_builder.add_buffer(0, MTLArgumentAccessReadOnly)
        .add_buffer(1, MTLArgumentAccessReadOnly)
        .add_buffer(2, MTLArgumentAccessReadOnly)
        .add_buffer(3, MTLArgumentAccessReadOnly)
        .add_constant(4, MTLDataTypeUInt)
        .add_constant(5, MTLDataTypeUInt);

    const uint32_t geom_args_size = geom_args_encoder_builder.encoded_length();
    geometry_args_buffer = std::make_shared<metal::Buffer>(
        *context, geom_args_size * total_geometries, MTLResourceStorageModeManaged);

    // Write the geometry arguments to the buffer
    size_t mesh_args_offset = 0;
    size_t geom_args_offset = 0;
    for (const auto &m : meshes) {
        // Write the mesh geometry ID buffer
        {
            auto encoder = mesh_args_encoder_builder.encoder_for_buffer(*mesh_args_buffer,
                                                                        mesh_args_offset);
            encoder->set_buffer(*m->geometry_id_buffer, 0, 0);
            mesh_args_offset += mesh_args_size;
        }

        // Write the geometry data arguments
        for (const auto &g : m->geometries) {
            auto encoder = geom_args_encoder_builder.encoder_for_buffer(*geometry_args_buffer,
                                                                        geom_args_offset);
            encoder->set_buffer(*g.vertex_buf, 0, 0);
            encoder->set_buffer(*g.index_buf, 0, 1);

            uint32_t *num_normals = reinterpret_cast<uint32_t *>(encoder->constant_data_at(4));
            if (g.normal_buf) {
                encoder->set_buffer(*g.normal_buf, 0, 2);
                *num_normals = g.normal_buf->size() / sizeof(glm::vec3);
            } else {
                *num_normals = 0;
            }

            uint32_t *num_uvs = reinterpret_cast<uint32_t *>(encoder->constant_data_at(5));
            if (g.uv_buf) {
                encoder->set_buffer(*g.uv_buf, 0, 3);
                *num_uvs = g.uv_buf->size() / sizeof(glm::vec2);
            } else {
                *num_uvs = 0;
            }

            geom_args_offset += geom_args_size;
        }
    }
    mesh_args_buffer->mark_modified();
    geometry_args_buffer->mark_modified();

    return meshes;
}

std::vector<std::shared_ptr<metal::Texture2D>> RenderMetal::upload_textures(
    const std::vector<Image> &textures)
{
    std::vector<std::shared_ptr<metal::Texture2D>> uploaded_textures;
    for (const auto &t : textures) {
        const MTLPixelFormat format =
            t.color_space == LINEAR ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA8Unorm_sRGB;

        metal::Texture2D upload(
            *context, t.width, t.height, format, MTLTextureUsageShaderRead);
        upload.upload(t.img.data());

        // Allocate a texture from the heap and copy into it
        auto heap_tex = std::make_shared<metal::Texture2D>(
            *data_heap, t.width, t.height, format, MTLTextureUsageShaderRead);

        id<MTLCommandBuffer> command_buffer = context->command_buffer();
        id<MTLBlitCommandEncoder> blit_encoder = command_buffer.blitCommandEncoder;

        [blit_encoder copyFromTexture:upload.texture toTexture:heap_tex->texture];

        [blit_encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        [command_buffer release];

        uploaded_textures.push_back(heap_tex);
    }
    return uploaded_textures;
}

