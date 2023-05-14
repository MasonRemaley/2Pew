const std = @import("std");
const math = std.math;

pub const descriptors = &.{
    .{
        .id = "ship/ranger/thrusters",
        .asset = .{
            .frames = &.{
                .@"img/ship/ranger/thrusters/0.png",
                .@"img/ship/ranger/thrusters/1.png",
                .@"img/ship/ranger/thrusters/2.png",
            },
            .loop_start = 1,
            .fps = 10,
            .angle = math.pi / 2.0,
        },
    },
    .{
        .id = "ship/militia/thrusters",
        .asset = .{
            .frames = &.{
                .@"img/ship/militia/thrusters/0.png",
                .@"img/ship/militia/thrusters/1.png",
                .@"img/ship/militia/thrusters/2.png",
            },
            .loop_start = 1,
            .fps = 10,
            .angle = math.pi / 2.0,
        },
    },
    .{
        .id = "explosion",
        .asset = .{
            .frames = &.{
                .@"img/explosion/01.png",
                .@"img/explosion/02.png",
                .@"img/explosion/03.png",
                .@"img/explosion/04.png",
                .@"img/explosion/05.png",
                .@"img/explosion/06.png",
                .@"img/explosion/07.png",
                .@"img/explosion/08.png",
                .@"img/explosion/09.png",
                .@"img/explosion/10.png",
                .@"img/explosion/11.png",
                .@"img/explosion/12.png",
            },
            .fps = 30,
            .angle = 0.0,
        },
    },
    .{
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
    },
    .{
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
    },
    .{
        .id = "ship/wendy/thrusters/left",
        .asset = .{
            .frames = &.{
                .@"img/ship/wendy/thrusters/left/0.png",
                .@"img/ship/wendy/thrusters/left/1.png",
                .@"img/ship/wendy/thrusters/left/2.png",
            },
            .loop_start = 1,
            .fps = 10,
            .angle = math.pi / 2.0,
        },
    },
    .{
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
    },
    .{
        .id = "ship/wendy/thrusters/top",
        .asset = .{
            .frames = &.{
                .@"img/ship/wendy/thrusters/top/0.png",
                .@"img/ship/wendy/thrusters/top/1.png",
                .@"img/ship/wendy/thrusters/top/2.png",
            },
            .loop_start = 1,
            .fps = 10,
            .angle = math.pi / 2.0,
        },
    },
    .{
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
    },
};
