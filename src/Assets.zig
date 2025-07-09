const std = @import("std");
const c = @import("c.zig").c;
const gpu = @import("gpu");
const zcs = @import("zcs");
const Renderer = @import("Renderer.zig");

const math = std.math;
const ubo = Renderer.ubo;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Gx = gpu.Gx;
const ImageUploadQueue = gpu.ext.ImageUploadQueue;
const Vec2 = zcs.ext.geom.Vec2;

const Assets = @This();

sprites: std.ArrayListUnmanaged(Sprite),
frames: std.ArrayListUnmanaged(Sprite.Index) = .{},
animations: std.ArrayListUnmanaged(Animation) = .{},

pub const Sprite = struct {
    size: Vec2,
    diffuse: ubo.Texture,
    recolor: ubo.Texture,

    /// Index into the sprites array.
    pub const Index = enum(u16) {
        none = std.math.maxInt(u16),
        _,
    };

    pub fn radius(self: Sprite) f32 {
        return (self.size.x + self.size.y) / 4.0;
    }
};

pub const Animation = struct {
    /// Index into frames array
    start: u32,
    /// Number of frames elements used in this animation.
    len: u32,
    /// After finishing, will jump to this next animation (which may be
    /// itself, in which case it will loop).
    next: Index,
    /// frames per second
    fps: f32,
    angle: f32 = 0.0,

    /// Index into animations array.
    pub const Index = enum(u32) {
        none = math.maxInt(u32),
        _,
    };

    const Frame = struct {
        sprite: Sprite.Index,
        angle: f32,
    };

    pub const Playback = struct {
        index: Index,
        /// number of seconds passed since Animation start.
        time_passed: f32 = 0,
        destroys_entity: bool = false,

        pub fn advance(self: *@This(), assets: *const Assets, delta_s: f32) Animation.Frame {
            const animation = assets.animations.items[@intFromEnum(self.index)];
            const frame_index: u32 = @intFromFloat(@floor(self.time_passed * animation.fps));
            const frame = animation.start + frame_index;
            // TODO: for large delta_s can cause out of bounds index
            self.time_passed += delta_s;
            const end_time = @as(f32, @floatFromInt(animation.len)) / animation.fps;
            if (self.time_passed >= end_time) {
                self.time_passed -= end_time;
                self.index = animation.next;
            }
            return .{
                .sprite = assets.frames.items[frame],
                .angle = animation.angle,
            };
        }
    };
};

pub fn init(gpa: Allocator) Assets {
    return .{
        .sprites = std.ArrayListUnmanaged(Sprite).initCapacity(
            gpa,
            Renderer.max_textures,
        ) catch @panic("OOM"),
    };
}

pub fn deinit(a: *Assets, gpa: Allocator) void {
    a.frames.deinit(gpa);
    a.animations.deinit(gpa);
    a.sprites.deinit(gpa);
    a.* = undefined;
}

/// null next_animation means to loop.
pub fn addAnimation(
    a: *Assets,
    gpa: Allocator,
    frames: []const Sprite.Index,
    next_animation: ?Animation.Index,
    fps: f32,
    angle: f32,
) !Animation.Index {
    try a.frames.appendSlice(gpa, frames);
    const result: Animation.Index = @enumFromInt(a.animations.items.len);
    assert(a.animations.items.len < @intFromEnum(Animation.Index.none));
    try a.animations.append(gpa, .{
        .start = @intCast(a.frames.items.len - frames.len),
        .len = @intCast(frames.len),
        .next = next_animation orelse result,
        .fps = fps,
        .angle = angle,
    });
    return result;
}

pub fn sprite(a: Assets, index: Sprite.Index) Sprite {
    return a.sprites.items[@intFromEnum(index)];
}

fn texture(a: Assets, index: ubo.Texture) gpu.Image(.color) {
    return a.textures.items[@intFromEnum(index)];
}

pub fn loadSprite(
    a: *Assets,
    gpa: Allocator,
    gx: *Gx,
    renderer: *Renderer,
    cb: gpu.CmdBuf,
    up: *ImageUploadQueue,
    dir: std.fs.Dir,
    diffuse_name: [:0]const u8,
    recolor_name: ?[:0]const u8,
) Sprite.Index {
    assert(a.sprites.items.len < @intFromEnum(Sprite.Index.none));
    const handle: Sprite.Index = @enumFromInt(a.sprites.items.len);

    const diffuse = renderer.loadTexture(gpa, gx, cb, up, .r8g8b8a8_srgb, dir, diffuse_name);
    const recolor = if (recolor_name) |name| b: {
        const recolor = renderer.loadTexture(gpa, gx, cb, up, .r8_unorm, dir, name);
        assert(recolor.width == diffuse.width);
        assert(recolor.height == diffuse.height);
        break :b recolor.texture;
    } else .none;
    a.sprites.appendAssumeCapacity(.{
        .size = .{ .x = @floatFromInt(diffuse.width), .y = @floatFromInt(diffuse.height) },
        .diffuse = diffuse.texture,
        .recolor = recolor,
    });
    return handle;
}
