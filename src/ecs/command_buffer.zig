const std = @import("std");
const ecs = @import("index.zig");
const NoAlloc = @import("../no_alloc.zig").NoAlloc;
const Handle = ecs.entities.Handle;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

const EntityHandle = ecs.entities.Handle;

pub fn CommandBuffer(comptime Entities: type) type {
    const parenting = ecs.parenting.init(Entities);
    const prefabs = ecs.prefabs.init(Entities);
    const ArchetypeChange = Entities.ArchetypeChange;
    const ArchetypeChangeCommand = struct {
        handle: Handle,
        change: ArchetypeChange,
    };
    const PrefabEntity = Entities.PrefabEntity;

    return struct {
        const PrefabHandle = prefabs.Handle;
        pub const Descriptor = struct {
            prefab_capacity: usize,
            prefab_entity_capacity: usize,
            remove_capacity: usize,
            arch_change_capacity: usize,
        };
        pub const PrefabSpan = prefabs.Span;

        entities: *Entities,
        prefab_spans: ArrayListUnmanaged(PrefabSpan),
        prefab_entities: ArrayListUnmanaged(PrefabEntity),
        prefab_temporary: []u8,
        remove: ArrayListUnmanaged(Handle),
        arch_change: ArrayListUnmanaged(ArchetypeChangeCommand),

        pub fn init(allocator: Allocator, entities: *Entities, desc: Descriptor) Allocator.Error!@This() {
            assert(desc.prefab_entity_capacity < std.math.maxInt(EntityHandle.Index));

            var prefab_entities = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, desc.prefab_entity_capacity);
            errdefer prefab_entities.deinit(allocator);

            var prefab_spans = try ArrayListUnmanaged(PrefabSpan).initCapacity(allocator, desc.prefab_capacity);
            errdefer prefab_spans.deinit(allocator);

            var prefab_temporary = try allocator.alloc(u8, @sizeOf(EntityHandle) * desc.prefab_capacity);
            errdefer allocator.free(prefab_temporary);

            var remove = try ArrayListUnmanaged(Handle).initCapacity(allocator, desc.remove_capacity);
            errdefer remove.deinit(allocator);

            var arch_change = try ArrayListUnmanaged(ArchetypeChangeCommand).initCapacity(allocator, desc.arch_change_capacity);
            errdefer arch_change.deinit(allocator);

            return .{
                .entities = entities,
                .prefab_entities = prefab_entities,
                .prefab_spans = prefab_spans,
                .prefab_temporary = prefab_temporary,
                .remove = remove,
                .arch_change = arch_change,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.prefab_entities.deinit(allocator);
            self.prefab_spans.deinit(allocator);
            allocator.free(self.prefab_temporary);
            self.remove.deinit(allocator);
            self.arch_change.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.prefab_entities.clearRetainingCapacity();
            self.prefab_spans.clearRetainingCapacity();
            self.remove.clearRetainingCapacity();
            self.arch_change.clearRetainingCapacity();
        }

        /// Appends an instantiate prefab command, and returns the prefab handle of the first prefab entity in the list
        /// to be instantiated if the list is not empty.
        pub fn appendInstantiate(self: *@This(), self_contained: bool, prefab: []const PrefabEntity) ?PrefabHandle {
            return self.appendInstantiateChecked(self_contained, prefab) catch |err|
                std.debug.panic("append instantiate failed: {}", .{err});
        }

        pub fn appendInstantiateChecked(self: *@This(), self_contained: bool, prefab: []const PrefabEntity) Allocator.Error!?PrefabHandle {
            if (prefab.len == 0) return null;
            const handle = PrefabHandle.init(@intCast(EntityHandle.Index, self.prefab_entities.items.len));
            try self.prefab_entities.appendSlice(NoAlloc, prefab);
            try self.prefab_spans.append(NoAlloc, PrefabSpan{ .len = prefab.len, .self_contained = self_contained });
            return handle;
        }

        pub fn appendRemove(self: *@This(), handle: Handle) void {
            self.appendRemoveChecked(handle) catch |err|
                std.debug.panic("append remove failed: {}", .{err});
        }

        pub fn appendRemoveChecked(self: *@This(), handle: Handle) error{ DoubleFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.DoubleFree;
            }
            try self.remove.append(NoAlloc, handle);
        }

        pub fn appendArchChange(self: *@This(), handle: Handle, change: ArchetypeChange) void {
            self.appendArchChangeChecked(handle, change) catch |err|
                std.debug.panic("append arch change failed: {}", .{err});
        }

        pub fn appendArchChangeChecked(self: *@This(), handle: Handle, change: ArchetypeChange) error{ UseAfterFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.UseAfterFree;
            }
            try self.arch_change.append(NoAlloc, .{
                .handle = handle,
                .change = change,
            });
        }

        pub fn executeChecked(self: *@This()) Allocator.Error!void {
            // Execute removals
            for (self.remove.items) |handle| {
                self.entities.swapRemoveChecked(handle) catch |err| switch (err) {
                    // We already checked for this error when the command was added, so we ignore it
                    // here since another thread could have queued up a delete before execution.
                    error.DoubleFree => {},
                };
            }

            // Execute archetype changes
            for (self.arch_change.items) |c| {
                self.entities.changeArchetypeChecked(c.handle, c.change) catch |err| switch (err) {
                    // We already checked for this error when the command was added, so we ignore it
                    // here since another thread could have queued up a delete before execution.
                    error.UseAfterFree => {},
                    // We still want to report out of memory errors!
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }

            // Instantiate prefabs
            var prefab_fba = FixedBufferAllocator.init(self.prefab_temporary);
            try prefabs.instantiateSpansChecked(
                prefab_fba.allocator(),
                self.entities,
                self.prefab_entities.items,
                self.prefab_spans.items,
            );

            // Remove orphans
            if (parenting) |p| {
                if (self.remove.items.len > 0) {
                    p.removeOrphans(self.entities);
                }
            }
        }

        pub fn execute(self: *@This()) void {
            self.executeChecked() catch |err|
                std.debug.panic("execute failed: {}", .{err});
        }
    };
}

