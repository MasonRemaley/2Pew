x: f32,
y: f32,

pub fn unit(angle_in_radians: f32) Vec2d {
    return .{
        .x = @cos(angle_in_radians),
        .y = @sin(angle_in_radians),
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

pub fn plus(v: Vec2d, other: Vec2d) Vec2d {
    return .{
        .x = v.x + other.x,
        .y = v.y + other.y,
    };
}

pub fn minus(v: Vec2d, other: Vec2d) Vec2d {
    return .{
        .x = v.x - other.x,
        .y = v.y - other.y,
    };
}

pub fn floored(v: Vec2d) Vec2d {
    return .{
        .x = @floor(v.x),
        .y = @floor(v.y),
    };
}

pub fn angle(v: Vec2d) f32 {
    if (v.lengthSqrd() == 0) {
        return 0;
    } else {
        return math.atan2(f32, v.y, v.x);
    }
}

pub fn lengthSqrd(v: Vec2d) f32 {
    return v.x * v.x + v.y * v.y;
}

pub fn length(v: Vec2d) f32 {
    return @sqrt(v.lengthSqrd());
}

pub fn distanceSqrd(v: Vec2d, other: Vec2d) f32 {
    var dx = other.x - v.x;
    var dy = other.y - v.y;
    return dx * dx + dy * dy;
}

pub fn normalized(v: Vec2d) Vec2d {
    const len = v.length();
    if (len == 0) {
        return v;
    } else {
        return v.scaled(1.0 / len);
    }
}

const Vec2d = @This();
const std = @import("std");
const math = std.math;
