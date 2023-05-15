const std = @import("std");
const math = std.math;

pub const descriptor = .{
    .id = "ship/kevin/thrusters",
    .asset = .{
        .frames = &.{
            .@"img/ship/kevin/thrusters/0.png",
            .@"img/ship/kevin/thrusters/1.png",
            .@"img/ship/kevin/thrusters/2.png",
        },
        .loop_start = 1,
        .fps = 10,
        .angle = math.pi / 2.0,
    },
};
