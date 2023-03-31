const std = @import("std");
const builtin = @import("builtin");
const SegmentedListFirstShelfCount = @import("../segmented_list.zig").SegmentedListFirstShelfCount;
const SlotMap = @import("../slot_map.zig").SlotMap;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const Type = std.builtin.Type;

const EntityGeneration = switch (builtin.mode) {
    .Debug, .ReleaseSafe => u32,
    .ReleaseSmall, .ReleaseFast => u0,
};

pub const max_entities: u32 = 1000000;
const page_size = 4096;

const max_pages = max_entities / 32;
const max_archetypes = 40000;
const first_shelf_count = 8;

pub fn Entities(comptime registered_components: anytype) type {
    return struct {
        // Meta programming to get the component names and types
        const ComponentName = std.meta.FieldEnum(@TypeOf(registered_components));

        const component_types = field_values(registered_components);
        const component_names = std.meta.fieldNames(@TypeOf(registered_components));

        fn find_component_name(comptime name: []const u8) ?ComponentName {
            const index = std.meta.fieldIndex(@TypeOf(registered_components), name);
            return @intToEnum(ComponentName, index orelse return null);
        }

        // Public types used by the ECS
        pub const Handle = HandleSlotMap.Handle;

        // Internal types used by the ECS
        const EntityPointer = struct {
            archetype_list: *ArchetypeList,
            index: u32, // TODO: how did we decide on u32 here?
        };
        const HandleSlotMap = SlotMap(EntityPointer, max_entities, EntityGeneration);
        const Archetype: type = std.bit_set.IntegerBitSet(component_names.len);
        // TODO: how many places do we generate a new type from entity? might wanna make a helper for this?
        pub const Prefab = prefab: {
            var fields: [component_names.len]Type.StructField = undefined;
            for (component_types, component_names, 0..) |comp_type, comp_name, i| {
                const field_type = ?comp_type;
                fields[i] = Type.StructField{
                    .name = comp_name,
                    .type = field_type,
                    .default_value = &null,
                    .is_comptime = false,
                    .alignment = @alignOf(field_type),
                };
            }
            break :prefab @Type(Type{
                .Struct = Type.Struct{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]Type.Declaration{},
                    .is_tuple = false,
                },
            });
        };
        const ArchetypeList = struct {
            const Components = components: {
                var fields: [component_names.len]Type.StructField = undefined;
                for (component_names, component_types, 0..) |comp_name, comp_type, i| {
                    const FieldType = SegmentedListFirstShelfCount(comp_type, first_shelf_count, false);
                    fields[i] = Type.StructField{
                        .name = comp_name,
                        // XXX: make the desired modifications to segmented list eventually?
                        .type = FieldType,
                        .default_value = &FieldType{},
                        .is_comptime = false,
                        .alignment = @alignOf(FieldType),
                    };
                }
                break :components @Type(Type{
                    .Struct = Type.Struct{
                        .layout = .Auto,
                        .backing_integer = null,
                        .fields = &fields,
                        .decls = &[_]Type.Declaration{},
                        .is_tuple = false,
                    },
                });
            };

            handles: SegmentedListFirstShelfCount(Handle, first_shelf_count, false) = .{},
            comps: Components = .{},
            archetype: Archetype,
            // XXX: this as a type?
            // len: HandleSlotMap.Index,

            fn init(archetype: Archetype) ArchetypeList {
                return .{ .archetype = archetype };
            }

            fn deinit(self: *@This(), allocator: Allocator) void {
                inline for (component_names) |comp_name| {
                    @field(self.comps, comp_name).deinit(allocator);
                }
                self.handles.deinit(allocator);
            }

            // XXX: better api that returns pointers so don't have to recalculate them?
            fn append(self: *@This(), allocator: Allocator, handle: Handle) Allocator.Error!u32 {
                // XXX: could optimize this logic a little since all lists are gonna match eachother, also
                // only really need one size, etc
                inline for (component_names, 0..) |comp_name, i| {
                    if (self.archetype.isSet(i)) {
                        _ = try @field(self.comps, comp_name).addOne(allocator);
                    }
                }
                const index = self.handles.len;
                try self.handles.append(allocator, handle);
                // XXX: can't overflow because fails earlier right?
                return @intCast(u32, index);
            }

            // XXX: put in (debug mode?) protection to prevent doing this while iterating? same for creating?
            // XXX: document that the ecs moves structures (so e.g. internal pointers will get invalidated). this
            // was already true but only happened when changing shape before which is less commonly done.
            fn swapRemove(self: *ArchetypeList, index: u32, slot_map: *HandleSlotMap) void {
                // XXX: instead of separate len use handles len? or fold all into same thing eventually anyway..?
                // XXX: only needed in debug mode right?
                assert(index < self.handles.len);
                inline for (component_names, 0..) |comp_name, i| {
                    if (self.archetype.isSet(i)) {
                        // XXX: here and below, i think it's okay to pop assign as lon gas we do unchecked, since
                        // the memory is guarenteed to be there right? (the problem case is swap removing if size 1)
                        var components = &@field(self.comps, comp_name);
                        components.uncheckedAt(index).* = components.pop().?;
                    }
                }
                const moved_handle = self.handles.pop().?;
                // XXX: only really need to update the generation here right?
                self.handles.uncheckedAt(index).* = moved_handle;
                // XXX: checking this in case we're deleting the last one in which case we don't wanna mess with
                // slots...? we also maybe don't wanna do the above stuff but may not matter?? is there a way to
                // make this less error prone? maybe in general don't do logic when last one, or return stuff to
                // be used outside to avoid probme based on order, etc
                if (index != self.handles.len) {
                    // XXX: don't need to check generation, always checked at public interface right? check in debug mode or no?
                    slot_map.getUnchecked(moved_handle).index = index;
                }
            }

            fn ComponentIterator(comptime component_name: ComponentName) type {
                return SegmentedListFirstShelfCount(component_types[@enumToInt(component_name)], first_shelf_count, false).Iterator;
            }

            fn componentIterator(self: *@This(), comptime component_name: ComponentName) ComponentIterator(component_name) {
                return @field(self.comps, component_names[@enumToInt(component_name)]).iterator(0);
            }

            const HandleIterator = SegmentedListFirstShelfCount(Handle, first_shelf_count, false).Iterator;

            fn handleIterator(self: *@This()) HandleIterator {
                return self.handles.iterator(0);
            }

            fn getComponent(self: *@This(), index: u32, comptime component_name: ComponentName) *component_types[@enumToInt(component_name)] {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return @field(self.comps, component_names[@enumToInt(component_name)]).uncheckedAt(index);
            }

            fn getHandle(self: *@This(), index: u32) Handle {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return self.handles.uncheckedAt(index);
            }

            fn clearRetainingCapacity(self: *@This()) void {
                self.handles.clearRetainingCapacity();
                inline for (component_names) |comp_name| {
                    @field(self.comps, comp_name).clearRetainingCapacity();
                }
            }
        };

        // Storage
        allocator: Allocator,
        slot_map: HandleSlotMap,
        archetype_lists: AutoArrayHashMapUnmanaged(Archetype, ArchetypeList),

        // The API
        // TODO: need errdefers here, and maybe elsewhere too, for the allocations. also make
        // clear when failure changes state and when it doesn't (or just don't have it do that.)
        pub fn init(allocator: Allocator) Allocator.Error!@This() {
            return .{
                .allocator = allocator,
                .slot_map = try HandleSlotMap.init(allocator),
                .archetype_lists = archetype_lists: {
                    var archetype_lists = AutoArrayHashMapUnmanaged(Archetype, ArchetypeList){};
                    // We leave room for one extra because we don't know whether or not getOrPut
                    // will allocate until afte it's done.
                    try archetype_lists.ensureTotalCapacity(allocator, max_archetypes + 1);
                    break :archetype_lists archetype_lists;
                },
            };
        }

        pub fn deinit(self: *@This()) void {
            self.slot_map.deinit(self.allocator);
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.deinit(self.allocator);
            }
            self.archetype_lists.deinit(self.allocator);
        }

        pub fn create(self: *@This(), entity: anytype) Handle {
            return self.createChecked(entity) catch |err|
                std.debug.panic("failed to create entity: {}", .{err});
        }

        fn setComponents(pointer: *const EntityPointer, components: anytype) void {
            inline for (@typeInfo(@TypeOf(components.*)).Struct.fields) |f| {
                const component_name = comptime find_component_name(f.name).?;
                if (@TypeOf(components.*) == Prefab) {
                    if (@field(components.*, f.name)) |component| {
                        pointer.archetype_list.getComponent(pointer.index, component_name).* = component;
                    }
                } else {
                    pointer.archetype_list.getComponent(pointer.index, component_name).* = @field(components.*, f.name);
                }
            }
        }

        pub fn createChecked(self: *@This(), components: anytype) Allocator.Error!Handle {
            const archetype = componentsArchetype(components);
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            const handle = try self.slot_map.create(undefined);
            const pointer = self.slot_map.getUnchecked(handle);
            pointer.* = EntityPointer{
                .archetype_list = archetype_list,
                .index = try archetype_list.append(self.allocator, handle),
            };
            setComponents(pointer, &components);
            return handle;
        }

        pub fn swapRemove(self: *@This(), entity: Handle) void {
            return self.swapRemoveChecked(entity) catch |err|
                std.debug.panic("failed to remove entity {}: {}", .{ entity, err });
        }

        pub fn swapRemoveChecked(self: *@This(), entity: Handle) error{DoubleFree}!void {
            const entity_pointer = try self.slot_map.remove(entity);
            entity_pointer.archetype_list.swapRemove(entity_pointer.index, &self.slot_map);
        }

        pub fn addComponents(self: *@This(), entity: Handle, components: anytype) void {
            self.addComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to add components: {}", .{err});
        }

        // TODO: test errors
        pub fn addComponentsChecked(self: *@This(), handle: Handle, components: anytype) error{ UseAfterFree, OutOfMemory }!void {
            try self.changeArchetype(handle, components, .{});
        }

        // TODO: return a bool indicating if it was present or no? also we could have a faster
        // hasComponents check for when you don't need the actual data?
        pub fn removeComponents(self: *@This(), entity: Handle, components: anytype) void {
            self.removeComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to remove components: {}", .{err});
        }

        // TODO: test errors
        pub fn removeComponentsChecked(self: *@This(), handle: Handle, components: anytype) error{ UseAfterFree, OutOfMemory }!void {
            try self.changeArchetype(handle, .{}, components);
        }

        fn getOrPutArchetypeList(self: *@This(), archetype: Archetype) Allocator.Error!*ArchetypeList {
            comptime assert(max_archetypes > 0);

            const entry = self.archetype_lists.getOrPutAssumeCapacity(archetype);

            if (!entry.found_existing) {
                // TODO: clean up?
                // We actually have max + 1 avaialble to make it possible to check even after creation
                // may have occurred via get or put.
                if (self.archetype_lists.count() >= max_archetypes) {
                    return error.OutOfMemory;
                }
                entry.value_ptr.* = ArchetypeList.init(archetype);
            }

            return entry.value_ptr;
        }

        // Turns a prefab, a struct of components, or a tuple of enum component names into an archetype
        // bitset.
        fn componentsArchetype(components: anytype) Archetype {
            if (@TypeOf(components) == Prefab) {
                var archetype = Archetype.initEmpty();
                inline for (comptime @typeInfo(@TypeOf(components)).Struct.fields) |field| {
                    if (@field(components, field.name) != null) {
                        archetype.set(@enumToInt(find_component_name(field.name).?));
                    }
                }
                return archetype;
            } else if (@typeInfo(@TypeOf(components)).Struct.is_tuple) {
                var archetype = Archetype.initEmpty();
                inline for (components) |c| {
                    const component: ComponentName = c;
                    archetype.set(@enumToInt(component));
                }
                return archetype;
            } else comptime {
                var archetype = Archetype.initEmpty();
                for (@typeInfo(@TypeOf(components)).Struct.fields) |field| {
                    archetype.set(@enumToInt(find_component_name(field.name).?));
                }
                return archetype;
            }
        }

        fn copyComponents(to: *const EntityPointer, from: EntityPointer, which: Archetype) void {
            inline for (0..component_names.len) |i| {
                if (which.isSet(i)) {
                    const component_name = @intToEnum(ComponentName, i);
                    to.archetype_list.getComponent(to.index, component_name).* = from.archetype_list.getComponent(from.index, component_name).*;
                }
            }
        }

        // TODO: a little weird that it takes handle and pointer. the idea is that it isn't safety checking
        // the handle so that forces you to do it outside, and prevents needlessly looking it up more than once.
        // we could just document that it doesn't safety check it though, or name it unchecekd or something idk unless
        // that makes the other errors confusing.
        // TODO: test the failure conditions here?
        // TODO: early out if no change?
        // TODO: make remove_components comptime?
        fn changeArchetype(
            self: *@This(),
            handle: Handle,
            add_components: anytype,
            remove_components: anytype,
        ) error{ UseAfterFree, OutOfMemory }!void {
            // Determine our archetype bitsets
            const pointer = try self.slot_map.get(handle);
            const previous_archetype = pointer.archetype_list.archetype;
            const components_added = componentsArchetype(add_components);
            const components_removed = componentsArchetype(remove_components);
            const archetype = previous_archetype.unionWith(components_added)
                .differenceWith(components_removed);
            const components_copied = previous_archetype.intersectWith(archetype)
                .differenceWith(components_added);

            // Create the new entity location
            const old_pointer: EntityPointer = pointer.*;
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            pointer.* = .{
                .archetype_list = archetype_list,
                .index = try archetype_list.append(self.allocator, handle),
            };

            // Set the component data at the new location
            copyComponents(pointer, old_pointer, components_copied);
            setComponents(pointer, &add_components);

            // Delete the old data
            old_pointer.archetype_list.swapRemove(old_pointer.index, &self.slot_map);
        }

        // XXX: make api clearer wrt generations, test?
        pub fn exists(self: *@This(), handle: Handle) bool {
            return self.slot_map.exists(handle);
        }

        // TODO: check assertions
        pub fn getComponentChecked(self: *@This(), entity: Handle, comptime component: ComponentName) error{UseAfterFree}!?*component_types[@enumToInt(component)] {
            // XXX: should it just return null from there or is that slower?
            const entity_pointer = try self.slot_map.get(entity);
            if (!entity_pointer.archetype_list.archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return entity_pointer.archetype_list.getComponent(entity_pointer.index, component);
        }

        pub fn getComponent(self: *@This(), entity: Handle, comptime component: ComponentName) ?*component_types[@enumToInt(component)] {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn Iterator(comptime components: anytype) type {
            return struct {
                const Components = entity: {
                    var fields: [@typeInfo(@TypeOf(components)).Struct.fields.len]Type.StructField = undefined;
                    var i = 0;
                    for (components) |component| {
                        const entity_name: ComponentName = component;
                        const FieldType = *component_types[@enumToInt(entity_name)];
                        fields[i] = Type.StructField{
                            .name = component_names[@enumToInt(entity_name)],
                            .type = FieldType,
                            .default_value = null,
                            .is_comptime = false,
                            .alignment = @alignOf(FieldType),
                        };
                        i += 1;
                    }
                    break :entity @Type(Type{
                        .Struct = Type.Struct{
                            .layout = .Auto,
                            .backing_integer = null,
                            .fields = &fields,
                            .decls = &[_]Type.Declaration{},
                            .is_tuple = false,
                        },
                    });
                };

                // TODO: maybe have a getter on the iterator for the handle since that's less often used instead of returning it here?
                const Item = struct {
                    handle: Handle,
                    comps: Components,
                };

                entities: *Entities(registered_components),
                archetype: Archetype,
                // TODO: just store index into archetype list instead of iterator now that we're storing entities too?
                archetype_lists: AutoArrayHashMapUnmanaged(Archetype, ArchetypeList).Iterator,
                archetype_list: ?*ArchetypeList,
                handle_iterator: ArchetypeList.HandleIterator,

                fn init(entities: *Entities(registered_components)) @This() {
                    return .{
                        .entities = entities,
                        // TODO: replace with getter if possible
                        .archetype = comptime archetype: {
                            var archetype = Archetype.initEmpty();
                            for (components) |field| {
                                const component_name: ComponentName = field;
                                archetype.set(@enumToInt(component_name));
                            }
                            break :archetype archetype;
                        },
                        .archetype_lists = entities.archetype_lists.iterator(),
                        .archetype_list = null,
                        // XXX: ...
                        .handle_iterator = undefined,
                    };
                }

                pub fn next(self: *@This()) ?Item {
                    while (true) {
                        // If we don't have a page list, find the next compatible archetype's page
                        // list
                        if (self.archetype_list == null) {
                            self.archetype_list = while (self.archetype_lists.next()) |page| {
                                if (page.key_ptr.supersetOf(self.archetype)) {
                                    break page.value_ptr;
                                }
                            } else return null;
                            self.handle_iterator = self.archetype_list.?.handleIterator();
                        }

                        // Get the next entity in this page list, if it exists
                        if (self.handle_iterator.peek()) |handle| {
                            var item: Item = undefined;
                            item.handle = handle.*;
                            comptime assert(@TypeOf(self.archetype_list.?.handles).prealloc_count == 0);
                            inline for (@typeInfo(Components).Struct.fields) |field| {
                                comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).prealloc_count == 0);
                                comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).first_shelf_exp == @TypeOf(self.archetype_list.?.handles).first_shelf_exp);
                                @field(item.comps, field.name) = &@field(self.archetype_list.?.comps, field.name).dynamic_segments[self.handle_iterator.shelf_index][self.handle_iterator.box_index];
                            }
                            _ = self.handle_iterator.next();
                            return item;
                        }

                        // XXX: can't we just ask for it here..?
                        self.archetype_list = null;
                    }
                }

                fn swapRemoveChecked(self: *@This()) error{NothingToRemove}!void {
                    if (self.archetype_list == null) return error.NothingToRemove;
                    _ = self.handle_iterator.prev();
                    self.entities.swapRemoveChecked(self.handle_iterator.peek().?.*) catch unreachable;
                }

                pub fn swapRemove(self: *@This()) void {
                    self.swapRemoveChecked() catch unreachable;
                }
            };
        }

        pub fn iterator(self: *@This(), components: anytype) Iterator(components) {
            return Iterator(components).init(self);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            // This empties the archetype lists, but keeps them in place. A more clever
            // implementation could also allow repurposing them for a different set of archetypes.
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.clearRetainingCapacity();
            }
            self.slot_map.clearRetainingCapacity();
        }
    };
}

