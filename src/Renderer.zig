const std = @import("std");
const gpu = @import("gpu");
const geom = @import("zcs").ext.geom;
const ImageUploadQueue = @import("ImageUploadQueue.zig");
const BufferLayout = @import("buffer_layout.zig").BufferLayout;
const Instancer = @import("instancer.zig").Instancer;

const Gx = gpu.Gx;
const Memory = gpu.Memory;
const Mat2x3 = geom.Mat2x3;

const Allocator = std.mem.Allocator;

gx: Gx,
upload_queue: ImageUploadQueue,
color_images: Memory(.color_image),
upload_offset: u64 = 0,

pub const max_textures = 255;
pub const max_sprites = 16384;

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

pub const SpriteRenderer = Instancer(ubos.Instance);

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

pub fn deinit(self: *@This(), gpa: Allocator) void {
    self.upload_queue.deinit(&self.gx);
    self.color_images.deinit(&self.gx);
    self.gx.deinit(gpa);
    self.* = undefined;
}