test "basics" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .a = u8,
        .b = u8,
        .c = u8,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);
    const PrefabHandle = prefabs.Handle;
    const ComponentFlags = Entities.ComponentFlags;
    const helper = struct {
        fn fillCommandBuffer(
            command_buffer: *CommandBuffer(Entities),
            remove: ?struct { a: EntityHandle, b: EntityHandle, c: EntityHandle },
            keep: EntityHandle,
        ) !void {
            // Instantiate
            {
                try expectEqual(command_buffer.appendInstantiate(
                    true,
                    &[_]PrefabEntity{.{ .a = 0 }},
                ).?, PrefabHandle.init(0));
                try expectEqual(command_buffer.appendInstantiate(
                    true,
                    &[_]PrefabEntity{.{ .a = 1 }},
                ).?, PrefabHandle.init(1));
                try expectEqual(command_buffer.appendInstantiateChecked(
                    true,
                    &[_]PrefabEntity{.{ .a = 2 }},
                ), error.OutOfMemory);
            }

            // Remove
            if (remove) |r| {
                command_buffer.appendRemove(r.a);
                command_buffer.appendRemove(r.a); // It's okay to remove it twice via the command buffer
                command_buffer.appendRemove(r.b);
                try expectEqual(command_buffer.appendRemoveChecked(r.c), error.DoubleFree);
                try expectEqual(command_buffer.appendRemoveChecked(r.b), error.OutOfMemory);
            } else {
                command_buffer.appendRemove(keep);
                command_buffer.appendRemove(keep);
                command_buffer.appendRemove(keep);
                try expectEqual(command_buffer.appendRemoveChecked(keep), error.OutOfMemory);
            }

            // Arch change
            {
                // It's okay to try to change archetypes of entities that *will* be removed but haven't been yet
                command_buffer.appendArchChange(if (remove) |r| r.b else keep, .{
                    .add = .{
                        .b = 10,
                    },
                    .remove = ComponentFlags.init(.{ .a, .c }),
                });

                // Appending arch changes to entities that have already been removed should error
                if (remove) |r| {
                    try expectEqual(command_buffer.appendArchChangeChecked(r.c, .{
                        .add = .{
                            .b = 10,
                        },
                        .remove = ComponentFlags.init(.{ .a, .c }),
                    }), error.UseAfterFree);
                }

                // Test removing a component and adding new components
                command_buffer.appendArchChange(keep, .{
                    .add = .{
                        .b = 20,
                    },
                    .remove = ComponentFlags.init(.{ .a, .c }),
                });

                // Test removing and adding the same component at the same time
                command_buffer.appendArchChange(keep, .{
                    .add = .{
                        .a = 100,
                    },
                    .remove = ComponentFlags.init(.{.a}),
                });

                try expectEqual(command_buffer.appendArchChangeChecked(keep, .{
                    .add = .{
                        .b = 10,
                    },
                    .remove = ComponentFlags.init(.{ .a, .c }),
                }), error.OutOfMemory);
            }
        }
    };

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    var command_buffer = try CommandBuffer(Entities).init(allocator, &entities, .{
        .prefab_entity_capacity = 2,
        .prefab_capacity = 2,
        .remove_capacity = 3,
        .arch_change_capacity = 3,
    });
    defer command_buffer.deinit(allocator);

    // Initialize the ecs with some entities
    const a = entities.create(.{});
    const b = entities.create(.{});
    const c = entities.create(.{});
    const keep = entities.create(.{ .a = 10 });

    entities.swapRemove(c); // Removing it before creating the command buffer should result in error
    try helper.fillCommandBuffer(&command_buffer, .{ .a = a, .b = b, .c = c }, keep);
    entities.swapRemove(a); // It's okay to remove it before the command buffer does

    // Execute and check the results
    {
        command_buffer.execute();
        try expectEqual(entities.len(), 3);

        var a_0: usize = 0;
        var a_1: usize = 0;
        var a_100_b_20: usize = 0;

        var iter = entities.iterator(.{
            .a = .{ .optional = true },
            .b = .{ .optional = true },
            .c = .{ .optional = true },
        });
        while (iter.next()) |entity| {
            try expectEqual(entity.c, null);
            if (entity.a != null and entity.b == null) {
                if (entity.a.?.* == 0) a_0 += 1;
                if (entity.a.?.* == 1) a_1 += 1;
            }

            if (entity.a != null and entity.b != null) {
                if (entity.a.?.* == 100 and entity.b.?.* == 20) a_100_b_20 += 1;
            }
        }

        try expectEqual(a_0, 1);
        try expectEqual(a_1, 1);
        try expectEqual(a_100_b_20, 1);
    }

    // Test re-running the command buffer
    {
        // Undo the changes to keep to make sure they get reapplied
        entities.changeArchetype(keep, .{
            .add = .{
                .a = 123,
            },
            .remove = ComponentFlags.init(.{ .b, .c }),
        });
        try expectEqual(entities.getComponent(keep, .a).?.*, 123);
        try expectEqual(entities.getComponent(keep, .b), null);
        try expectEqual(entities.getComponent(keep, .c), null);

        // Rerun the command buffer
        command_buffer.execute();
        try expectEqual(entities.len(), 5);

        var a_0: usize = 0;
        var a_1: usize = 0;
        var a_100_b_20: usize = 0;

        var iter = entities.iterator(.{
            .a = .{ .optional = true },
            .b = .{ .optional = true },
            .c = .{ .optional = true },
        });
        while (iter.next()) |entity| {
            try expectEqual(entity.c, null);
            if (entity.a != null and entity.b == null) {
                if (entity.a.?.* == 0) a_0 += 1;
                if (entity.a.?.* == 1) a_1 += 1;
            }

            if (entity.a != null and entity.b != null) {
                if (entity.a.?.* == 100 and entity.b.?.* == 20) a_100_b_20 += 1;
            }
        }

        try expectEqual(a_0, 2);
        try expectEqual(a_1, 2);
        try expectEqual(a_100_b_20, 1);
    }

    // Test running a cleared command buffer
    {
        entities.changeArchetype(keep, .{
            .add = .{
                .a = 123,
            },
            .remove = ComponentFlags.init(.{ .b, .c }),
        });
        try expectEqual(entities.getComponent(keep, .a).?.*, 123);
        try expectEqual(entities.getComponent(keep, .b), null);
        try expectEqual(entities.getComponent(keep, .c), null);

        command_buffer.clearRetainingCapacity();
        command_buffer.execute();
        try expectEqual(entities.len(), 5);

        var a_0: usize = 0;
        var a_1: usize = 0;
        var a_123: usize = 0;

        var iter = entities.iterator(.{
            .a = .{ .optional = true },
            .b = .{ .optional = true },
            .c = .{ .optional = true },
        });
        while (iter.next()) |entity| {
            try expectEqual(entity.c, null);
            if (entity.a != null and entity.b == null) {
                if (entity.a.?.* == 0) a_0 += 1;
                if (entity.a.?.* == 1) a_1 += 1;
            }

            if (entity.a != null and entity.b == null) {
                if (entity.a.?.* == 123) a_123 += 1;
            }
        }

        try expectEqual(a_0, 2);
        try expectEqual(a_1, 2);
        try expectEqual(a_123, 1);
    }

    // Test re-filling the command buffer. If we failed to clear one of the fields, it'll run out of
    // memory and we'll catch that here!
    try helper.fillCommandBuffer(&command_buffer, null, keep);

    // XXX: tests:
    // * [x] init
    // * [x] deinit
    // * [x] clearRetainingCapacity
    //     * [x] test double execution!
    // * [x] appendInstantiate
    // * [x] appendInstantiateChecked
    //     * [ ] test patching, including in nested types, maybe of multiple types
    //     * [ ] only test patching that's specific to command buffer though, if possible do it in that module instead!
    //     * [ ] maybe just the limits around prefabs vs prefab entities and whether self contained works right, minimally?
    // * [x] appendRemove
    // * [x] appendRemoveChecked
    // * [x] appendArchChange
    // * [x] appendArchChangeChecked
    // * [ ] executeChecked
    //      * [ ] test this resulting in out of memory or not worth it?
    // * [x] execute
}