fn FieldValuesType(comptime T: type) type {
    const fields = @typeInfo(T).Struct.fields;
    if (fields.len == 0) return [0]void;
    return [fields.len]fields[0].type;
}

fn field_values(s: anytype) FieldValuesType(@TypeOf(s)) {
    const fields = @typeInfo(@TypeOf(s)).Struct.fields;
    var values: FieldValuesType(@TypeOf(s)) = undefined;
    for (fields, 0..) |field, i| {
        values[i] = @field(s, field.name);
    }
    return values;
}

test "iter remove" {
    var allocator = std.heap.page_allocator;

    // Remove from the beginning
    {
        var entities = try Entities(.{ .x = u32 }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20 });
        const e3 = entities.create(.{ .x = 30 });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponentChecked(e0, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }
    }

    // Remove from the middle
    {
        var entities = try Entities(.{ .x = u32 }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20 });
        const e3 = entities.create(.{ .x = 30 });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponentChecked(e1, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }
    }

    // Remove from the end
    {
        var entities = try Entities(.{ .x = u32 }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20 });
        const e3 = entities.create(.{ .x = 30 });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            iter.swapRemove();
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponentChecked(e3, .x) == error.UseAfterFree);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }
    }

    // Removing everything!
    {
        var entities = try Entities(.{ .x = u32 }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20 });
        const e3 = entities.create(.{ .x = 30 });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponentChecked(e0, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponentChecked(e1, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponentChecked(e2, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponentChecked(e3, .x) == error.UseAfterFree);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next() == null);
        }
    }

    // Removing before starting or after finishing
    {
        var entities = try Entities(.{ .x = u32 }).init(allocator);
        defer entities.deinit();

        _ = entities.create(.{ .x = 0 });
        _ = entities.create(.{ .x = 10 });
        _ = entities.create(.{ .x = 20 });
        _ = entities.create(.{ .x = 30 });

        var iter = entities.iterator(.{.x});
        try std.testing.expect(iter.swapRemoveChecked() == error.NothingToRemove);
        for (0..5) |_| {
            _ = iter.next();
        }
        try std.testing.expect(iter.swapRemoveChecked() == error.NothingToRemove);
    }

    // Removing last of first archetype
    {
        var entities = try Entities(.{ .x = u32, .y = void }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20, .y = {} });
        const e3 = entities.create(.{ .x = 30, .y = {} });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next().?.comps.x.* == 30);
        }

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponentChecked(e1, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);
    }

    // Removing first of last archetype
    {
        var entities = try Entities(.{ .x = u32, .y = void }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{ .x = 0 });
        const e1 = entities.create(.{ .x = 10 });
        const e2 = entities.create(.{ .x = 20, .y = {} });
        const e3 = entities.create(.{ .x = 30, .y = {} });

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 20);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.comps.x.* == 30);
        }

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.comps.x.* == 0);
            try std.testing.expect(iter.next().?.comps.x.* == 10);
            try std.testing.expect(iter.next().?.comps.x.* == 30);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponentChecked(e2, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);
    }

    // XXX: what if we're in between archetype lists? does it work right there? i THINK so? but should test it...
    // XXX: use in game!
}

