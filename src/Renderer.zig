const builtin = @import("builtin");
const std = @import("std");
const gpu = @import("gpu");
const geom = @import("zcs").ext.geom;
const tracy = @import("tracy");
const c = @import("c.zig").c;
const Game = @import("Game.zig");
pub const interface = @cImport({
    @cInclude("shaders/interface.glsl");
    @cInclude("shaders/box_blur_moving_avg.comp.glsl");
    @cInclude("shaders/linear_convolve.comp.glsl");
    @cInclude("shaders/composite.comp.glsl");
});

const DeleteQueue = gpu.ext.DeleteQueue;
const ImageBumpAllocator = gpu.ext.ImageBumpAllocator;
const bufPart = gpu.ext.bufPart;
const ModTimer = gpu.ext.ModTimer;

const Gx = gpu.Gx;
const Memory = gpu.Memory;
const UploadBuf = gpu.UploadBuf;
const ImageUploadQueue = gpu.ext.ImageUploadQueue;
const RenderTarget = gpu.ext.RenderTarget;
const Mat2x3 = geom.Mat2x3;
const Vec2 = geom.Vec2;
const Zone = tracy.Zone;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

delete_queues: [gpu.global_options.max_frames_in_flight]DeleteQueue(8),

color_image_allocator: ImageBumpAllocator(.color),

textures: std.ArrayListUnmanaged(gpu.Image(.color)),

pipelines: Pipelines,
pipeline_layout: gpu.Pipeline.Layout,
desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet,
desc_pool: gpu.DescPool,
rtp: RenderTarget(.color).Pool,
moving_avg_blur: bool = false,

storage_buf: UploadBuf(.{ .storage = true }),

sampler: gpu.Sampler,

entities: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View,
scene: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View,

pub const max_render_entities = 100000;
pub const max_textures = b: {
    // https://docs.vulkan.org/spec/latest/appendices/roadmap.html
    // If using animations, consider creating texture arrays to avoid hitting this limit
    const n = 128;
    assert(n < @intFromEnum(ubo.Texture.none));
    break :b n;
};
pub const image_mibs = 16;

pub const max_render_targets = interface.i_max_render_targets;

pub const mib = std.math.pow(u64, 2, 20);

pub const ubo = struct {
    pub const Color = extern struct {
        pub const white: @This() = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    pub const Texture = enum(u16) {
        none = std.math.maxInt(u16),
        _,

        comptime {
            assert(@intFromEnum(@This().none) == interface.i_tex_none);
        }
    };

    pub const Scene = extern struct {
        view_from_world: Mat2x3,
        projection_from_view: Mat2x3,
        timer: ModTimer,
        mouse: Vec2,

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(interface.Scene));
        }
    };

    pub const Entity = extern struct {
        world_from_model: Mat2x3,
        diffuse: Texture = .none,
        recolor: Texture = .none,
        color: Color = .white,

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(interface.Entity));
        }
    };
};

pub const pipeline_layout_options: gpu.Pipeline.Layout.Options = .{
    .name = .{ .str = "Main" },
    .descs = &.{
        .{
            .name = "scene",
            .kind = .storage_buffer,
            .stages = .{ .vertex = true, .compute = true },
            .partially_bound = false,
        },
        .{
            .name = "entities",
            .kind = .storage_buffer,
            .stages = .{ .vertex = true },
            .partially_bound = false,
        },
        .{
            .name = "textures",
            .kind = .sampled_image,
            .count = max_textures,
            .stages = .{ .fragment = true },
            .partially_bound = true,
        },
        .{
            .name = "linear_sampler",
            .kind = .sampler,
            .stages = .{ .fragment = true, .compute = true },
            .partially_bound = false,
        },
        .{
            .name = "rt_storage",
            .kind = .storage_image,
            .count = max_render_targets,
            .stages = .{ .compute = true },
            .partially_bound = true,
        },
        .{
            .name = "rt_sampled",
            .kind = .sampled_image,
            .count = max_render_targets,
            .stages = .{ .compute = true },
            .partially_bound = true,
        },
    },
    .push_constant_ranges = &.{
        .{
            .stages = .{ .compute = true },
            .size = @sizeOf(u32) * 32,
        },
    },
};

