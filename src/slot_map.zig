const std = @import("std");

const assert = std.debug.assert;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const NoAlloc = @import("no_alloc.zig").NoAlloc;

pub fn Handle(comptime exact_capacity: usize, comptime GenerationTag: type) type {
    const IndexT = @Type(std.builtin.Type{
        .Int = .{
            .signedness = .unsigned,
            .bits = if (exact_capacity == 0) 0 else std.math.log2_int_ceil(usize, exact_capacity),
        },
    });
    const GenerationT = enum(GenerationTag) {
        const Self = @This();

        // XXX: could i represent invalud efficeintly as absence of a generation? that'd be less
        // weird in serialized data...
        /// An invalid generation.
        invalid = std.math.maxInt(GenerationTag),
        /// A valid geneartion that will never be used.
        none = std.math.maxInt(GenerationTag) - 1,
        /// All other generations.
        _,

        // TODO: support throwing it out when it wraps as well
        fn increment(self: *Self) void {
            comptime assert(@intFromEnum(Self.invalid) > 1);
            assert(self.* != .none);
            assert(self.* != .invalid);

            self.* = @enumFromInt(Self, @intFromEnum(self.*) + 1);
            if (self.* == .none) {
                self.* = @enumFromInt(Self, 0);
            }
        }
    };

    return struct {
        const Self = @This();

        pub const Index = IndexT;
        pub const Generation = GenerationT;
        pub const capacity = exact_capacity;

        index: Index,
        generation: Generation,

        /// A handle that never exists.
        pub const none = Self{
            .index = 0,
            .generation = .none,
        };

        pub fn eql(lhs: Self, rhs: Self) bool {
            return std.meta.eql(lhs, rhs);
        }
    };
}

pub fn SlotMap(comptime Item: type, comptime HandleT: type) type {
    return struct {
        const Self = @This();
        const capacity = HandleT.capacity;
        const Index = HandleT.Index;
        const Generation = HandleT.Generation;
        const Slot = struct {
            item: Item,
            generation: HandleT.Generation,
        };

        slots: ArrayListUnmanaged(Slot),
        free: ArrayListUnmanaged(Index),

        pub fn init(allocator: Allocator) Allocator.Error!Self {
            var slots = try ArrayListUnmanaged(Slot).initCapacity(allocator, capacity);
            errdefer slots.deinit(allocator);
            // TODO: if this makes startup slower we can compare to just zeroing the whole thing
            for (slots.items.ptr[0..slots.capacity]) |*slot| {
                slot.* = .{
                    .item = undefined,
                    .generation = @enumFromInt(Generation, 0),
                };
            }

            var free = try ArrayListUnmanaged(Index).initCapacity(allocator, capacity);
            errdefer free.deinit(allocator);

            return .{
                .slots = slots,
                .free = free,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.slots.deinit(allocator);
            self.free.deinit(allocator);
            self.* = undefined;
        }

        // Adds a new slot, leaving its item undefined.
        fn addOne(self: *Self) Allocator.Error!Index {
            if (self.free.popOrNull()) |index| {
                return index;
            }
            const index = @intCast(Index, self.slots.items.len);
            _ = try self.slots.addOne(NoAlloc);
            return index;
        }

        pub fn create(self: *Self, item: Item) !HandleT {
            const index = try self.addOne();
            const slot = &self.slots.items[index];
            slot.item = item;
            return .{
                .index = index,
                .generation = slot.generation,
            };
        }

        pub fn remove(self: *Self, handle: HandleT) error{DoubleFree}!Item {
            if (!self.exists(handle)) {
                return error.DoubleFree;
            }

            self.free.append(NoAlloc, handle.index) catch |err| switch (err) {
                // This could happen if the generation counter fails to prevent a double free due to
                // being wrapped (most likely if we've turned off that safety by setting it to a u0.)
                error.OutOfMemory => return error.DoubleFree,
            };

            self.slots.items[handle.index].generation.increment();

            return self.slots.items[handle.index].item;
        }

        pub fn exists(self: *const Self, handle: HandleT) bool {
            if (handle.index >= self.slots.items.len) {
                // This can occur if we cleared the slot map previously.
                return false;
            }

            return self.slots.items[handle.index].generation == handle.generation;
        }

        pub fn get(self: *const Self, handle: HandleT) error{UseAfterFree}!*Item {
            if (!self.exists(handle)) {
                return error.UseAfterFree;
            }

            return self.getUnchecked(handle);
        }

        pub fn getUnchecked(self: *const Self, handle: HandleT) *Item {
            return &self.slots.items[handle.index].item;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            for (0..self.slots.items.len) |i| {
                self.slots.items[@intCast(Index, i)].generation.increment();
            }
            self.free.clearRetainingCapacity();
            self.slots.clearRetainingCapacity();
        }

        // XXX: test this
        pub fn len(self: *const Self) Index {
            return @intCast(Index, self.slots.items.len - self.free.items.len);
        }
    };
}

test "slot map" {
    const H = Handle(5, u8);
    var sm = try SlotMap(u8, H).init(testing.allocator);
    defer sm.deinit(testing.allocator);

    try testing.expect(sm.get(H{ .index = 0, .generation = @enumFromInt(H.Generation, 0) }) == error.UseAfterFree);

    const a = try sm.create('a');
    const b = try sm.create('b');
    try testing.expect(sm.get(H{ .index = 4, .generation = @enumFromInt(H.Generation, 0) }) == error.UseAfterFree);
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

    try testing.expectEqual(H{ .index = 0, .generation = @enumFromInt(H.Generation, 0) }, a);
    try testing.expectEqual(H{ .index = 1, .generation = @enumFromInt(H.Generation, 0) }, b);
    try testing.expectEqual(H{ .index = 2, .generation = @enumFromInt(H.Generation, 0) }, c);
    try testing.expectEqual(H{ .index = 3, .generation = @enumFromInt(H.Generation, 0) }, d);
    try testing.expectEqual(H{ .index = 4, .generation = @enumFromInt(H.Generation, 0) }, e);
    try testing.expectEqual(H{ .index = 3, .generation = @enumFromInt(H.Generation, 1) }, f);
    try testing.expectEqual(H{ .index = 2, .generation = @enumFromInt(H.Generation, 1) }, g);

    var temp = g;
    for (0..253) |_| {
        try testing.expect(try sm.remove(temp) == 'g');
        temp = try sm.create('g');
    }
    try testing.expectEqual(H{ .index = g.index, .generation = @enumFromInt(H.Generation, 0) }, temp);

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

    try testing.expectEqual(H{ .index = 0, .generation = @enumFromInt(H.Generation, 1) }, h);
    try testing.expectEqual(H{ .index = 1, .generation = @enumFromInt(H.Generation, 1) }, i);
    try testing.expectEqual(H{ .index = 2, .generation = @enumFromInt(H.Generation, 1) }, j);
    try testing.expectEqual(H{ .index = 3, .generation = @enumFromInt(H.Generation, 2) }, k);
    try testing.expectEqual(H{ .index = 4, .generation = @enumFromInt(H.Generation, 1) }, l);

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

    try testing.expect(!sm.exists(H.none));
    try testing.expect(!sm.exists(H{ .index = 1, .generation = .none }));
}
