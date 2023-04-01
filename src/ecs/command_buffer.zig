const std = @import("std");
const ecs = @import("index.zig");
const Allocator = std.mem.Allocator;
const BoundedArrayList = @import("../bounded_array_list.zig").BoundedArrayList;

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
        create: BoundedArrayList(Prefab),
        remove: BoundedArrayList(Handle),
        arch_change: BoundedArrayList(ArchetypeChangeCommand),

        pub fn init(allocator: Allocator, entities: *Entities, config: Config) Allocator.Error!@This() {
            var create = try BoundedArrayList(Prefab).init(allocator, config.create_capacity);
            errdefer create.deinit(allocator);

            var remove = try BoundedArrayList(Handle).init(allocator, config.remove_capacity);
            errdefer remove.deinit(allocator);

            var arch_change = try BoundedArrayList(ArchetypeChangeCommand).init(allocator, config.arch_change_capacity);
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

        pub fn appendCreate(self: *@This(), prefab: Prefab) void {
            self.appendCreateChecked(prefab) catch |err|
                std.debug.panic("append create failed: {}", .{err});
        }

        pub fn appendCreateChecked(self: *@This(), prefab: Prefab) Allocator.Error!void {
            try self.create.append(prefab);
        }

        pub fn appendRemove(self: *@This(), handle: Handle) void {
            self.appendRemoveChecked(handle) catch |err|
                std.debug.panic("append remove failed: {}", .{err});
        }

        pub fn appendRemoveChecked(self: *@This(), handle: Handle) error{ DoubleFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.DoubleFree;
            }
            try self.remove.append(handle);
        }

        pub fn appendArchChange(self: *@This(), handle: Handle, change: ArchetypeChange) void {
            self.appendArchChangeChecked(handle, change) catch |err|
                std.debug.panic("append arch change failed: {}", .{err});
        }

        pub fn appendArchChangeChecked(self: *@This(), handle: Handle, change: ArchetypeChange) error{ UseAfterFree, OutOfMemory }!void {
            if (!self.entities.exists(handle)) {
                return error.UseAfterFree;
            }
            try self.arch_change.append(.{
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