test "clear retaining capacity" {
    var allocator = std.heap.page_allocator;

    // Remove from the beginning
    {
        var entities = try Entities(.{ .x = u32, .y = u32 }).init(allocator);
        defer entities.deinit();

        const e0 = entities.create(.{});
        const e1 = entities.create(.{});
        const x0 = entities.create(.{ .x = 10 });
        const x1 = entities.create(.{ .x = 20 });
        const y0 = entities.create(.{ .y = 30 });
        const y1 = entities.create(.{ .y = 40 });
        const xy0 = entities.create(.{ .x = 50, .y = 60 });
        const xy1 = entities.create(.{ .x = 70, .y = 80 });
        const first_batch = [_]@TypeOf(entities).Handle{ e0, e1, x0, x1, y0, y1, xy0, xy1 };

        entities.clearRetainingCapacity();

        for (first_batch) |e| {
            try std.testing.expect(entities.getComponentChecked(e, .x) == error.UseAfterFree);
            try std.testing.expect(entities.getComponentChecked(e, .y) == error.UseAfterFree);
        }

        const e0_new = entities.create(.{});
        const e1_new = entities.create(.{});
        const x0_new = entities.create(.{ .x = 11 });
        const x1_new = entities.create(.{ .x = 12 });
        const y0_new = entities.create(.{ .y = 13 });
        const y1_new = entities.create(.{ .y = 14 });
        const xy0_new = entities.create(.{ .x = 15, .y = 16 });
        const xy1_new = entities.create(.{ .x = 17, .y = 18 });
        const second_batch = [_]@TypeOf(entities).Handle{ e0_new, e1_new, x0_new, x1_new, y0_new, y1_new, xy0_new, xy1_new };

        for (first_batch) |e| {
            try std.testing.expect(entities.getComponentChecked(e, .x) == error.UseAfterFree);
            try std.testing.expect(entities.getComponentChecked(e, .y) == error.UseAfterFree);
        }

        // XXX: test iters, test getcomponent on these
        // try std.testing.expectEqual(

        for (first_batch, second_batch) |first, second| {
            var expected = first;
            expected.generation += 1;
            try std.testing.expectEqual(expected, second);
        }

        try std.testing.expect(entities.getComponent(e0_new, .x) == null);
        try std.testing.expect(entities.getComponent(e0_new, .y) == null);
        try std.testing.expect(entities.getComponent(e1_new, .x) == null);
        try std.testing.expect(entities.getComponent(e1_new, .y) == null);
        try std.testing.expect(entities.getComponent(x0_new, .x).?.* == 11);
        try std.testing.expect(entities.getComponent(x0_new, .y) == null);
        try std.testing.expect(entities.getComponent(x1_new, .x).?.* == 12);
        try std.testing.expect(entities.getComponent(x1_new, .y) == null);
        try std.testing.expect(entities.getComponent(y0_new, .x) == null);
        try std.testing.expect(entities.getComponent(y0_new, .y).?.* == 13);
        try std.testing.expect(entities.getComponent(y1_new, .x) == null);
        try std.testing.expect(entities.getComponent(y1_new, .y).?.* == 14);
        try std.testing.expect(entities.getComponent(xy0_new, .x).?.* == 15);
        try std.testing.expect(entities.getComponent(xy0_new, .y).?.* == 16);
        try std.testing.expect(entities.getComponent(xy1_new, .x).?.* == 17);
        try std.testing.expect(entities.getComponent(xy1_new, .y).?.* == 18);

        var expected = std.AutoHashMap(@TypeOf(entities).Handle, void).init(std.heap.page_allocator);
        for (second_batch) |e| {
            try expected.put(e, {});
        }
        var it = entities.iterator(.{});
        while (it.next()) |n| {
            try std.testing.expect(expected.remove(n.handle));
        }
        try std.testing.expect(expected.count() == 0);
    }
}

