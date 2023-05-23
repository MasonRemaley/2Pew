const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"militia/thrusters/0",
        .@"militia/thrusters/1",
        .@"militia/thrusters/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
