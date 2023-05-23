const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"wendy/thrusters/bottom/0",
        .@"wendy/thrusters/bottom/1",
        .@"wendy/thrusters/bottom/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
