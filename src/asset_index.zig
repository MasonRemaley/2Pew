const indexer = @import("asset_indexer.zig");

pub const Sprite = struct {
    path: []const u8,
    tint: ?struct {
        mask_path: ?[]const u8 = null,
    } = null,
};

pub const Animation = struct {
    frames: []const sprites.Id,
    loop_start: ?u16 = null,
    fps: f32,
    angle: f32,
};

pub const sprites = indexer.index(Sprite, @import("asset_descriptors/sprites.zig").descriptors);
pub const animations = indexer.index(Animation, @import("asset_descriptors/animations.zig").descriptors);