pub fn init(gpa: Allocator, gx: *Gx, init_window_extent: gpu.Extent2D) @This() {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    const color_image_allocator = ImageBumpAllocator(.color).init(gpa, gx, .{
        .name = "Color Images",
        .initial_pages = 1,
    }) catch |err| @panic(@errorName(err));

    const pipeline_layout: gpu.Pipeline.Layout = .init(gx, pipeline_layout_options);

    var desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet = undefined;
    var create_descs: std.BoundedArray(gpu.DescPool.Options.Cmd, desc_sets.len) = .{};
    for (&desc_sets, 0..) |*desc_set, i| {
        create_descs.appendAssumeCapacity(.{
            .name = .{ .str = "Entities", .index = i },
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
    var entities: [gpu.global_options.max_frames_in_flight]UploadBuf(.{ .storage = true }).View = undefined;
    const storage_buf = bufPart(gx, UploadBuf(.{ .storage = true }), .{
        .buf = .{
            .name = .{ .str = "Storage" },
            .prefer_device_local = false,
        },
        .frame = &.{
            .init(ubo.Scene, &scene),
            .init([max_render_entities]ubo.Entity, &entities),
        },
    });

    const sampler: gpu.Sampler = .init(gx, .{ .str = "Texture" }, .{
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

    const pipelines: Pipelines = .init(
        gpa,
        gx,
        pipeline_layout,
    );

    const rtp = RenderTarget(.color).Pool.init(gpa, gx, .{
        .virtual_extent = .{
            .width = 1920,
            .height = 1080,
        },
        .physical_extent = init_window_extent,
        .capacity = max_render_targets,
        .allocator = .{
            .name = "Render Targets",
            .initial_pages = 0,
        },
    }) catch |err| @panic(@errorName(err));

    return .{
        .delete_queues = @splat(.{}),
        .color_image_allocator = color_image_allocator,
        .textures = textures,
        .pipelines = pipelines,
        .pipeline_layout = pipeline_layout,
        .desc_sets = desc_sets,
        .desc_pool = desc_pool,
        .storage_buf = storage_buf,
        .sampler = sampler,
        .scene = scene,
        .entities = entities,
        .rtp = rtp,
    };
}

pub fn deinit(self: *@This(), gpa: Allocator, gx: *Gx) void {
    const zone: Zone = .begin(.{ .src = @src() });
    defer zone.end();

    for (&self.delete_queues) |*dq| dq.reset(gx);

    for (self.textures.items) |*t| t.deinit(gx);
    self.textures.deinit(gpa);

    self.pipeline_layout.deinit(gx);
    self.pipelines.deinit(gx);

    self.desc_pool.deinit(gx);
    self.storage_buf.deinit(gx);
    self.sampler.deinit(gx);

    self.color_image_allocator.deinit(gpa, gx);

    self.rtp.deinit(gpa, gx);

    self.* = undefined;
}

pub const Pipelines = struct {
    game: gpu.Pipeline,
    linear_convolve: gpu.Pipeline,
    box_blur_moving_avg: gpu.Pipeline,
    composite: gpu.Pipeline,

    pub const color_attachment_format: gpu.ImageFormat = .r8g8b8a8_unorm;

    pub fn init(
        gpa: Allocator,
        gx: *Gx,
        pipeline_layout: gpu.Pipeline.Layout,
    ) Pipelines {
        const ecs_vert_spv = initSpv(gpa, "shaders/ecs.vert.spv");
        defer gpa.free(ecs_vert_spv);
        const ecs_vert_module: gpu.ShaderModule = .init(gx, .{
            .name = .{ .str = "ecs.vert.spv" },
            .ir = ecs_vert_spv,
        });
        defer ecs_vert_module.deinit(gx);

        const ecs_frag_spv = initSpv(gpa, "shaders/ecs.frag.spv");
        defer gpa.free(ecs_frag_spv);
        const sprite_frag_module: gpu.ShaderModule = .init(gx, .{
            .name = .{ .str = "ecs.frag.spv" },
            .ir = ecs_frag_spv,
        });
        defer sprite_frag_module.deinit(gx);

        const post_comp_spv = initSpv(gpa, "shaders/composite.comp.spv");
        defer gpa.free(post_comp_spv);
        const post_comp_module: gpu.ShaderModule = .init(gx, .{
            .name = .{ .str = "composite.comp.spv" },
            .ir = post_comp_spv,
        });
        defer post_comp_module.deinit(gx);

        const blur_separable_spv = initSpv(gpa, "shaders/linear_convolve.comp.spv");
        defer gpa.free(blur_separable_spv);
        const blur_separable_comp_module: gpu.ShaderModule = .init(gx, .{
            .name = .{ .str = "linear_convolve.comp.spv" },
            .ir = blur_separable_spv,
        });
        defer blur_separable_comp_module.deinit(gx);

        const blur_moving_average_spv = initSpv(gpa, "shaders/box_blur_moving_avg.comp.spv");
        defer gpa.free(blur_moving_average_spv);
        const blur_moving_average_comp_module: gpu.ShaderModule = .init(gx, .{
            .name = .{ .str = "linear_convolve.comp.spv" },
            .ir = blur_moving_average_spv,
        });
        defer blur_moving_average_comp_module.deinit(gx);

        var game: gpu.Pipeline = undefined;
        var linear_convolve: gpu.Pipeline = undefined;
        var box_blur_moving_avg: gpu.Pipeline = undefined;
        var composite: gpu.Pipeline = undefined;
        gpu.Pipeline.initGraphics(gx, &.{
            .{
                .name = .{ .str = "Game" },
                .stages = .{
                    .vertex = ecs_vert_module,
                    .fragment = sprite_frag_module,
                },
                .result = &game,
                .input_assembly = .{ .triangle_strip = .{} },
                .layout = pipeline_layout,
                .color_attachment_formats = &.{
                    color_attachment_format,
                },
                .depth_attachment_format = .undefined,
                .stencil_attachment_format = .undefined,
            },
        });

        gpu.Pipeline.initCompute(gx, &.{
            .{
                .name = .{ .str = "Blur Separable" },
                .shader_module = blur_separable_comp_module,
                .result = &linear_convolve,
                .layout = pipeline_layout,
            },
            .{
                .name = .{ .str = "Blur Moving Average" },
                .shader_module = blur_moving_average_comp_module,
                .result = &box_blur_moving_avg,
                .layout = pipeline_layout,
            },
            .{
                .name = .{ .str = "Composite" },
                .shader_module = post_comp_module,
                .result = &composite,
                .layout = pipeline_layout,
            },
        });

        return .{
            .game = game,
            .linear_convolve = linear_convolve,
            .box_blur_moving_avg = box_blur_moving_avg,
            .composite = composite,
        };
    }

    pub fn deinit(self: *@This(), gx: *Gx) void {
        self.game.deinit(gx);
        self.composite.deinit(gx);
        self.linear_convolve.deinit(gx);
        self.box_blur_moving_avg.deinit(gx);
        self.* = undefined;
    }
};

fn initSpv(gpa: Allocator, subpath: []const u8) []const u32 {
    // On most of the platforms we care about we could just use `selfExeDirPathAlloc`, but the SDL
    // call works under wine
    const path = std.fs.path.join(gpa, &.{ std.mem.span(c.SDL_GetBasePath()), "data" }) catch |err|
        @panic(@errorName(err));
    defer gpa.free(path);
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err|
        @panic(@errorName(err));
    defer dir.close();

    const max_bytes = 160384;
    const size_hint = 4096;
    const spv = dir.readFileAllocOptions(
        gpa,
        subpath,
        max_bytes,
        size_hint,
        .of(u32),
        null,
    ) catch |err| std.debug.panic("{s}: {}", .{ subpath, err });
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
