const std = @import("std");
const math = std.math;
const sprites = @import("sprites.zig");

const SpriteId = sprites.SpriteId;

// XXX: make loop points for animations?
// XXX: just name id?
pub const AnimationId = enum {
    @"ship/ranger/thrusters/0",
    @"ship/ranger/thrusters/1",
    @"ship/militia/thrusters/0",
    @"ship/militia/thrusters/1",
    explosion,
    @"ship/triangle/thrusters/0",
    @"ship/triangle/thrusters/1",
    @"ship/kevin/thrusters/0",
    @"ship/kevin/thrusters/1",
    @"ship/wendy/thrusters/left/0",
    @"ship/wendy/thrusters/left/1",
    @"ship/wendy/thrusters/right/0",
    @"ship/wendy/thrusters/right/1",
    @"ship/wendy/thrusters/top/0",
    @"ship/wendy/thrusters/top/1",
    @"ship/wendy/thrusters/bottom/0",
    @"ship/wendy/thrusters/bottom/1",
};

const Animation = struct {
    frames: []const SpriteId,
    next: ?AnimationId,
    fps: f32,
    angle: f32,
};

// XXX: CURRENT: things are generally working, but some thrust animations are broken (play and then stop
// right now...) remember that we wanna switch this to using a loop trick probably?
pub const data = b: {
    var result = std.EnumArray(AnimationId, Animation).initFill(undefined);
    result.set(.@"ship/ranger/thrusters/0", .{
        .frames = &.{
            .@"img/ship/ranger/thrusters/0.png",
        },
        .next = .@"ship/ranger/thrusters/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/ranger/thrusters/1", .{
        .frames = &.{
            .@"img/ship/ranger/thrusters/1.png",
            .@"img/ship/ranger/thrusters/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/militia/thrusters/0", .{
        .frames = &.{
            .@"img/ship/militia/thrusters/0.png",
        },
        .next = .@"ship/militia/thrusters/0",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/militia/thrusters/1", .{
        .frames = &.{
            .@"img/ship/militia/thrusters/1.png",
            .@"img/ship/militia/thrusters/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.explosion, .{
        .frames = &.{
            .@"img/explosion/01.png",
            .@"img/explosion/02.png",
            .@"img/explosion/03.png",
            .@"img/explosion/04.png",
            .@"img/explosion/05.png",
            .@"img/explosion/06.png",
            .@"img/explosion/07.png",
            .@"img/explosion/08.png",
            .@"img/explosion/09.png",
            .@"img/explosion/10.png",
            .@"img/explosion/11.png",
            .@"img/explosion/12.png",
        },
        .next = null,
        .fps = 30,
        .angle = 0.0,
    });
    result.set(.@"ship/triangle/thrusters/0", .{
        .frames = &.{
            .@"img/ship/triangle/thrusters/0.png",
        },
        .next = .@"ship/triangle/thrusters/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/triangle/thrusters/1", .{
        .frames = &.{
            .@"img/ship/triangle/thrusters/1.png",
            .@"img/ship/triangle/thrusters/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/kevin/thrusters/0", .{
        .frames = &.{
            .@"img/ship/kevin/thrusters/0.png",
        },
        .next = .@"ship/kevin/thrusters/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/kevin/thrusters/1", .{
        .frames = &.{
            .@"img/ship/kevin/thrusters/1.png",
            .@"img/ship/kevin/thrusters/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/left/0", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/left/0.png",
        },
        .next = .@"ship/wendy/thrusters/left/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/left/1", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/left/1.png",
            .@"img/ship/wendy/thrusters/left/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/right/0", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/right/0.png",
        },
        .next = .@"ship/wendy/thrusters/right/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/right/1", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/right/1.png",
            .@"img/ship/wendy/thrusters/right/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/top/0", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/top/0.png",
        },
        .next = .@"ship/wendy/thrusters/top/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/top/1", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/top/1.png",
            .@"img/ship/wendy/thrusters/top/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/bottom/0", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/bottom/0.png",
        },
        .next = .@"ship/wendy/thrusters/bottom/1",
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    result.set(.@"ship/wendy/thrusters/bottom/1", .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/bottom/1.png",
            .@"img/ship/wendy/thrusters/bottom/2.png",
        },
        .next = null,
        .fps = 10,
        .angle = math.pi / 2.0,
    });
    break :b result;
};
