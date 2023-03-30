const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn MinimumAlignmentAllocator(comptime min_alignment: u8) type {
    comptime assert(std.math.isPowerOfTwo(min_alignment));

    return struct {
        const log2_min_alignment: u8 = std.math.log2_int(u8, min_alignment);

        child_allocator: Allocator,

        pub fn init(child_allocator: Allocator) @This() {
            return .{ .child_allocator = child_allocator };
        }

        fn adjustAlignment(log2_alignment: u8) u8 {
            return std.math.max(log2_alignment, log2_min_alignment);
        }

        fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
            return self.child_allocator.rawAlloc(n, adjustAlignment(log2_ptr_align), ra);
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
            return self.child_allocator.rawResize(buf, adjustAlignment(log2_buf_align), new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
            return self.child_allocator.rawFree(buf, adjustAlignment(log2_buf_align), ret_addr);
        }

        pub fn allocator(self: *@This()) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }
    };
}

test "minimum alignment allocator" {
    var buffer = try std.heap.page_allocator.alloc(u8, 1024);
    defer std.heap.page_allocator.free(buffer);

    {
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var maa = MinimumAlignmentAllocator(1).init(fba.allocator());
        var allocator = maa.allocator();
        var a = try allocator.create(u8);
        var b = try allocator.create(u16);
        var c = try allocator.create(u8);
        var d = try allocator.create(u8);
        try std.testing.expect(@ptrCast(*u8, a) == &buffer[0]);
        try std.testing.expect(@ptrCast(*u8, b) == &buffer[2]);
        try std.testing.expect(@ptrCast(*u8, c) == &buffer[4]);
        try std.testing.expect(@ptrCast(*u8, d) == &buffer[5]);
    }

    {
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var maa = MinimumAlignmentAllocator(2).init(fba.allocator());
        var allocator = maa.allocator();
        var a = try allocator.create(u8);
        var b = try allocator.create(u16);
        var c = try allocator.create(u8);
        var d = try allocator.create(u8);
        try std.testing.expect(@ptrCast(*u8, a) == &buffer[0]);
        try std.testing.expect(@ptrCast(*u8, b) == &buffer[2]);
        try std.testing.expect(@ptrCast(*u8, c) == &buffer[4]);
        try std.testing.expect(@ptrCast(*u8, d) == &buffer[6]);
    }

    {
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var maa = MinimumAlignmentAllocator(4).init(fba.allocator());
        var allocator = maa.allocator();
        var a = try allocator.create(u8);
        var b = try allocator.create(u16);
        var c = try allocator.create(u8);
        var d = try allocator.create(u8);
        try std.testing.expect(@ptrCast(*u8, a) == &buffer[0]);
        try std.testing.expect(@ptrCast(*u8, b) == &buffer[4]);
        try std.testing.expect(@ptrCast(*u8, c) == &buffer[8]);
        try std.testing.expect(@ptrCast(*u8, d) == &buffer[12]);
    }
}
