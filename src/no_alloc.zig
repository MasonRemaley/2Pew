const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NoAlloc: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, _: usize, _: u8, _: usize) ?[*]u8 {
    return null;
}

fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    return false;
}

fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
