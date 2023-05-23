const engine = @import("engine");
const indexer = engine.asset_indexer;

pub const Sprite = struct {
    diffuse: images.Id,
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
// pub const sprites = indexer.index(Sprite, @import("asset_descriptors/sprites.zig").descriptors);
pub const images = indexer.index(.{ .file = {} }, @import("image_descriptors").descriptors);
pub const sprites = indexer.index(.{ .value = Sprite }, @import("sprite_descriptors").descriptors);
pub const animations = indexer.index(.{ .value = Animation }, @import("animation_descriptors").descriptors);
