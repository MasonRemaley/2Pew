const builtin = @import("builtin");
const std = @import("std");
const gpu = @import("gpu");
const geom = @import("zcs").ext.geom;
const tracy = @import("tracy");
const c = @import("c.zig");

const DeleteQueue = gpu.ext.DeleteQueue;
const ImageBumpAllocator = gpu.ext.ImageBumpAllocator;
const bufPart = gpu.ext.bufPart;

const Gx = gpu.Gx;
const Memory = gpu.Memory;
const UploadBuf = gpu.UploadBuf;
const ImageUploadQueue = gpu.ext.ImageUploadQueue;
const Mat2x3 = geom.Mat2x3;
const Zone = tracy.Zone;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

delete_queues: [gpu.global_options.max_frames_in_flight]DeleteQueue(8),

color_image_allocator: ImageBumpAllocator(.color),

textures: std.ArrayListUnmanaged(gpu.Image(.color)),

pipeline: gpu.Pipeline,
pipeline_layout: gpu.Pipeline.Layout,
desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet,
desc_pool: gpu.DescPool,

storage_buf: UploadBuf(.{ .storage = true }),

texture_sampler: gpu.Sampler,

sprites: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View,
scene: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View,

pub const max_textures = b: {
    const n = 16384;
    assert(n < @intFromEnum(ubo.Texture.none));
    break :b n;
};
pub const image_mibs = 16;

pub const mib = std.math.pow(u64, 2, 20);

pub const ubo = struct {
    pub const Color = extern struct {
        pub const white: @This() = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
        a: u8,
        b: u8,
        g: u8,
        r: u8,
    };

    pub const Texture = enum(u16) {
        none = std.math.maxInt(u16),
        _,
    };

    pub const Scene = extern struct {
        view_from_world: Mat2x3 = .identity,
    };

    pub const Instance = extern struct {
        world_from_model: Mat2x3,
        diffuse: Texture = .none,
        recolor: Texture = .none,
        color: Color = .white,
    };
};

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
            .stages = .{ .vertex = true },
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

pub fn init(gpa: Allocator, gx: *Gx) @This() {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    const color_image_allocator = ImageBumpAllocator(.color).init(gpa, gx, .{
        .name = "Color Images",
    }) catch |err| @panic(@errorName(err));

    const sprite_vert_spv = initSpv(gpa, "data/shaders/entity.vert.spv");
    defer gpa.free(sprite_vert_spv);
    const sprite_vert_module: gpu.ShaderModule = .init(gx, .{
        .name = .{ .str = "entity.vert.spv" },
        .ir = sprite_vert_spv,
    });
    defer sprite_vert_module.deinit(gx);

    const sprite_frag_spv = initSpv(gpa, "data/shaders/entity.frag.spv");
    defer gpa.free(sprite_frag_spv);
    const sprite_frag_module: gpu.ShaderModule = .init(gx, .{
        .name = .{ .str = "entity.frag.spv" },
        .ir = sprite_frag_spv,
    });
    defer sprite_frag_module.deinit(gx);

    const pipeline_layout: gpu.Pipeline.Layout = .init(gx, pipeline_layout_options);

    var pipeline: gpu.Pipeline = undefined;
    gpu.Pipeline.initGraphics(gx, &.{
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
    const desc_pool: gpu.DescPool = .init(gx, .{
        .name = .{ .str = "Game" },
        .cmds = create_descs.constSlice(),
    });

    var scene: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View = undefined;
    var sprites: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View = undefined;
    const storage_buf = bufPart(gx, UploadBuf(.{ .storage = true }), .{
        .buf = .{
            .name = .{ .str = "Storage" },
            .prefer_device_local = false,
        },
        .frame = &.{
            .init(ubo.Scene, &scene),
            .init([max_textures]ubo.Instance, &sprites),
        },
    });

    const texture_sampler: gpu.Sampler = .init(gx, .{ .str = "Texture" }, .{
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

    const textures = std.ArrayListUnmanaged(gpu.Image(.color)).initCapacity(
        gpa,
        max_textures,
    ) catch @panic("OOM");

    return .{
        .delete_queues = @splat(.{}),
        .color_image_allocator = color_image_allocator,
        .textures = textures,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .desc_sets = desc_sets,
        .desc_pool = desc_pool,
        .storage_buf = storage_buf,
        .texture_sampler = texture_sampler,
        .scene = scene,
        .sprites = sprites,
    };
}

pub fn deinit(self: *@This(), gpa: Allocator, gx: *Gx) void {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    for (&self.delete_queues) |*dq| dq.reset(gx);

    for (self.textures.items) |*t| t.deinit(gx);
    self.textures.deinit(gpa);

    self.pipeline_layout.deinit(gx);
    self.pipeline.deinit(gx);

    self.desc_pool.deinit(gx);
    self.storage_buf.deinit(gx);
    self.texture_sampler.deinit(gx);

    self.color_image_allocator.deinit(gpa, gx);
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

pub fn beginFrame(self: *@This(), gx: *Gx) void {
    gx.beginFrame();
    self.delete_queues[gx.frame].reset(gx);
}

const LoadTextureResult = struct {
    width: u16,
    height: u16,
    texture: ubo.Texture,
};

const TextureFormat = enum(i32) {
    r8g8b8a8_srgb = @intFromEnum(gpu.ImageFormat.r8g8b8a8_srgb),
    r8_unorm = @intFromEnum(gpu.ImageFormat.r8_unorm),

    pub fn asGpuFormat(self: @This()) gpu.ImageFormat {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn channels(self: @This()) u8 {
        return switch (self) {
            .r8g8b8a8_srgb => 4,
            .r8_unorm => 1,
        };
    }
};

pub fn loadTexture(
    self: *@This(),
    gpa: Allocator,
    gx: *Gx,
    cb: gpu.CmdBuf,
    up: *ImageUploadQueue,
    format: TextureFormat,
    dir: std.fs.Dir,
    name: [:0]const u8,
) LoadTextureResult {
    assert(self.textures.items.len < @intFromEnum(ubo.Texture.none));
    const handle: ubo.Texture = @enumFromInt(self.textures.items.len);

    const diffuse_png = dir.readFileAlloc(gpa, name, 50 * 1024 * 1024) catch |err|
        @panic(@errorName(err));
    defer gpa.free(diffuse_png);

    var width: c_int = undefined;
    var height: c_int = undefined;
    const c_pixels = c.stbi_load_from_memory(
        diffuse_png.ptr,
        @intCast(diffuse_png.len),
        &width,
        &height,
        null,
        format.channels(),
    );
    defer c.stbi_image_free(c_pixels);
    const pixels = c_pixels[0..@intCast(width * height * format.channels())];

    self.textures.appendAssumeCapacity(up.beginWrite(gx, cb, &self.color_image_allocator, .{
        .name = .{ .str = name },
        .image = .{
            .format = format.asGpuFormat(),
            .extent = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            },
            .usage = .{
                .transfer_dst = true,
                .sampled = true,
            },
        },
    }));

    up.writer.writeAll(pixels);

    return .{
        .texture = handle,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}
