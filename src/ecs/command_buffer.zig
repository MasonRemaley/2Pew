const std = @import("std");
const ecs = @import("index.zig");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// XXX: test this or is it simple enough that it doesn't need it?
// XXX: taking entities vs registered components?
pub fn CommandBuffer(comptime Entities: anytype) type {
    const Prefab = Entities.Prefab;
    const Handle = Entities.Handle;

    return struct {
        pub const Config = struct {
            create_capacity: usize,
            remove_capacity: usize,
        };

        entities: *Entities,
        create: ArrayListUnmanaged(Prefab),
        remove: ArrayListUnmanaged(Handle),
        // XXX: add shape changing stuff here too...

        pub fn init(allocator: Allocator, entities: *Entities, config: Config) Allocator.Error!@This() {
            var create = try ArrayListUnmanaged(Prefab).initCapacity(allocator, config.create_capacity);
            errdefer create.deinit(allocator);

            var remove = try ArrayListUnmanaged(Handle).initCapacity(allocator, config.remove_capacity);
            errdefer remove.deinit(allocator);

            return .{
                .entities = entities,
                .create = create,
                .remove = remove,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.create.deinit(allocator);
            self.remove.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.create.clearRetainingCapacity();
            self.remove.clearRetainingCapacity();
        }

        // XXX: somewhere else we manually set an arrays size when we could've just used an arraylist,
        // do this there too? i think in slot map? still woudl be nice to wrap tbh and just have it automatically
        // fail when at capacity, or to make own type that does this. would make this simpler--wouldn't even need
        // functions for this then could just call append on those directly.
        // oh wait no we can't cause we wanna do error checking. but still would be a nice structure to have!
        pub fn appendCreate(self: *@This(), prefab: Prefab) void {
            self.appendCreateChecked(prefab) catch |err|
                std.debug.panic("appendCreate failed: {}", .{err});
        }

        pub fn appendCreateChecked(self: *@This(), prefab: Prefab) error{AtCapacity}!void {
            if (self.create.items.len >= self.create.capacity) {
                return error.AtCapacity;
            }
            self.create.appendAssumeCapacity(prefab);
        }

        pub fn appendRemove(self: *@This(), handle: Handle) void {
            self.appendRemoveChecked(handle) catch |err|
                std.debug.panic("appendRemove failed: {}", .{err});
        }

        pub fn appendRemoveChecked(self: *@This(), handle: Handle) error{ AtCapacity, DoubleFree }!void {
            if (!self.entities.exists(handle)) {
                return error.DoubleFree;
            }
            if (self.remove.items.len >= self.remove.capacity) {
                return error.AtCapacity;
            }
            self.remove.appendAssumeCapacity(handle);
        }

        // XXX: errors should be checked on add not on execute! on execute other stuff could've happened
        // e.g. if multi threaded and wanna let it siletnly work out since it'll be the same either way
        // XXX: annotate which errors?
        pub fn executeChecked(self: *@This()) !void {
            for (self.remove.items) |handle| {
                self.entities.swapRemoveChecked(handle) catch |err| switch (err) {
                    // We already checked for this error when the command was added, so we ignore it
                    // here since another thread could have queued up a delete before execution.
                    // XXX: required even if not annoated right?
                    error.DoubleFree => {},
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
