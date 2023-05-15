const std = @import("std");
const math = std.math;

pub const descriptor = .{
    .id = "ship/triangle/thrusters",
    .asset = .{
        .frames = &.{
            .@"img/ship/triangle/thrusters/0.png",
            .@"img/ship/triangle/thrusters/1.png",
            .@"img/ship/triangle/thrusters/2.png",
        },
        .loop_start = 1,
        .fps = 10,
        .angle = math.pi / 2.0,
    },
};
