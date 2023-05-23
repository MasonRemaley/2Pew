const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"ranger/thrusters/0",
        .@"ranger/thrusters/1",
        .@"ranger/thrusters/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
