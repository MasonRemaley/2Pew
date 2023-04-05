const std = @import("std");
const ecs = @import("index.zig");

const assert = std.debug.assert;

const Handle = ecs.entities.Handle;

pub fn supported(comptime Entities: type) bool {
    inline for (Entities.component_names, Entities.component_types) |name, ty| {
        if (std.mem.eql(u8, name, "parent") and ty == ?Handle) {
            return true;
        }
    }
    return false;
}

pub fn requireSupport(comptime Entities: type) void {
    if (!comptime supported(Entities)) {
        @compileError("to support parenting, add a component `parent: ?Entities.Handle`");
    }
}

pub fn getParent(entities: anytype, handle: Handle) ?Handle {
    comptime assert(@typeInfo(@TypeOf(entities)) == .Pointer);
    requireSupport(@TypeOf(entities.*));

    if (entities.getComponent(handle, .parent)) |parent| {
        return parent.*;
    }
    return null;
}

pub fn setParent(entities: anytype, child: Handle, parent: ?Handle) void {
    comptime assert(@typeInfo(@TypeOf(entities)) == .Pointer);
    requireSupport(@TypeOf(entities.*));

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
            const next = it.peek();
            if (next != null and next.?.eql(child)) {
                setParent(entities, current, null);
                break;
            }
        }
    }
}

pub fn removeOrphans(entities: anytype) void {
    comptime assert(@typeInfo(@TypeOf(entities)) == .Pointer);
    requireSupport(@TypeOf(entities.*));

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

pub fn Iterator(comptime Entities: type) type {
    requireSupport(Entities);
    return struct {
        const Self = @This();

        entities: *Entities,
        current: ?Handle,

        pub fn next(self: *Self) ?Handle {
            if (self.current == null) return null;

            const result = self.peek();
            self.current = getParent(self.entities, self.current.?);
            return result;
        }

        pub fn peek(self: *const Self) ?Handle {
            return self.current;
        }
    };
}

pub fn iterator(entities: anytype, handle: Handle) Iterator(@TypeOf(entities.*)) {
    comptime assert(@typeInfo(@TypeOf(entities)) == .Pointer);
    requireSupport(@TypeOf(entities.*));
    return .{
        .entities = entities,
        .current = handle,
    };
}
