const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"triangle/thrusters/0",
        .@"triangle/thrusters/1",
        .@"triangle/thrusters/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