// XXX: use testing allocator--i think i'm leaking memory right now. that's FINE since like we're gonna use
// a fixed buffer, but wanna get it right anyway.
// Could use a more exhaustive test, this at least makes sure it compiles which was a problem
// at one point!
test "zero-sized-component" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{ .x = struct {} }).init(allocator);
    defer entities.deinit();

    const a = entities.create(.{ .x = .{} });
    const b = entities.create(.{});

    try std.testing.expect(entities.getComponent(a, .x) != null);
    try std.testing.expect(entities.getComponent(b, .x) == null);
}

// XXX: update this test or no since we have it externally?
// test "free list" {
//     var allocator = std.heap.page_allocator;
//     var entities = try Entities(.{}).init(allocator);
//     defer entities.deinit();

//     const entity_0_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_0_0, Handle{ .index = 0, .generation = 0 });
//     const entity_1_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_1_0, Handle{ .index = 1, .generation = 0 });
//     const entity_2_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_2_0, Handle{ .index = 2, .generation = 0 });
//     const entity_3_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_3_0, Handle{ .index = 3, .generation = 0 });

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 2);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 3);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

//     entities.swapRemove(entity_1_0);

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 2);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

//     entities.swapRemove(entity_3_0);

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 1);

//     _ = entities.create(.{});
//     _ = entities.create(.{});
//     _ = entities.create(.{});

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 3);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 2);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 1);
//     try std.testing.expectEqual(entities.slots[4].entity_pointer.index, 4);
//     try std.testing.expectEqual(entities.slots[4].generation, 0);
// }

