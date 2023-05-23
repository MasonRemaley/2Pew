const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"wendy/thrusters/top/0",
        .@"wendy/thrusters/top/1",
        .@"wendy/thrusters/top/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
