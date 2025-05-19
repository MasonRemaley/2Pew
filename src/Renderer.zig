const std = @import("std");
const gpu = @import("gpu");
const geom = @import("zcs").ext.geom;
const tracy = @import("tracy");

const ImageUploadQueue = @import("ImageUploadQueue.zig");
const BufferLayout = @import("buffer_layout.zig").BufferLayout;

const Gx = gpu.Gx;
const Memory = gpu.Memory;
const Mat2x3 = geom.Mat2x3;
const Zone = tracy.Zone;

const Allocator = std.mem.Allocator;

gx: Gx,

upload_queue: ImageUploadQueue,
color_images: Memory(.color_image),
upload_offset: u64,

pipeline: gpu.Pipeline,
pipeline_layout: gpu.Pipeline.Layout,
desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet,
desc_pool: gpu.DescPool,

storage_layout: StorageLayout,
storage_buf: gpu.UploadBuf(.{ .storage = true }),

texture_sampler: gpu.Sampler,

sprites: [gpu.global_options.max_frames_in_flight]gpu.UploadBuf(.{}).View,
scene: [gpu.global_options.max_frames_in_flight]gpu.UploadBuf(.{}).View,

pub const max_textures = 255;
pub const max_sprites = 16384;
pub const image_mbs = 16;

const mb = std.math.pow(u64, 2, 20);

pub const ubos = struct {
    pub const Scene = extern struct {
        view_from_world: Mat2x3 = .identity,
    };

    pub const Instance = extern struct {
        world_from_model: Mat2x3,
        texture_index: u32,
    };
};

pub const StorageLayout = BufferLayout(.{
    .kind = .{ .storage = true },
    .frame = &.{
        .{
            .name = "scene",
            .size = @sizeOf(ubos.Scene),
            .alignment = @alignOf(ubos.Scene),
        },
        .{
            .name = "instances",
            .size = @sizeOf(ubos.Instance) * max_sprites,
            .alignment = @alignOf(ubos.Instance),
        },
    },
});

pub const pipeline_layout_options: gpu.Pipeline.Layout.Options = .{
    .name = .{ .str = "Game" },
    .descs = &.{
        .{
            .name = "Scene",
            .kind = .storage_buffer,
            .stages = .{ .vertex = true },
            .partially_bound = false,
        },
        .{
            .name = "Instance",
            .kind = .storage_buffer,
            .stages = .{
                .vertex = true,
                .fragment = true,
            },
            .partially_bound = false,
        },
        .{
            .name = "Textures",
            .kind = .combined_image_sampler,
            .count = max_textures,
            .stages = .{ .fragment = true },
            .partially_bound = true,
        },
    },
};

pub fn init(gpa: Allocator, ctx: Gx) @This() {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    // Eventually we'll take this by reference, but it's more convenient to own it while we're
    // maintaining both the SDL and Vulkan renderer simultaneously through the transition
    var gx = ctx;

    const color_images: gpu.Memory(.color_image) = .init(&gx, .{
        .name = .{ .str = "Color Images" },
        .size = image_mbs * mb,
    });

    const upload_queue: ImageUploadQueue = .init(&gx, .{
        .name = .{ .str = "Color Image Upload" },
        .bytes = image_mbs * mb,
    });

    const sprite_vert_spv = initSpv(gpa, "data/shaders/sprite.vert.spv");
    defer gpa.free(sprite_vert_spv);
    const sprite_vert_module: gpu.ShaderModule = .init(&gx, .{
        .name = .{ .str = "sprite.vert.spv" },
        .ir = sprite_vert_spv,
    });
    defer sprite_vert_module.deinit(&gx);

    const sprite_frag_spv = initSpv(gpa, "data/shaders/sprite.frag.spv");
    defer gpa.free(sprite_frag_spv);
    const sprite_frag_module: gpu.ShaderModule = .init(&gx, .{
        .name = .{ .str = "sprite.frag.spv" },
        .ir = sprite_frag_spv,
    });
    defer sprite_frag_module.deinit(&gx);

    const pipeline_layout: gpu.Pipeline.Layout = .init(&gx, pipeline_layout_options);

    var pipeline: gpu.Pipeline = undefined;
    gpu.Pipeline.initGraphics(&gx, &.{
        .{
            .name = .{ .str = "Sprites" },
            .stages = .{
                .vertex = sprite_vert_module,
                .fragment = sprite_frag_module,
            },
            .result = &pipeline,
            .input_assembly = .{ .triangle_strip = .{} },
            .layout = pipeline_layout,
            .color_attachment_formats = &.{
                gx.device.surface_format,
            },
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        },
    });

    var desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet = undefined;
    var create_descs: std.BoundedArray(gpu.DescPool.Options.Cmd, desc_sets.len) = .{};
    for (&desc_sets, 0..) |*desc_set, i| {
        create_descs.appendAssumeCapacity(.{
            .name = .{ .str = "Game", .index = i },
            .result = desc_set,
            .layout = pipeline_layout.desc_set,
            .layout_options = &pipeline_layout_options,
        });
    }
    const desc_pool: gpu.DescPool = .init(&gx, .{
        .name = .{ .str = "Game" },
        .cmds = create_descs.constSlice(),
    });

    const storage_layout: StorageLayout = .init(&gx);
    const storage_buf: gpu.UploadBuf(.{ .storage = true }) = .init(&gx, .{
        .name = .{ .str = "Storage" },
        .size = storage_layout.buffer_size,
        .prefer_device_local = false,
    });

    const texture_sampler: gpu.Sampler = .init(&gx, .{ .str = "Texture" }, .{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode = .initAll(.clamp_to_border),
        .mip_lod_bias = 0.0,
        .max_anisotropy = .@"16",
        .compare_op = null,
        .min_lod = 0.0,
        .max_lod = null,
        .border_color = .int_transparent_black,
    });

    const scene = storage_layout.frameViews(storage_buf, "scene", .{});
    const sprites = storage_layout.frameViews(storage_buf, "instances", .{});

    return .{
        .gx = gx,

        .upload_queue = upload_queue,
        .color_images = color_images,
        .upload_offset = 0,

        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .desc_sets = desc_sets,
        .desc_pool = desc_pool,

        .storage_layout = storage_layout,
        .storage_buf = storage_buf,

        .texture_sampler = texture_sampler,

        .scene = scene,
        .sprites = sprites,
    };
}

pub fn deinit(self: *@This(), gpa: Allocator) void {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    self.pipeline_layout.deinit(&self.gx);
    self.pipeline.deinit(&self.gx);

    self.desc_pool.deinit(&self.gx);
    self.storage_buf.deinit(&self.gx);
    self.texture_sampler.deinit(&self.gx);

    self.upload_queue.deinit(&self.gx);
    self.color_images.deinit(&self.gx);
    self.gx.deinit(gpa);
    self.* = undefined;
}

fn initSpv(gpa: Allocator, path: []const u8) []const u32 {
    const max_bytes = 80192;
    const size_hint = 4096;
    const spv = std.fs.cwd().readFileAllocOptions(
        gpa,
        path,
        max_bytes,
        size_hint,
        .of(u32),
        null,
    ) catch |err| std.debug.panic("{s}: {}", .{ path, err });
    var u32s: []const u32 = undefined;
    u32s.ptr = @ptrCast(spv.ptr);
    u32s.len = spv.len / 4;
    return u32s;
}
