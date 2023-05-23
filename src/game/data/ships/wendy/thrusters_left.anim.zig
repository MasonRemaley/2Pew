const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"wendy/thrusters/left/0",
        .@"wendy/thrusters/left/1",
        .@"wendy/thrusters/left/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
