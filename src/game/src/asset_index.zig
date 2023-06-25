const engine = @import("engine");
const indexer = engine.asset_indexer;

pub const Tint = union(enum) {
    none,
    luminosity,
    mask: images.Id,
};

pub const Sprite = struct {
    diffuse: images.Id,
    degrees: f32 = 0.0,
    tint: Tint = .none,
};

// TODO: convert these to radians while baking?
pub const Animation = struct {
    frames: []const sprites.Id,
    loop_start: ?u16 = null,
    fps: f32,
    degrees: f32,
};

// XXX: delete manual decriptors once this works...though actually the index should be going into source I think!! and
// being read/written by the build system etc. can do that as a next step though. it's possible it should actually be jsonfor
// that purpose and then changed to zig after.
// pub const sprites = indexer.index(Sprite, @import("asset_descriptors/sprites.zig").descriptors);
// XXX: file is a weird name for this--also need to make it work now that eveyrthing can be a file but also can
// potentially be imported at comptime as zon
// XXX: also we should verify at build time that all zon is valid even if not loaded immediately
pub const images = indexer.index(.file, @import("image_descriptors").descriptors);
pub const sprites = indexer.index(.file, @import("sprite_descriptors").descriptors);
pub const animations = indexer.index(.file, @import("animation_descriptors").descriptors);
