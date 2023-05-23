const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"kevin/thrusters/0",
        .@"kevin/thrusters/1",
        .@"kevin/thrusters/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