test "limits" {
    // Make sure our page index type is big enough
    {
        // TODO: break this out into constant?
        const EntityPointer = Entities(.{}).EntityPointer;
        const IndexInPage = std.meta.fields(EntityPointer)[std.meta.fieldIndex(EntityPointer, "index").?].type;
        assert(std.math.maxInt(IndexInPage) > page_size);
    }

    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    const Handle = @TypeOf(entities).Handle;
    defer entities.deinit();
    var created = std.ArrayList(Handle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(Handle{ .index = @intCast(Entities(.{}).HandleSlotMap.Index, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expectError(error.OutOfMemory, entities.createChecked(.{}));
    // XXX: ...
    // const page_pool_size = entities.page_pool.items.len;

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.swapRemove(entity);
    }
    // XXX: ...
    // try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // Assert that all pages are empty
    {
        var archetype_lists = entities.archetype_lists.iterator();
        while (archetype_lists.next()) |archetype_list| {
            try std.testing.expect(archetype_list.value_ptr.handles.len == 0);
        }
    }

    // Create a bunch of entities again
    for (0..max_entities) |i| {
        try std.testing.expectEqual(
            Handle{ .index = @intCast(Entities(.{}).HandleSlotMap.Index, i), .generation = 1 },
            entities.create(.{}),
        );
    }
    try std.testing.expectError(error.OutOfMemory, entities.createChecked(.{}));
    // XXX: ...
    // try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // XXX: update this test or no since we have it externally?
    // // Wrap a generation counter
    // {
    //     const entity = Handle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
    //     entities.slots[entity.index].generation = entity.generation;
    //     entities.swapRemove(entity);
    //     try std.testing.expectEqual(
    //         Handle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
    //         entities.create(.{}),
    //     );
    // }
}

test "safety" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();

    const entity = entities.create(.{});
    entities.swapRemove(entity);
    try std.testing.expectError(error.DoubleFree, entities.swapRemoveChecked(entity));
    try std.testing.expectError(error.DoubleFree, entities.swapRemoveChecked(@TypeOf(entities).Handle{
        .index = 1,
        .generation = 0,
    }));
}

// TODO: speed up this test by replacing the allocator?
// TODO: test 0 sized components? (used in game seemingly correctly!)
test "random data" {
    const E = Entities(.{ .x = u32, .y = u8, .z = u16 });
    var allocator = std.heap.page_allocator;
    var entities = try E.init(allocator);
    defer entities.deinit();

    const Data = struct {
        x: ?u32 = null,
        y: ?u8 = null,
        z: ?u16 = null,
    };
    const Created = struct {
        data: Data,
        handle: E.Handle,
    };

    var rnd = std.rand.DefaultPrng.init(0);
    var truth = std.ArrayList(Created).init(std.testing.allocator);
    defer truth.deinit();

    for (0..4000) |_| {
        switch (rnd.random().enumValue(enum { create, modify, add, remove, destroy })) {
            .create => {
                for (0..rnd.random().uintLessThan(usize, 10)) |_| {
                    const data = Data{
                        .x = if (rnd.random().boolean()) rnd.random().int(u32) else null,
                        .y = if (rnd.random().boolean()) rnd.random().int(u8) else null,
                        .z = if (rnd.random().boolean()) rnd.random().int(u16) else null,
                    };
                    try truth.append(Created{
                        .data = data,
                        .handle = handle: {
                            if (data.x) |x| {
                                if (data.y) |y| {
                                    if (data.z) |z| {
                                        break :handle entities.create(.{ .x = x, .y = y, .z = z });
                                    }
                                }
                            }
                            if (data.x) |x| {
                                if (data.y) |y| {
                                    break :handle entities.create(.{ .x = x, .y = y });
                                }
                            }
                            if (data.x) |x| {
                                if (data.z) |z| {
                                    break :handle entities.create(.{ .x = x, .z = z });
                                }
                            }
                            if (data.y) |y| {
                                if (data.z) |z| {
                                    break :handle entities.create(.{ .y = y, .z = z });
                                }
                            }
                            if (data.x) |x| {
                                break :handle entities.create(.{ .x = x });
                            }
                            if (data.y) |y| {
                                break :handle entities.create(.{ .y = y });
                            }
                            if (data.z) |z| {
                                break :handle entities.create(.{ .z = z });
                            }
                            break :handle entities.create(.{});
                        },
                    });
                }
            },
            .modify => {
                if (truth.items.len > 0) {
                    const index = rnd.random().uintLessThan(usize, truth.items.len);
                    var entity: *Created = &truth.items[index];
                    if (entity.data.x) |_| {
                        entity.data.x = rnd.random().int(u32);
                        entities.getComponent(entity.handle, .x).?.* = entity.data.x.?;
                    }
                    if (entity.data.y) |_| {
                        entity.data.y = rnd.random().int(u8);
                        entities.getComponent(entity.handle, .y).?.* = entity.data.y.?;
                    }
                    if (entity.data.z) |_| {
                        entity.data.z = rnd.random().int(u16);
                        entities.getComponent(entity.handle, .z).?.* = entity.data.z.?;
                    }
                }
            },
            .add => {
                if (truth.items.len > 0) {
                    for (0..rnd.random().uintLessThan(usize, 10)) |_| {
                        const index = rnd.random().uintLessThan(usize, truth.items.len);
                        var entity: *Created = &truth.items[index];
                        switch (rnd.random().enumValue(enum { none, x, y, z, xy, xz, yz, xyz })) {
                            .none => {
                                entities.addComponents(entity.handle, .{});
                            },
                            .x => {
                                entity.data.x = rnd.random().int(u32);
                                entities.addComponents(entity.handle, .{
                                    .x = entity.data.x.?,
                                });
                            },
                            .y => {
                                entity.data.y = rnd.random().int(u8);
                                entities.addComponents(entity.handle, .{
                                    .y = entity.data.y.?,
                                });
                            },
                            .z => {
                                entity.data.z = rnd.random().int(u16);
                                entities.addComponents(entity.handle, .{
                                    .z = entity.data.z.?,
                                });
                            },
                            .xy => {
                                entity.data.x = rnd.random().int(u32);
                                entity.data.y = rnd.random().int(u8);
                                entities.addComponents(entity.handle, .{
                                    .x = entity.data.x.?,
                                    .y = entity.data.y.?,
                                });
                            },
                            .xz => {
                                entity.data.x = rnd.random().int(u32);
                                entity.data.z = rnd.random().int(u16);
                                entities.addComponents(entity.handle, .{
                                    .x = entity.data.x.?,
                                    .z = entity.data.z.?,
                                });
                            },
                            .yz => {
                                entity.data.y = rnd.random().int(u8);
                                entity.data.z = rnd.random().int(u16);
                                entities.addComponents(entity.handle, .{
                                    .y = entity.data.y.?,
                                    .z = entity.data.z.?,
                                });
                            },
                            .xyz => {
                                entity.data.x = rnd.random().int(u32);
                                entity.data.y = rnd.random().int(u8);
                                entity.data.z = rnd.random().int(u16);
                                entities.addComponents(entity.handle, .{
                                    .x = entity.data.x.?,
                                    .y = entity.data.y.?,
                                    .z = entity.data.z.?,
                                });
                            },
                        }
                    }
                }
            },
            .remove => {
                if (truth.items.len > 0) {
                    for (0..rnd.random().uintLessThan(usize, 10)) |_| {
                        const index = rnd.random().uintLessThan(usize, truth.items.len);
                        var entity: *Created = &truth.items[index];
                        switch (rnd.random().enumValue(enum { none, x, y, z, xy, xz, yz, xyz })) {
                            .none => {
                                entities.removeComponents(entity.handle, .{});
                            },
                            .x => {
                                entity.data.x = null;
                                entities.removeComponents(entity.handle, .{.x});
                            },
                            .y => {
                                entity.data.y = null;
                                entities.removeComponents(entity.handle, .{.y});
                            },
                            .z => {
                                entity.data.z = null;
                                entities.removeComponents(entity.handle, .{.z});
                            },
                            .xy => {
                                entity.data.x = null;
                                entity.data.y = null;
                                entities.removeComponents(entity.handle, .{ .x, .y });
                            },
                            .xz => {
                                entity.data.x = null;
                                entity.data.z = null;
                                entities.removeComponents(entity.handle, .{ .x, .z });
                            },
                            .yz => {
                                entity.data.y = null;
                                entity.data.z = null;
                                entities.removeComponents(entity.handle, .{ .y, .z });
                            },
                            .xyz => {
                                entity.data.x = null;
                                entity.data.y = null;
                                entity.data.z = null;
                                entities.removeComponents(entity.handle, .{ .x, .y, .z });
                            },
                        }
                    }
                }
            },
            .destroy => {
                for (0..rnd.random().uintLessThan(usize, 3)) |_| {
                    if (truth.items.len > 0) {
                        const index = rnd.random().uintLessThan(usize, truth.items.len);
                        const removed = truth.orderedRemove(index);
                        entities.swapRemove(removed.handle);
                    }
                }
            },
        }

        // Test that all created entities are still correct
        for (truth.items) |expected| {
            if (expected.data.x) |x| {
                try std.testing.expectEqual(x, entities.getComponent(expected.handle, .x).?.*);
            } else {
                try std.testing.expect(entities.getComponent(expected.handle, .x) == null);
            }
            if (expected.data.y) |y| {
                try std.testing.expectEqual(y, entities.getComponent(expected.handle, .y).?.*);
            } else {
                try std.testing.expect(entities.getComponent(expected.handle, .y) == null);
            }
            if (expected.data.z) |z| {
                try std.testing.expectEqual(z, entities.getComponent(expected.handle, .z).?.*);
            } else {
                try std.testing.expect(entities.getComponent(expected.handle, .z) == null);
            }
        }

        // Test that iterators are working properly
        {
            var truth_xyz = std.AutoArrayHashMap(E.Handle, Data).init(std.testing.allocator);
            defer truth_xyz.deinit();
            var truth_xz = std.AutoArrayHashMap(E.Handle, Data).init(std.testing.allocator);
            defer truth_xz.deinit();
            var truth_y = std.AutoArrayHashMap(E.Handle, Data).init(std.testing.allocator);
            defer truth_y.deinit();
            var truth_all = std.AutoArrayHashMap(E.Handle, Data).init(std.testing.allocator);
            defer truth_all.deinit();

            for (truth.items) |entity| {
                if (entity.data.x != null and entity.data.y != null and entity.data.z != null)
                    try truth_xyz.put(entity.handle, entity.data);
                if (entity.data.x != null and entity.data.z != null)
                    try truth_xz.put(entity.handle, entity.data);
                if (entity.data.y != null)
                    try truth_y.put(entity.handle, entity.data);
                try truth_all.put(entity.handle, entity.data);
            }

            var iter_xyz = entities.iterator(.{ .x, .y, .z });
            while (iter_xyz.next()) |entity| {
                var expected = truth_xyz.get(entity.handle).?;
                _ = truth_xyz.swapRemove(entity.handle);
                try std.testing.expectEqual(expected.x.?, entity.comps.x.*);
                try std.testing.expectEqual(expected.y.?, entity.comps.y.*);
                try std.testing.expectEqual(expected.z.?, entity.comps.z.*);
            }
            try std.testing.expect(truth_xyz.count() == 0);

            var iter_xz = entities.iterator(.{ .x, .z });
            while (iter_xz.next()) |entity| {
                var expected = truth_xz.get(entity.handle).?;
                _ = truth_xz.swapRemove(entity.handle);
                try std.testing.expectEqual(expected.x.?, entity.comps.x.*);
                try std.testing.expectEqual(expected.z.?, entity.comps.z.*);
            }
            try std.testing.expect(truth_xz.count() == 0);

            var iter_y = entities.iterator(.{.y});
            while (iter_y.next()) |entity| {
                var expected = truth_y.get(entity.handle).?;
                _ = truth_y.swapRemove(entity.handle);
                try std.testing.expectEqual(expected.y.?, entity.comps.y.*);
            }
            try std.testing.expect(truth_y.count() == 0);

            var iter_all = entities.iterator(.{});
            while (iter_all.next()) |entity| {
                try std.testing.expect(truth_all.swapRemove(entity.handle));
            }
            try std.testing.expect(truth_all.count() == 0);
        }
    }
}

test "minimal iter test" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    const entity_0 = entities.create(.{ .x = 10, .y = 20 });
    const entity_1 = entities.create(.{ .x = 30, .y = 40 });
    const entity_2 = entities.create(.{ .x = 50 });
    const entity_3 = entities.create(.{ .y = 60 });

    {
        var iter = entities.iterator(.{ .x, .y });
        var next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_0);
        try std.testing.expectEqual(next.comps.x.*, 10);
        try std.testing.expectEqual(next.comps.y.*, 20);
        next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_1);
        try std.testing.expectEqual(next.comps.x.*, 30);
        try std.testing.expectEqual(next.comps.y.*, 40);

        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{.x});
        var next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_0);
        try std.testing.expectEqual(next.comps.x.*, 10);
        next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_1);
        try std.testing.expectEqual(next.comps.x.*, 30);
        next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_2);
        try std.testing.expectEqual(next.comps.x.*, 50);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{.y});
        var next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_0);
        try std.testing.expectEqual(next.comps.y.*, 20);
        next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_1);
        try std.testing.expectEqual(next.comps.y.*, 40);
        next = iter.next().?;
        try std.testing.expectEqual(next.handle, entity_3);
        try std.testing.expectEqual(next.comps.y.*, 60);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{});
        try std.testing.expectEqual(iter.next().?.handle, entity_0);
        try std.testing.expectEqual(iter.next().?.handle, entity_1);
        try std.testing.expectEqual(iter.next().?.handle, entity_2);
        try std.testing.expectEqual(iter.next().?.handle, entity_3);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }
}

test "prefabs" {
    var allocator = std.heap.page_allocator;

    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    var prefab: @TypeOf(entities).Prefab = .{ .y = 10, .z = 20 };
    var instance = entities.create(prefab);

    try std.testing.expect(entities.getComponent(instance, .x) == null);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);

    entities.addComponents(instance, @TypeOf(entities).Prefab{ .x = 30 });
    try std.testing.expect(entities.getComponent(instance, .x).?.* == 30);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);
}
