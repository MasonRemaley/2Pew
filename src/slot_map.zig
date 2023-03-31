const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const log2_int_ceil = std.math.log2_int_ceil;

pub fn SlotMap(comptime Item: type, comptime capacity: usize, comptime GenerationType: type) type {
    return struct {
        // TODO: using u32, make automatic based on capacity? or set capacity automatically idk though lol
        pub const Index = @Type(std.builtin.Type{
            .Int = .{
                .signedness = .unsigned,
                .bits = if (capacity == 0) 0 else log2_int_ceil(usize, capacity),
            },
        });
        pub const Generation = GenerationType;
        const Slot = struct {
            item: Item,
            generation: Generation,
        };
        pub const Handle = struct {
            index: Index,
            generation: Generation,
        };

        slots: []Slot,
        free_list: []Index,

        pub fn init(allocator: Allocator) Allocator.Error!@This() {
            var slots = try allocator.alloc(Slot, capacity);
            errdefer allocator.free(slots.ptr[0..capacity]);
            slots.len = 0;

            var free_list = try allocator.alloc(Index, capacity);
            errdefer allocator.free(free_list.ptr[0..capacity]);
            free_list.len = 0;

            return .{
                .slots = slots,
                .free_list = free_list,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.slots.ptr[0..capacity]);
            allocator.free(self.free_list.ptr[0..capacity]);
        }

        // Adds a new slot, leaving its item undefined.
        fn addSlot(self: *@This()) !Index {
            if (self.free_list.len > 0) {
                self.free_list.len -= 1;
                return self.free_list.ptr[self.free_list.len];
            }
            if (self.slots.len < capacity) {
                const index = self.slots.len;
                self.slots.len += 1;
                self.slots[index].generation = 0;
                return @intCast(Index, index);
            }
            return error.AtCapacity;
        }

        pub fn create(self: *@This(), item: Item) !Handle {
            const index = try self.addSlot();
            const slot = &self.slots[index];
            slot.item = item;
            return .{
                .index = index,
                .generation = slot.generation,
            };
        }

        pub fn remove(self: *@This(), handle: Handle) error{ DoubleFree, OutOfBounds }!Item {
            // TODO: do we have to check this? may already be handled!
            if (handle.index >= self.slots.len) {
                return error.OutOfBounds;
            }

            if (self.slots[handle.index].generation != handle.generation) {
                return error.DoubleFree;
            }

            if (self.free_list.len >= capacity) {
                // This could happen if the generation counter fails to prevent a double free due to
                // being wrapped (most likely if we've turned off that safety by setting it to a u0.)
                return error.DoubleFree;
            }

            if (Generation != u0) {
                // TODO: support throwing it out when it wraps as well
                self.slots[handle.index].generation +%= 1;
            }

            // TODO: does .ptr do what I think it does?
            self.free_list.ptr[self.free_list.len] = handle.index;
            self.free_list.len += 1;

            return self.slots.ptr[handle.index].item;
        }

        pub fn get(self: *const @This(), handle: Handle) error{ UseAfterFree, OutOfBounds }!*Item {
            if (handle.index >= self.slots.len) {
                return error.OutOfBounds;
            }

            if (self.slots[handle.index].generation != handle.generation) {
                return error.UseAfterFree;
            }

            return self.getUnchecked(handle);
        }

        pub fn getUnchecked(self: *const @This(), handle: Handle) *Item {
            return &self.slots[handle.index].item;
        }
    };
}

test "slot map" {
    var sm = try SlotMap(u8, 5, u8).init(testing.allocator);
    defer sm.deinit(testing.allocator);

    const H = @TypeOf(sm).Handle;

    try testing.expect(sm.get(H{ .index = 0, .generation = 0 }) == error.OutOfBounds);

    const a = try sm.create('a');
    const b = try sm.create('b');
    try testing.expect(sm.get(H{ .index = 4, .generation = 0 }) == error.OutOfBounds);
    const c = try sm.create('c');
    const d = try sm.create('d');
    const e = try sm.create('e');

    try testing.expect((try sm.get(a)).* == 'a');
    try testing.expect((try sm.get(b)).* == 'b');
    try testing.expect((try sm.get(c)).* == 'c');
    try testing.expect((try sm.get(d)).* == 'd');
    try testing.expect((try sm.get(e)).* == 'e');

    try testing.expect(sm.create('f') == error.AtCapacity);

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

    try testing.expect(sm.create('h') == error.AtCapacity);
}
