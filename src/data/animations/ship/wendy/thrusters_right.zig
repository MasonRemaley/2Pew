const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"img/ship/wendy/thrusters/left/0.png",
        .@"img/ship/wendy/thrusters/left/1.png",
        .@"img/ship/wendy/thrusters/left/2.png",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
