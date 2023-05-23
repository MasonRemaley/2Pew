const std = @import("std");
const math = std.math;

pub const asset = .{
    .frames = &.{
        .@"wendy/thrusters/right/0",
        .@"wendy/thrusters/right/1",
        .@"wendy/thrusters/right/2",
    },
    .loop_start = 1,
    .fps = 10,
    .angle = math.pi / 2.0,
};
