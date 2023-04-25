const std = @import("std");
const ecs = @import("index.zig");
const NoAlloc = @import("../no_alloc.zig").NoAlloc;
const Handle = ecs.entities.Handle;
const PrefabHandle = ecs.prefab.PrefabHandle;
const Allocator = std.mem.Allocator;
const parenting = ecs.parenting;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub fn CommandBuffer(comptime Entities: type) type {
    return struct {
        pub const Descriptor = struct {
            prefab_entity_capacity: usize,
            remove_capacity: usize,
            arch_change_capacity: usize,
        };

        const PrefabEntity = ecs.entities.PrefabEntity(Entities);
        const ArchetypeChange = ecs.entities.ArchetypeChange(Entities);
        const ArchetypeChangeCommand = struct {
            handle: Handle,
            change: ArchetypeChange,
        };

        entities: *Entities,
        prefab_entities: ArrayListUnmanaged(PrefabEntity),
        remove: ArrayListUnmanaged(Handle),
        arch_change: ArrayListUnmanaged(ArchetypeChangeCommand),

        pub fn init(allocator: Allocator, entities: *Entities, desc: Descriptor) Allocator.Error!@This() {
            var prefab_entities = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, desc.prefab_entity_capacity);
            errdefer prefab_entities.deinit(allocator);

            var remove = try ArrayListUnmanaged(Handle).initCapacity(allocator, desc.remove_capacity);
            errdefer remove.deinit(allocator);

            var arch_change = try ArrayListUnmanaged(ArchetypeChangeCommand).initCapacity(allocator, desc.arch_change_capacity);
            errdefer arch_change.deinit(allocator);

            return .{
                .entities = entities,
                .prefab_entities = prefab_entities,
                .remove = remove,
                .arch_change = arch_change,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.prefab_entities.deinit(allocator);
            self.remove.deinit(allocator);
            self.arch_change.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.prefab_entities.clearRetainingCapacity();
            self.remove.clearRetainingCapacity();
            self.arch_change.clearRetainingCapacity();
        }

        // XXX: rename to createPrefab or instantiatePrefab or is this fine? create implies one entity
        // XXX: make fancier lower level interface that lets you append sizes and individual prefab entities
        // seprately, and call that from here? or can just access the fields directly for that..?
        // XXX: a little weird that it returns a handle to the first one, could just say you gotta do that from the
        // outside.
        pub fn appendInstantiate(self: *@This(), prefab: []const PrefabEntity) PrefabHandle {
            return self.appendInstantiateChecked(prefab) catch |err|
                std.debug.panic("append instantiate failed: {}", .{err});
        }

        pub fn appendInstantiateChecked(self: *@This(), prefab: []const PrefabEntity) Allocator.Error!PrefabHandle {
            // XXX: make helper, use here and outside...avoid explciit u20 cast etc. used multiple places outside.
            const handle = ecs.prefab.createHandle(@intCast(u20, self.prefab_entities.items.len));
            try self.prefab_entities.appendSlice(NoAlloc, prefab);
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
            {
                // XXX: temp gpa...
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                try ecs.prefab.instantiateChecked(gpa.allocator(), self.entities, self.prefab_entities.items);
            }

            // Execute parenting
            if (parenting.supported(Entities) and self.remove.items.len > 0) {
                parenting.removeOrphans(self.entities);
            }
        }

        pub fn execute(self: *@This()) void {
            self.executeChecked() catch |err|
                std.debug.panic("execute failed: {}", .{err});
        }
    };
}
