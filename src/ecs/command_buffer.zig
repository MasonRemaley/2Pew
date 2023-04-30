const std = @import("std");
const ecs = @import("index.zig");
const NoAlloc = @import("../no_alloc.zig").NoAlloc;
const Handle = ecs.entities.Handle;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

pub fn CommandBuffer(comptime Entities: type) type {
    const parenting = ecs.parenting.init(Entities);
    const prefabs = ecs.prefabs.init(Entities);
    const ArchetypeChange = Entities.ArchetypeChange;
    const ArchetypeChangeCommand = struct {
        handle: Handle,
        change: ArchetypeChange,
    };
    const PrefabEntity = Entities.PrefabEntity;
    const EntityHandle = ecs.entities.Handle;

    return struct {
        pub const PrefabHandle = prefabs.Handle;
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
