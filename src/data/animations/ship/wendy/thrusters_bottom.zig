const std = @import("std");
const math = std.math;

pub const descriptor = .{
    .id = "ship/wendy/thrusters/bottom",
    .asset = .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/bottom/0.png",
            .@"img/ship/wendy/thrusters/bottom/1.png",
            .@"img/ship/wendy/thrusters/bottom/2.png",
        },
        .loop_start = 1,
        .fps = 10,
        .angle = math.pi / 2.0,
    },
};
