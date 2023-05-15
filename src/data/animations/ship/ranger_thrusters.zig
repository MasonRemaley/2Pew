const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"img/ship/ranger/thrusters/0.png",
        .@"img/ship/ranger/thrusters/1.png",
        .@"img/ship/ranger/thrusters/2.png",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
