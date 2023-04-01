const std = @import("std");

const Allocator = std.mem.Allocator;

// TODO: we could make the capacity comptime instead if we wanted, since that's often how we use this
// TODO: does .ptr do what I think it does?
// TODO: another way to make this would be to just make it an actual array list but give it an always
// failing allocator
pub fn BoundedArrayList(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,

        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!@This() {
            var items = try allocator.alloc(T, capacity);
            errdefer allocator.free(items.ptr[0..capacity]);
            items.len = 0;
            return .{ .items = items, .capacity = capacity };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.items.ptr[0..self.capacity]);
            self.* = undefined;
        }

        pub fn addOne(self: *@This()) Allocator.Error!*T {
            if (self.items.len >= self.capacity) {
                return error.OutOfMemory;
            }

            const ptr = &self.items.ptr[self.items.len];
            self.items.len += 1;
            return ptr;
        }

        pub fn append(self: *@This(), item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOne();
            new_item_ptr.* = item;
        }

        pub fn pop(self: *@This()) T {
            self.items.len -= 1;
            return self.items.ptr[self.items.len];
        }

        pub fn popOrNull(self: *@This()) ?T {
            if (self.items.len == 0) return null;
            return self.pop();
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.items.len = 0;
        }
    };
}
