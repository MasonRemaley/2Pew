const indexer = @import("asset_indexer.zig");

pub const Sprite = struct {
    path: []const u8,
    angle: f32 = 0.0,
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

// XXX: delete manual decriptors once this works...though actually the index should be going into source I think!! and
// being read/written by the build system etc. can do that as a next step though. it's possible it should actually be jsonfor
// that purpose and then changed to zig after.
pub const sprites = indexer.index(Sprite, @import("asset_descriptors/sprites.zig").descriptors);
pub const animations = indexer.index(Animation, @import("asset_descriptors").descriptors);
