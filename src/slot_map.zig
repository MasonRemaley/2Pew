const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const log2_int_ceil = std.math.log2_int_ceil;
const BoundedArrayList = @import("bounded_array_list.zig").BoundedArrayList;

pub fn IndexType(comptime capacity: usize) type {
    return @Type(std.builtin.Type{
        .Int = .{
            .signedness = .unsigned,
            .bits = if (capacity == 0) 0 else log2_int_ceil(usize, capacity),
        },
    });
}

pub fn HandleType(comptime Index: type, comptime Generation: type) type {
    return struct {
        index: Index,
        generation: Generation,

        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return std.meta.eql(lhs, rhs);
        }
    };
}

pub fn SlotMap(comptime Item: type, comptime capacity: usize, comptime Generation: type) type {
    return struct {
        pub const Handle = HandleType(Index, Generation);

        const Index = IndexType(capacity);
        const Slot = struct {
            item: Item,
            generation: Generation,
        };

        slots: BoundedArrayList(Slot),
        free_list: BoundedArrayList(Index),

        pub fn init(allocator: Allocator) Allocator.Error!@This() {
            var slots = try BoundedArrayList(Slot).init(allocator, capacity);
            errdefer slots.deinit(allocator);
            // TODO: if this makes startup slower we can compare to just zeroing the whole thing
            for (slots.items.ptr[0..slots.capacity]) |*slot| {
                slot.* = .{
                    .item = undefined,
                    .generation = 0,
                };
            }

            var free_list = try BoundedArrayList(Index).init(allocator, capacity);
            errdefer free_list.deinit(allocator);

            return .{
                .slots = slots,
                .free_list = free_list,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.slots.deinit(allocator);
            self.free_list.deinit(allocator);
        }

        // Adds a new slot, leaving its item undefined.
        fn addOne(self: *@This()) Allocator.Error!Index {
            if (self.free_list.popOrNull()) |index| {
                return index;
            }
            const index = @intCast(Index, self.slots.items.len);
            _ = try self.slots.addOne();
            return index;
        }

        pub fn create(self: *@This(), item: Item) !Handle {
            const index = try self.addOne();
            const slot = &self.slots.items[index];
            slot.item = item;
            return .{
                .index = index,
                .generation = slot.generation,
            };
        }

        fn incrementGeneration(self: *@This(), index: Index) void {
            if (Generation != u0) {
                // TODO: support throwing it out when it wraps as well
                self.slots.items[index].generation +%= 1;
            }
        }

        pub fn remove(self: *@This(), handle: Handle) error{DoubleFree}!Item {
            if (!self.exists(handle)) {
                return error.DoubleFree;
            }

            self.free_list.append(handle.index) catch |err| switch (err) {
                // This could happen if the generation counter fails to prevent a double free due to
                // being wrapped (most likely if we've turned off that safety by setting it to a u0.)
                error.OutOfMemory => return error.DoubleFree,
            };

            self.incrementGeneration(handle.index);

            return self.slots.items[handle.index].item;
        }

        pub fn exists(self: *const @This(), handle: Handle) bool {
            if (handle.index >= self.slots.items.len) {
                // This can occur if we cleared the slot map previously.
                return false;
            }

            return self.slots.items[handle.index].generation == handle.generation;
        }

        pub fn get(self: *const @This(), handle: Handle) error{UseAfterFree}!*Item {
            if (!self.exists(handle)) {
                return error.UseAfterFree;
            }

            return self.getUnchecked(handle);
        }

        pub fn getUnchecked(self: *const @This(), handle: Handle) *Item {
            return &self.slots.items[handle.index].item;
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            for (0..self.slots.items.len) |i| {
                self.incrementGeneration(@intCast(Index, i));
            }
            self.free_list.clearRetainingCapacity();
            self.slots.clearRetainingCapacity();
        }
    };
}

test "slot map" {
    var sm = try SlotMap(u8, 5, u8).init(testing.allocator);
    defer sm.deinit(testing.allocator);

    const H = @TypeOf(sm).Handle;

    try testing.expect(sm.get(H{ .index = 0, .generation = 0 }) == error.UseAfterFree);

    const a = try sm.create('a');
    const b = try sm.create('b');
    try testing.expect(sm.get(H{ .index = 4, .generation = 0 }) == error.UseAfterFree);
    const c = try sm.create('c');
    const d = try sm.create('d');
    const e = try sm.create('e');

    try testing.expect((try sm.get(a)).* == 'a');
    try testing.expect((try sm.get(b)).* == 'b');
    try testing.expect((try sm.get(c)).* == 'c');
    try testing.expect((try sm.get(d)).* == 'd');
    try testing.expect((try sm.get(e)).* == 'e');

    try testing.expect(sm.create('f') == error.OutOfMemory);

    try testing.expect(try sm.remove(c) == 'c');
    try testing.expect(try sm.remove(d) == 'd');

    try testing.expect(sm.remove(c) == error.DoubleFree);
    try testing.expect(sm.remove(d) == error.DoubleFree);

    try testing.expect((try sm.get(a)).* == 'a');
    try testing.expect((try sm.get(b)).* == 'b');
    try testing.expect(sm.get(c) == error.UseAfterFree);
    try testing.expect(sm.get(d) == error.UseAfterFree);
    try testing.expect((try sm.get(e)).* == 'e');

    const f = try sm.create('f');

    try testing.expect((try sm.get(a)).* == 'a');
    try testing.expect((try sm.get(b)).* == 'b');
    try testing.expect(sm.get(c) == error.UseAfterFree);
    try testing.expect(sm.get(d) == error.UseAfterFree);
    try testing.expect((try sm.get(e)).* == 'e');
    try testing.expect((try sm.get(f)).* == 'f');

    const g = try sm.create('g');

    try testing.expect((try sm.get(a)).* == 'a');
    try testing.expect((try sm.get(b)).* == 'b');
    try testing.expect(sm.get(c) == error.UseAfterFree);
    try testing.expect(sm.get(d) == error.UseAfterFree);
    try testing.expect((try sm.get(e)).* == 'e');
    try testing.expect((try sm.get(f)).* == 'f');
    try testing.expect((try sm.get(g)).* == 'g');

    try testing.expectEqual(H{ .index = 0, .generation = 0 }, a);
    try testing.expectEqual(H{ .index = 1, .generation = 0 }, b);
    try testing.expectEqual(H{ .index = 2, .generation = 0 }, c);
    try testing.expectEqual(H{ .index = 3, .generation = 0 }, d);
    try testing.expectEqual(H{ .index = 4, .generation = 0 }, e);
    try testing.expectEqual(H{ .index = 3, .generation = 1 }, f);
    try testing.expectEqual(H{ .index = 2, .generation = 1 }, g);

    var temp = g;
    for (0..255) |_| {
        try testing.expect(try sm.remove(temp) == 'g');
        temp = try sm.create('g');
    }
    try testing.expectEqual(H{ .index = g.index, .generation = 0 }, temp);

    try testing.expect(sm.create('h') == error.OutOfMemory);

    sm.clearRetainingCapacity();

    try testing.expect(sm.get(a) == error.UseAfterFree);
    try testing.expect(sm.get(b) == error.UseAfterFree);
    try testing.expect(sm.get(c) == error.UseAfterFree);
    try testing.expect(sm.get(d) == error.UseAfterFree);
    try testing.expect(sm.get(e) == error.UseAfterFree);
    try testing.expect(sm.get(f) == error.UseAfterFree);
    try testing.expect(sm.get(g) == error.UseAfterFree);
    try testing.expect(sm.get(temp) == error.UseAfterFree);

    const h = try sm.create('h');
    const i = try sm.create('i');
    const j = try sm.create('j');
    const k = try sm.create('k');
    const l = try sm.create('l');

    try testing.expectEqual(H{ .index = 0, .generation = 1 }, h);
    try testing.expectEqual(H{ .index = 1, .generation = 1 }, i);
    try testing.expectEqual(H{ .index = 2, .generation = 1 }, j);
    try testing.expectEqual(H{ .index = 3, .generation = 2 }, k);
    try testing.expectEqual(H{ .index = 4, .generation = 1 }, l);

    try testing.expect(sm.get(a) == error.UseAfterFree);
    try testing.expect(sm.get(b) == error.UseAfterFree);
    try testing.expect(sm.get(c) == error.UseAfterFree);
    try testing.expect(sm.get(d) == error.UseAfterFree);
    try testing.expect(sm.get(e) == error.UseAfterFree);
    try testing.expect(sm.get(f) == error.UseAfterFree);
    try testing.expect((try sm.get(g)).* == 'j'); // generation collision
    try testing.expect(sm.get(temp) == error.UseAfterFree);
    try testing.expect((try sm.get(h)).* == 'h');
    try testing.expect((try sm.get(i)).* == 'i');
    try testing.expect((try sm.get(j)).* == 'j');
    try testing.expect((try sm.get(k)).* == 'k');
    try testing.expect((try sm.get(l)).* == 'l');
}
