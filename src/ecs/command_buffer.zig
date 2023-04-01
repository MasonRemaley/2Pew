const std = @import("std");
const ecs = @import("index.zig");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub fn CommandBuffer(comptime Entities: anytype) type {
    const Handle = Entities.Handle;
    const Prefab = Entities.Prefab;
    const ArchetypeChange = Entities.ArchetypeChange;
    const ArchetypeChangeCommand = struct {
        handle: Handle,
        change: ArchetypeChange,
    };

    return struct {
        pub const Config = struct {
            create_capacity: usize,
            remove_capacity: usize,
            arch_change_capacity: usize,
        };

        entities: *Entities,
        create: ArrayListUnmanaged(Prefab),
        remove: ArrayListUnmanaged(Handle),
        arch_change: ArrayListUnmanaged(ArchetypeChangeCommand),

        pub fn init(allocator: Allocator, entities: *Entities, config: Config) Allocator.Error!@This() {
            var create = try ArrayListUnmanaged(Prefab).initCapacity(allocator, config.create_capacity);
            errdefer create.deinit(allocator);

            var remove = try ArrayListUnmanaged(Handle).initCapacity(allocator, config.remove_capacity);
            errdefer remove.deinit(allocator);

            var arch_change = try ArrayListUnmanaged(ArchetypeChangeCommand).initCapacity(allocator, config.arch_change_capacity);
            errdefer arch_change.deinit(allocator);

            return .{
                .entities = entities,
                .create = create,
                .remove = remove,
                .arch_change = arch_change,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.create.deinit(allocator);
            self.remove.deinit(allocator);
            self.arch_change.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.create.clearRetainingCapacity();
            self.remove.clearRetainingCapacity();
            self.arch_change.clearRetainingCapacity();
        }

        // XXX: somewhere else we manually set an arrays size when we could've just used an arraylist,
        // do this there too? i think in slot map? still woudl be nice to wrap tbh and just have it automatically
        // fail when at capacity, or to make own type that does this. would make this simpler--wouldn't even need
        // functions for this then could just call append on those directly.
        // oh wait no we can't cause we wanna do error checking. but still would be a nice structure to have!
        pub fn appendCreate(self: *@This(), prefab: Prefab) void {
            self.appendCreateChecked(prefab) catch |err|
                std.debug.panic("append create failed: {}", .{err});
        }

        pub fn appendCreateChecked(self: *@This(), prefab: Prefab) Allocator.Error!void {
            if (self.create.items.len >= self.create.capacity) {
                return error.OutOfMemory;
            }
            self.create.appendAssumeCapacity(prefab);
        }

        pub fn appendRemove(self: *@This(), handle: Handle) void {
            self.appendRemoveChecked(handle) catch |err|
                std.debug.panic("append remove failed: {}", .{err});
        }

        pub fn appendRemoveChecked(self: *@This(), handle: Handle) error{ DoubleFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.DoubleFree;
            }
            if (self.remove.items.len >= self.remove.capacity) {
                return error.OutOfMemory;
            }
            self.remove.appendAssumeCapacity(handle);
        }

        pub fn appendArchChange(self: *@This(), handle: Handle, change: ArchetypeChange) void {
            self.appendArchChangeChecked(handle, change) catch |err|
                std.debug.panic("append arch change failed: {}", .{err});
        }

        // XXX: worth testing if only to make sure bounds are respected...or wrap in something that does
        // that for us tbh.
        pub fn appendArchChangeChecked(self: *@This(), handle: Handle, change: ArchetypeChange) error{ UseAfterFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.UseAfterFree;
            }
            if (self.arch_change.items.len >= self.arch_change.capacity) {
                return error.OutOfMemory;
            }
            self.arch_change.appendAssumeCapacity(.{
                .handle = handle,
                .change = change,
            });
        }

        pub fn executeChecked(self: *@This()) Allocator.Error!void {
            for (self.remove.items) |handle| {
                self.entities.swapRemoveChecked(handle) catch |err| switch (err) {
                    // We already checked for this error when the command was added, so we ignore it
                    // here since another thread could have queued up a delete before execution.
                    error.DoubleFree => {},
                };
            }
            for (self.arch_change.items) |c| {
                self.entities.changeArchetypeChecked(c.handle, c.change) catch |err| switch (err) {
                    // We already checked for this error when the command was added, so we ignore it
                    // here since another thread could have queued up a delete before execution.
                    error.UseAfterFree => {},
                    // We still want to report out of memory errors!
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            for (self.create.items) |prefab| {
                _ = try self.entities.createChecked(prefab);
            }
        }

        pub fn execute(self: *@This()) void {
            self.executeChecked() catch |err|
                std.debug.panic("execute failed: {}", .{err});
        }
    };
}
