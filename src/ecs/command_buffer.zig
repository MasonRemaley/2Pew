const std = @import("std");
const ecs = @import("index.zig");
const NoAlloc = @import("../no_alloc.zig").NoAlloc;
const Handle = ecs.entities.Handle;
const Allocator = std.mem.Allocator;
const parenting = ecs.parenting;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const DeferredHandle = union(enum) {
    handle: Handle,
    index: usize,
};

pub fn CommandBuffer(comptime Entities: type) type {
    return struct {
        pub const Descriptor = struct {
            prefab_entity_capacity: usize,
            prefab_capacity: usize,
            create_capacity: usize,
            remove_capacity: usize,
            arch_change_capacity: usize,
            parent_capacity: usize,
        };

        const PrefabEntity = ecs.entities.PrefabEntity(Entities);
        const ArchetypeChange = ecs.entities.ArchetypeChange(Entities);
        const ArchetypeChangeCommand = struct {
            handle: Handle,
            change: ArchetypeChange,
        };
        const ParentCommand = struct {
            parent: ?DeferredHandle,
            child: DeferredHandle,
        };

        entities: *Entities,
        prefab_entities: ArrayListUnmanaged(PrefabEntity),
        prefab_lens: ArrayListUnmanaged(usize),
        // XXX: remove all references to create once all moved to new system!
        // XXX: remove all deferred handle stuff too then (can defer appending the prefab len if we really need
        // that to work.)
        create: ArrayListUnmanaged(PrefabEntity),
        remove: ArrayListUnmanaged(Handle),
        arch_change: ArrayListUnmanaged(ArchetypeChangeCommand),
        parent: ArrayListUnmanaged(ParentCommand),

        created: ArrayListUnmanaged(Handle),

        pub fn init(allocator: Allocator, entities: *Entities, desc: Descriptor) Allocator.Error!@This() {
            var prefab_entities = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, desc.prefab_entity_capacity);
            errdefer prefab_entities.deinit(allocator);

            var prefab_lens = try ArrayListUnmanaged(usize).initCapacity(allocator, desc.prefab_capacity);
            errdefer prefab_lens.deinit(allocator);

            var create = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, desc.create_capacity);
            errdefer create.deinit(allocator);

            var remove = try ArrayListUnmanaged(Handle).initCapacity(allocator, desc.remove_capacity);
            errdefer remove.deinit(allocator);

            var arch_change = try ArrayListUnmanaged(ArchetypeChangeCommand).initCapacity(allocator, desc.arch_change_capacity);
            errdefer arch_change.deinit(allocator);

            var parent = try ArrayListUnmanaged(ParentCommand).initCapacity(allocator, desc.arch_change_capacity);
            errdefer arch_change.deinit(allocator);

            var created = try ArrayListUnmanaged(Handle).initCapacity(allocator, desc.create_capacity);
            errdefer created.deinit(allocator);

            return .{
                .entities = entities,
                .prefab_entities = prefab_entities,
                .prefab_lens = prefab_lens,
                .create = create,
                .remove = remove,
                .arch_change = arch_change,
                .parent = parent,
                .created = created,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.prefab_entities.deinit(allocator);
            self.prefab_lens.deinit(allocator);
            self.create.deinit(allocator);
            self.remove.deinit(allocator);
            self.arch_change.deinit(allocator);
            self.parent.deinit(allocator);
            self.created.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.prefab_entities.clearRetainingCapacity();
            self.prefab_lens.clearRetainingCapacity();
            self.create.clearRetainingCapacity();
            self.remove.clearRetainingCapacity();
            self.arch_change.clearRetainingCapacity();
            self.parent.clearRetainingCapacity();
        }

        // XXX: make fancier lower level interface that lets you append sizes and individual prefab entities
        // seprately, and call that from here? or can just access the fields directly for that..?
        pub fn appendInstantiate(self: *@This(), prefab: []const PrefabEntity) void {
            self.appendInstantiateChecked(prefab) catch |err|
                std.debug.panic("append instantiate failed: {}", .{err});
        }

        pub fn appendInstantiateChecked(self: *@This(), prefab: []const PrefabEntity) Allocator.Error!void {
            try self.prefab_entities.appendSlice(NoAlloc, prefab);
            try self.prefab_lens.append(NoAlloc, prefab.len);
        }

        pub fn appendCreate(self: *@This(), prefab: PrefabEntity) DeferredHandle {
            return self.appendCreateChecked(prefab) catch |err|
                std.debug.panic("append create failed: {}", .{err});
        }

        pub fn appendCreateChecked(self: *@This(), prefab: PrefabEntity) Allocator.Error!DeferredHandle {
            const handle = DeferredHandle{ .index = self.create.items.len };
            try self.create.append(NoAlloc, prefab);
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

        fn checkDeferredHandle(self: *@This(), deferred: DeferredHandle) error{ UseAfterFree, OutOfBounds }!void {
            switch (deferred) {
                .handle => |handle| if (!self.entities.exists(handle)) return error.UseAfterFree,
                .index => |index| if (index >= self.create.items.len) return error.OutOfBounds,
            }
        }

        fn resolveDeferredHandle(self: @This(), deferred: DeferredHandle) Handle {
            switch (deferred) {
                .handle => |handle| return handle,
                .index => |index| return self.created.items[index],
            }
        }

        pub fn appendParent(self: *@This(), child: DeferredHandle, parent: ?DeferredHandle) void {
            return self.appendParentChecked(child, parent) catch |err|
                std.debug.panic("append parent failed: {}", .{err});
        }

        pub fn appendParentChecked(self: *@This(), child: DeferredHandle, parent: ?DeferredHandle) error{ UseAfterFree, OutOfBounds, OutOfMemory }!void {
            parenting.requireSupport(Entities);

            try self.checkDeferredHandle(child);
            if (parent) |p| try self.checkDeferredHandle(p);

            // If the the child hasn't been created yet, make sure it gets created with a parent
            // component (initialized to null) to prevent needlessly creating as one archetype then
            // changing to another.
            if (child == .index) {
                self.create.items[child.index].parent = @as(?Handle, null);
            }

            try self.parent.append(NoAlloc, .{
                .child = child,
                .parent = parent,
            });
        }

        pub fn executeChecked(self: *@This()) Allocator.Error!void {
            // Clear the created buffer
            self.created.clearRetainingCapacity();

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

                var end: usize = 0;
                for (self.prefab_lens.items) |len| {
                    const start = end;
                    end += len;
                    try ecs.prefab.instantiateChecked(gpa.allocator(), self.entities, self.prefab_entities.items[start..end]);
                }
            }

            // Execute creations
            for (self.create.items) |prefab| {
                self.created.append(NoAlloc, try self.entities.createChecked(prefab)) catch unreachable;
            }

            // Execute parenting
            if (parenting.supported(Entities)) {
                // Set parents
                for (self.parent.items) |cmd| {
                    const child = self.resolveDeferredHandle(cmd.child);
                    const new_parent = if (cmd.parent) |p| self.resolveDeferredHandle(p) else null;
                    parenting.setParent(self.entities, child, new_parent);
                }

                if (self.remove.items.len > 0) {
                    parenting.removeOrphans(self.entities);
                }
            }
        }

        pub fn execute(self: *@This()) void {
            self.executeChecked() catch |err|
                std.debug.panic("execute failed: {}", .{err});
        }
    };
}
