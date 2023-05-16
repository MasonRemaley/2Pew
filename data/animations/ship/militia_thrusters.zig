const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"img/ship/militia/thrusters/0.png",
        .@"img/ship/militia/thrusters/1.png",
        .@"img/ship/militia/thrusters/2.png",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
