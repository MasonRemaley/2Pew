x: f32,
y: f32,

pub fn unit(angle: f32) Vec2d {
    return .{
        .x = math.cos(angle),
        .y = math.sin(angle),
    };
}

pub fn scaled(v: Vec2d, scalar: f32) Vec2d {
    return .{
        .x = v.x * scalar,
        .y = v.y * scalar,
    };
}

pub fn add(v: *Vec2d, other: Vec2d) void {
    v.x += other.x;
    v.y += other.y;
}

const Vec2d = @This();
const std = @import("std");
const math = std.math;
