const std = @import("std");
const ecs = @import("ecs.zig");

const assert = std.debug.assert;

const Handle = ecs.entities.Handle;

pub fn init(comptime Entities: type) ?type {
    // Return null if `Entities` does not have a parent component of the correct type
    inline for (Entities.component_names, Entities.component_types) |name, ty| {
        if (std.mem.eql(u8, name, "parent") and ty == ?Handle) {
            break;
        }
    } else return null;

    // Return the module
    return struct {
        pub fn get(entities: *const Entities, handle: Handle) ?Handle {
            if (entities.getComponent(handle, .parent)) |parent| {
                return parent.*;
            }
            return null;
        }

        pub fn set(entities: *Entities, child: Handle, parent: ?Handle) void {
            // If we're setting it to null but there's no current parent anyway,
            // early out to avoid a pointless archetype change
            if (parent == null and entities.getComponent(child, .parent) == null) {
                return;
            }

            // Set the parent
            entities.addComponents(child, .{ .parent = parent });

            // If this change caused a parent cycle, break the cycle
            if (parent != null) {
                var it = iterator(entities, parent.?);
                while (it.next()) |current| {
                    const next = it.peek;
                    if (next != null and next.?.eql(child)) {
                        set(entities, current, null);
                        break;
                    }
                }
            }
        }

        pub fn removeOrphans(entities: *Entities) void {
            // This is done iteratively to avoid needing to store children pointers. While suboptimal for
            // removing large hierarchies, this is simpler for the time being.
            var dirty = true;
            while (dirty) {
                dirty = false;
                var it = entities.iterator(.{ .parent = .{} });
                while (it.next()) |entity| {
                    if (entity.parent.*) |parent| {
                        if (!entities.exists(parent)) {
                            it.swapRemove();
                            dirty = true;
                            continue;
                        }
                    }
                }
            }
        }

        pub const Iterator = struct {
            const Self = @This();

            entities: *const Entities,
            peek: ?Handle,

            pub fn next(self: *Self) ?Handle {
                if (self.peek == null) return null;

                const result = self.peek;
                self.peek = get(self.entities, self.peek.?);
                return result;
            }
        };

        pub fn iterator(entities: *const Entities, handle: Handle) Iterator {
            return .{
                .entities = entities,
                .peek = handle,
            };
        }
    };
}

test "supported" {
    const expect = std.testing.expect;

    try expect(init(ecs.entities.Entities(.{ .parent = ?Handle })) != null);
    try expect(init(ecs.entities.Entities(.{ .parent = ?Handle, .y = f32 })) != null);
    try expect(init(ecs.entities.Entities(.{ .parent = Handle, .y = f32 })) == null);
    try expect(init(ecs.entities.Entities(.{ .parent = ?f32, .y = f32 })) == null);
    try expect(init(ecs.entities.Entities(.{ .foo = ?Handle, .y = f32 })) == null);
}

test "get parent" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{ .parent = ?Handle });
    var entities = try Entities.init(allocator);
    defer entities.deinit();
    const parenting = init(Entities).?;

    const a = entities.create(.{});
    const b = entities.create(.{ .parent = a });
    const c = entities.create(.{ .parent = null });

    try expectEqual(parenting.get(&entities, a), null);
    try expectEqual(parenting.get(&entities, b).?, a);
    try expectEqual(parenting.get(&entities, c), null);
}

test "set parent" {
    const expectEqual = std.testing.expectEqual;
    const expect = std.testing.expect;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{ .parent = ?Handle });
    var entities = try Entities.init(allocator);
    defer entities.deinit();
    const parenting = init(Entities).?;

    const a = entities.create(.{});
    const b = entities.create(.{});
    const c = entities.create(.{});

    // Setting a parent to null that doesn't exist shouldn't change the
    // archetype just to add null
    parenting.set(&entities, a, null);
    try expectEqual(entities.getComponent(a, .parent), null);

    // Setting the parent when it doesn't exist yet should add the component
    parenting.set(&entities, a, b);
    try expectEqual(parenting.get(&entities, a), b);

    // Setting the parent to null should not remove the component
    parenting.set(&entities, a, null);
    try expect(entities.getComponent(a, .parent).?.* == null);

    // Cycle of length one should be broken
    parenting.set(&entities, a, b);
    parenting.set(&entities, a, a);
    try expectEqual(parenting.get(&entities, a), null);

    // Larger cycles should be broken too
    parenting.set(&entities, a, b);
    parenting.set(&entities, b, c);
    parenting.set(&entities, c, a);

    try expectEqual(parenting.get(&entities, c), a);
    try expectEqual(parenting.get(&entities, a), b);
    try expectEqual(parenting.get(&entities, b), null);
}

test "remove orphans" {
    const expect = std.testing.expect;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{ .parent = ?Handle });
    var entities = try Entities.init(allocator);
    defer entities.deinit();
    const parenting = init(Entities).?;

    const keep = entities.create(.{});
    const root = entities.create(.{});
    const root_child0 = entities.create(.{ .parent = root });
    const root_child1 = entities.create(.{ .parent = root });
    const root_child0_child0 = entities.create(.{ .parent = root_child0 });
    const root_child0_child1 = entities.create(.{ .parent = root_child0 });
    const other_root = entities.create(.{});
    const other_root_child = entities.create(.{ .parent = other_root });

    entities.swapRemove(root_child0);
    entities.swapRemove(other_root);

    parenting.removeOrphans(&entities);

    try expect(entities.exists(keep));
    try expect(entities.exists(root));
    try expect(!entities.exists(root_child0));
    try expect(entities.exists(root_child1));
    try expect(!entities.exists(root_child0_child0));
    try expect(!entities.exists(root_child0_child1));
    try expect(!entities.exists(other_root));
    try expect(!entities.exists(other_root_child));
}

test "iterator" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{ .parent = ?Handle });
    var entities = try Entities.init(allocator);
    defer entities.deinit();
    const parenting = init(Entities).?;

    const a = entities.create(.{});
    const b = entities.create(.{ .parent = a });
    const c = entities.create(.{ .parent = b });
    const d = entities.create(.{ .parent = c });

    var iter = parenting.iterator(&entities, d);
    try expectEqual(iter.peek.?, d);
    try expectEqual(iter.next().?, d);
    try expectEqual(iter.peek.?, c);
    try expectEqual(iter.next().?, c);
    try expectEqual(iter.next().?, b);
    try expectEqual(iter.next().?, a);
    try expectEqual(iter.peek, null);
    try expectEqual(iter.next(), null);
    try expectEqual(iter.next(), null);
    try expectEqual(iter.peek, null);
}
