const std = @import("std");
const math = std.math;

pub const descriptor = .{
    .id = "ship/wendy/thrusters/right",
    .asset = .{
        .frames = &.{
            .@"img/ship/wendy/thrusters/right/0.png",
            .@"img/ship/wendy/thrusters/right/1.png",
            .@"img/ship/wendy/thrusters/right/2.png",
        },
        .loop_start = 1,
        .fps = 10,
        .angle = math.pi / 2.0,
    },
};
