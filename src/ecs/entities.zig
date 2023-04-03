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
        const Self = @This();
        const ComponentKind = std.meta.FieldEnum(@TypeOf(registered_components));
        const component_types = field_values(registered_components);
        const component_names = std.meta.fieldNames(@TypeOf(registered_components));

        pub const Handle = HandleSlotMap.Handle;
        const HandleSlotMap = SlotMap(EntityPointer(Self), max_entities, EntityGeneration);

        allocator: Allocator,
        slot_map: HandleSlotMap,
        archetype_lists: AutoArrayHashMapUnmanaged(ComponentFlags(Self), ArchetypeList(Self)),

        // Is designed to ensure compatibility with allocators that do not implement free.
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            var slot_map = try HandleSlotMap.init(allocator);
            errdefer slot_map.deinit(allocator);

            var archetype_lists = archetype_lists: {
                var archetype_lists = AutoArrayHashMapUnmanaged(ComponentFlags(Self), ArchetypeList(Self)){};
                // We leave room for one extra because we don't know whether or not getOrPut
                // will allocate until afte it's done.
                try archetype_lists.ensureTotalCapacity(allocator, max_archetypes + 1);
                break :archetype_lists archetype_lists;
            };
            errdefer archetype_lists.deinit(allocator);

            return .{
                .allocator = allocator,
                .slot_map = slot_map,
                .archetype_lists = archetype_lists,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slot_map.deinit(self.allocator);
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.deinit(self.allocator);
            }
            self.archetype_lists.deinit(self.allocator);
        }

        pub fn create(self: *Self, entity: anytype) Handle {
            return self.createChecked(entity) catch |err|
                std.debug.panic("failed to create entity: {}", .{err});
        }

        pub fn createChecked(self: *Self, components: anytype) Allocator.Error!Handle {
            const archetype = ComponentFlags(Self).init(components);
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            const handle = try self.slot_map.create(undefined);
            errdefer _ = self.slot_map.remove(handle) catch unreachable;
            const pointer = self.slot_map.getUnchecked(handle);
            const index = try archetype_list.append(self.allocator, handle);
            errdefer archetype_list.pop();
            pointer.* = .{
                .archetype_list = archetype_list,
                .index = index,
            };
            setComponents(pointer, components);
            return handle;
        }

        pub fn swapRemove(self: *Self, entity: Handle) void {
            return self.swapRemoveChecked(entity) catch |err|
                std.debug.panic("failed to remove entity {}: {}", .{ entity, err });
        }

        pub fn swapRemoveChecked(self: *Self, entity: Handle) error{DoubleFree}!void {
            const entity_pointer = try self.slot_map.remove(entity);
            entity_pointer.archetype_list.swapRemove(entity_pointer.index, &self.slot_map);
        }

        pub fn exists(self: *Self, handle: Handle) bool {
            return self.slot_map.exists(handle);
        }

        pub fn addComponents(self: *Self, entity: Handle, add: anytype) void {
            self.addComponentsChecked(entity, add) catch |err|
                std.debug.panic("failed to add components: {}", .{err});
        }

        pub fn addComponentsChecked(self: *Self, handle: Handle, add: anytype) error{ UseAfterFree, OutOfMemory }!void {
            try self.changeArchetypeChecked(handle, .{ .add = add, .remove = ComponentFlags(Self).initBits(ComponentFlags(Self).Bits.initEmpty()) });
        }

        pub fn removeComponents(self: *Self, entity: Handle, remove: anytype) void {
            self.removeComponentsChecked(entity, remove) catch |err|
                std.debug.panic("failed to remove components: {}", .{err});
        }

        pub fn removeComponentsChecked(self: *Self, handle: Handle, remove: anytype) error{ UseAfterFree, OutOfMemory }!void {
            try self.changeArchetypeChecked(
                handle,
                .{
                    .add = .{},
                    .remove = ComponentFlags(Self).init(remove),
                },
            );
        }

        // TODO: use this in tests?
        pub fn changeArchetype(self: *Self, handle: Handle, changes: anytype) void {
            self.changeArchetypeChecked(handle, changes) catch |err|
                std.debug.panic("failed to change archetype: {}", .{err});
        }

        // TODO: early out if no change?
        // Changes the components archetype. The logical equivalent of removing `changes.remove`,
        // and then adding `changes.add`.
        pub fn changeArchetypeChecked(self: *Self, handle: Handle, changes: anytype) error{ UseAfterFree, OutOfMemory }!void {
            // Determine our archetype bitsets
            const pointer = try self.slot_map.get(handle);
            const previous_archetype = pointer.archetype_list.archetype;
            const components_added = ComponentFlags(Self).init(changes.add);
            const archetype = ComponentFlags(Self).initBits(previous_archetype.bits.unionWith(components_added.bits)
                .differenceWith(changes.remove.bits));
            const components_copied = ComponentFlags(Self).initBits(previous_archetype.bits.intersectWith(archetype.bits)
                .differenceWith(components_added.bits));

            // Create the new entity location
            const old_pointer: EntityPointer(Self) = pointer.*;
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            const index = try archetype_list.append(self.allocator, handle);
            errdefer archetype_list.pop();
            pointer.* = .{
                .archetype_list = archetype_list,
                .index = index,
            };

            // Set the component data at the new location
            copyComponents(pointer, old_pointer, components_copied);
            setComponents(pointer, changes.add);

            // Delete the old data
            old_pointer.archetype_list.swapRemove(old_pointer.index, &self.slot_map);
        }

        pub fn getComponent(self: *Self, entity: Handle, comptime component: ComponentKind) ?*component_types[@enumToInt(component)] {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn getComponentChecked(self: *Self, entity: Handle, comptime component: ComponentKind) error{UseAfterFree}!?*component_types[@enumToInt(component)] {
            const entity_pointer = try self.slot_map.get(entity);
            return entity_pointer.archetype_list.getComponent(entity_pointer.index, component);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            // This empties the archetype lists, but keeps them in place. A more clever
            // implementation could also allow repurposing them for a different set of archetypes.
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.clearRetainingCapacity();
            }
            self.slot_map.clearRetainingCapacity();
        }

        pub fn iterator(self: *Self, components: anytype) Iterator(Self, components) {
            return Iterator(Self, components).init(self);
        }

        fn find_component_name(comptime name: []const u8) ComponentKind {
            const maybe_index = std.meta.fieldIndex(@TypeOf(registered_components), name);
            if (maybe_index) |index| {
                return @intToEnum(ComponentKind, index);
            } else {
                @compileError("no registered component named '" ++ name ++ "'");
            }
        }

        fn getOrPutArchetypeList(self: *Self, archetype: ComponentFlags(Self)) Allocator.Error!*ArchetypeList(Self) {
            comptime assert(max_archetypes > 0);

            const entry = self.archetype_lists.getOrPutAssumeCapacity(archetype);

            if (!entry.found_existing) {
                // TODO: clean up?
                // We actually have max + 1 avaialble to make it possible to check even after creation
                // may have occurred via get or put.
                if (self.archetype_lists.count() >= max_archetypes) {
                    return error.OutOfMemory;
                }
                entry.value_ptr.* = ArchetypeList(Self).init(archetype);
            }

            return entry.value_ptr;
        }

        fn copyComponents(to: *const EntityPointer(Self), from: EntityPointer(Self), which: ComponentFlags(Self)) void {
            inline for (0..component_names.len) |i| {
                if (which.bits.isSet(i)) {
                    const component_name = @intToEnum(ComponentKind, i);
                    to.archetype_list.getComponentUnchecked(to.index, component_name).* = from.archetype_list.getComponentUnchecked(from.index, component_name).*;
                }
            }
        }

        fn setComponents(pointer: *const EntityPointer(Self), components: anytype) void {
            inline for (@typeInfo(@TypeOf(components)).Struct.fields) |f| {
                const component_name = comptime find_component_name(f.name);
                if (@TypeOf(components) == Prefab(Self)) {
                    if (@field(components, f.name)) |component| {
                        pointer.archetype_list.getComponentUnchecked(pointer.index, component_name).* = component;
                    }
                } else {
                    pointer.archetype_list.getComponentUnchecked(pointer.index, component_name).* = @field(components, f.name);
                }
            }
        }
    };
}

fn ArchetypeList(comptime T: type) type {
    const ComponentLists = ComponentMap(T, struct {
        fn FieldType(comptime C: type) type {
            return SegmentedListFirstShelfCount(C, first_shelf_count, false);
        }

        fn default_value(comptime C: type) ?*const anyopaque {
            return &FieldType(C){};
        }

        fn skip(comptime _: T.ComponentKind) bool {
            return false;
        }
    });

    return struct {
        const Self = @This();

        pub const HandleIterator = SegmentedListFirstShelfCount(T.Handle, first_shelf_count, false).Iterator;

        archetype: ComponentFlags(T),
        handles: SegmentedListFirstShelfCount(T.Handle, first_shelf_count, false) = .{},
        comps: ComponentLists = .{},

        pub fn init(archetype: ComponentFlags(T)) Self {
            return .{ .archetype = archetype };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            inline for (T.component_names) |comp_name| {
                @field(self.comps, comp_name).deinit(allocator);
            }
            self.handles.deinit(allocator);
        }

        // TODO: could return a set of optional pointers to avoid recalculating them, could
        // have the append math between the lists be shared
        pub fn append(self: *Self, allocator: Allocator, handle: T.Handle) Allocator.Error!u32 {
            inline for (T.component_names, 0..) |comp_name, i| {
                if (self.archetype.bits.isSet(i)) {
                    _ = try @field(self.comps, comp_name).addOne(allocator);
                }
            }
            const index = self.handles.len;
            try self.handles.append(allocator, handle);
            comptime assert(std.math.maxInt(u32) > max_entities);
            return @intCast(u32, index);
        }

        pub fn swapRemove(self: *Self, index: u32, slot_map: *T.HandleSlotMap) void {
            assert(index < self.handles.len);
            inline for (T.component_names, 0..) |comp_name, i| {
                if (self.archetype.bits.isSet(i)) {
                    var components = &@field(self.comps, comp_name);
                    components.uncheckedAt(index).* = components.pop().?;
                }
            }
            const moved_handle = self.handles.pop().?;
            self.handles.uncheckedAt(index).* = moved_handle;
            // TODO: why do i have to skip this if last?
            if (index != self.handles.len) {
                slot_map.getUnchecked(moved_handle).index = index;
            }
        }

        pub fn handleIterator(self: *Self) HandleIterator {
            return self.handles.iterator(0);
        }

        pub fn getComponent(self: *Self, index: u32, comptime component_name: T.ComponentKind) ?*T.component_types[@enumToInt(component_name)] {
            if (!self.archetype.bits.isSet(@enumToInt(component_name))) {
                return null;
            }
            return self.getComponentUnchecked(index, component_name);
        }

        pub fn getComponentUnchecked(self: *Self, index: u32, comptime component_name: T.ComponentKind) *T.component_types[@enumToInt(component_name)] {
            return @field(self.comps, T.component_names[@enumToInt(component_name)]).uncheckedAt(index);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.handles.clearRetainingCapacity();
            inline for (T.component_names) |comp_name| {
                @field(self.comps, comp_name).clearRetainingCapacity();
            }
        }
    };
}

pub fn Iterator(comptime T: type, comptime components: anytype) type {
    return struct {
        const Item = ComponentMap(T, struct {
            fn FieldType(comptime C: type) type {
                return *C;
            }

            fn default_value(comptime _: type) ?*const anyopaque {
                return &null;
            }

            fn skip(comptime kind: T.ComponentKind) bool {
                return !ComponentFlags(T).init(components).bits.isSet(@enumToInt(kind));
            }
        });

        archetype: ComponentFlags(T),
        entities: *T,
        // It's measurably faster to use the iterator rather than index (less indirection), removing
        // indirection by storing pointer to array is equiavlent in release mode and faster in debug
        // mode.
        archetype_lists: AutoArrayHashMapUnmanaged(ComponentFlags(T), ArchetypeList(T)).Iterator,
        archetype_list: ?*ArchetypeList(T),
        handle_iterator: ArchetypeList(T).HandleIterator,
        current_handle: T.Handle,

        pub fn next(self: *@This()) ?Item {
            while (true) {
                // If we don't have a page list, find the next compatible archetype's page
                // list
                if (self.archetype_list == null) {
                    self.archetype_list = while (self.archetype_lists.next()) |archetype_list| {
                        if (archetype_list.value_ptr.archetype.bits.supersetOf(self.archetype.bits)) {
                            break archetype_list.value_ptr;
                        }
                    } else return null;
                    self.handle_iterator = self.archetype_list.?.handleIterator();
                }

                // Get the next entity in this page list, if it exists
                if (self.handle_iterator.peek()) |current_handle| {
                    var item: Item = undefined;
                    self.current_handle = current_handle.*;
                    comptime assert(@TypeOf(self.archetype_list.?.handles).prealloc_count == 0);
                    inline for (@typeInfo(Item).Struct.fields) |field| {
                        comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).prealloc_count == 0);
                        comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).first_shelf_exp == @TypeOf(self.archetype_list.?.handles).first_shelf_exp);
                        @field(item, field.name) = &@field(self.archetype_list.?.comps, field.name).dynamic_segments[self.handle_iterator.shelf_index][self.handle_iterator.box_index];
                    }
                    _ = self.handle_iterator.next();
                    return item;
                }

                self.archetype_list = null;
            }
        }

        // TODO: test coverage
        pub fn handle(self: *const @This()) T.Handle {
            assert(self.archetype_list != null);
            return self.current_handle;
        }

        pub fn swapRemove(self: *@This()) void {
            self.swapRemoveChecked() catch unreachable;
        }

        fn swapRemoveChecked(self: *@This()) error{NothingToRemove}!void {
            if (self.archetype_list == null) return error.NothingToRemove;
            _ = self.handle_iterator.prev();
            self.entities.swapRemoveChecked(self.handle_iterator.peek().?.*) catch unreachable;
        }

        fn init(entities: *T) @This() {
            return .{
                .entities = entities,
                .archetype = ComponentFlags(T).init(components),
                .archetype_lists = entities.archetype_lists.iterator(),
                .archetype_list = null,
                .handle_iterator = undefined,
                .current_handle = undefined,
            };
        }
    };
}

pub fn ComponentFlags(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Bits = std.bit_set.IntegerBitSet(T.component_names.len);

        bits: Bits,

        // Creates an archetype from a prefab, a struct of components, or a tuple of enum
        // component names.
        pub fn init(components: anytype) Self {
            if (@TypeOf(components) == Prefab(T)) {
                var archetype = initBits(Bits.initEmpty());
                inline for (comptime @typeInfo(@TypeOf(components)).Struct.fields) |field| {
                    if (@field(components, field.name) != null) {
                        archetype.bits.set(@enumToInt(T.find_component_name(field.name)));
                    }
                }
                return archetype;
            } else if (@typeInfo(@TypeOf(components)).Struct.is_tuple) {
                var archetype = initBits(Bits.initEmpty());
                inline for (components) |c| {
                    const component: T.ComponentKind = c;
                    archetype.bits.set(@enumToInt(component));
                }
                return archetype;
            } else comptime {
                var archetype = initBits(Bits.initEmpty());
                for (@typeInfo(@TypeOf(components)).Struct.fields) |field| {
                    archetype.bits.set(@enumToInt(T.find_component_name(field.name)));
                }
                return archetype;
            }
        }

        pub fn initBits(bits: Bits) Self {
            return .{ .bits = bits };
        }
    };
}

pub fn Prefab(comptime T: type) type {
    return ComponentMap(T, struct {
        fn FieldType(comptime C: type) type {
            return ?C;
        }

        fn default_value(comptime _: type) ?*const anyopaque {
            return &null;
        }

        fn skip(comptime _: T.ComponentKind) bool {
            return false;
        }
    });
}

pub fn ArchetypeChange(comptime T: type) type {
    return struct {
        add: Prefab(T),
        remove: ComponentFlags(T),
    };
}

pub fn EntityPointer(comptime T: type) type {
    return struct {
        archetype_list: *ArchetypeList(T),
        index: u32, // TODO: how did we decide on u32 here?
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

fn ComponentMap(comptime T: type, comptime Map: type) type {
    var fields: [T.component_types.len]Type.StructField = undefined;
    var len: usize = 0;
    for (T.component_types, T.component_names, 0..) |comp_type, comp_name, i| {
        if (!Map.skip(@intToEnum(T.ComponentKind, i))) {
            const FieldType = Map.FieldType(comp_type);
            fields[len] = Type.StructField{
                .name = comp_name,
                .type = FieldType,
                .default_value = Map.default_value(comp_type),
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
            };
            len += 1;
        }
    }
    return @Type(Type{
        .Struct = Type.Struct{
            .layout = .Auto,
            .backing_integer = null,
            .fields = fields[0..len],
            .decls = &[_]Type.Declaration{},
            .is_tuple = false,
        },
    });
}

test "iter remove" {
    var allocator = std.testing.allocator;

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
            try std.testing.expect(iter.next().?.x.* == 0);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 30);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponentChecked(e0, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.x.* == 30);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
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
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 30);
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponentChecked(e1, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 30);
            try std.testing.expect(iter.next().?.x.* == 20);
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
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next().?.x.* == 30);
            iter.swapRemove();
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 20);
        try std.testing.expect(entities.getComponentChecked(e3, .x) == error.UseAfterFree);

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
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
            try std.testing.expect(iter.next().?.x.* == 0);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 30);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 20);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 10);
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
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next().?.x.* == 30);
        }

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next().?.x.* == 30);
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
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 30);
        }

        {
            var iter = entities.iterator(.{.x});
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 30);
            try std.testing.expect(iter.next() == null);
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 0);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 10);
        try std.testing.expect(entities.getComponentChecked(e2, .x) == error.UseAfterFree);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 30);
    }
}

test "clear retaining capacity" {
    var allocator = std.testing.allocator;

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

        // TODO: test iters, test getcomponent on these

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
        while (it.next()) |_| {
            try std.testing.expect(expected.remove(it.handle()));
        }
        try std.testing.expect(expected.count() == 0);
    }
}

// Could use a more exhaustive test, this at least makes sure it compiles which was a problem
// at one point!
test "zero-sized-component" {
    var allocator = std.testing.allocator;
    var entities = try Entities(.{ .x = struct {} }).init(allocator);
    defer entities.deinit();

    const a = entities.create(.{ .x = .{} });
    const b = entities.create(.{});

    try std.testing.expect(entities.getComponent(a, .x) != null);
    try std.testing.expect(entities.getComponent(b, .x) == null);
}

// TODO: update this test or no since we have it externally?
// test "free list" {
//     var allocator = std.testing.allocator;
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
        const IndexInPage = std.meta.fields(EntityPointer(Entities(.{})))[std.meta.fieldIndex(EntityPointer(Entities(.{})), "index").?].type;
        assert(std.math.maxInt(IndexInPage) > page_size);
    }

    var allocator = std.testing.allocator;
    var entities = try Entities(.{}).init(allocator);
    const Handle = @TypeOf(entities).Handle;
    defer entities.deinit();
    var created = std.ArrayList(Handle).init(allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(Handle{ .index = @intCast(Entities(.{}).HandleSlotMap.Index, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expectError(error.OutOfMemory, entities.createChecked(.{}));

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.swapRemove(entity);
    }

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

    // TODO: update this test or no since we have it externally?
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
    var allocator = std.testing.allocator;
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

// TODO: test 0 sized components? (used in game seemingly correctly!)
test "random data" {
    const E = Entities(.{ .x = u32, .y = u8, .z = u16 });
    var allocator = std.testing.allocator;
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
    var truth = std.ArrayList(Created).init(allocator);
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
            var truth_xyz = std.AutoArrayHashMap(E.Handle, Data).init(allocator);
            defer truth_xyz.deinit();
            var truth_xz = std.AutoArrayHashMap(E.Handle, Data).init(allocator);
            defer truth_xz.deinit();
            var truth_y = std.AutoArrayHashMap(E.Handle, Data).init(allocator);
            defer truth_y.deinit();
            var truth_all = std.AutoArrayHashMap(E.Handle, Data).init(allocator);
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
                var expected = truth_xyz.get(iter_xyz.handle()).?;
                _ = truth_xyz.swapRemove(iter_xyz.handle());
                try std.testing.expectEqual(expected.x.?, entity.x.*);
                try std.testing.expectEqual(expected.y.?, entity.y.*);
                try std.testing.expectEqual(expected.z.?, entity.z.*);
            }
            try std.testing.expect(truth_xyz.count() == 0);

            var iter_xz = entities.iterator(.{ .x, .z });
            while (iter_xz.next()) |entity| {
                var expected = truth_xz.get(iter_xz.handle()).?;
                _ = truth_xz.swapRemove(iter_xz.handle());
                try std.testing.expectEqual(expected.x.?, entity.x.*);
                try std.testing.expectEqual(expected.z.?, entity.z.*);
            }
            try std.testing.expect(truth_xz.count() == 0);

            var iter_y = entities.iterator(.{.y});
            while (iter_y.next()) |entity| {
                var expected = truth_y.get(iter_y.handle()).?;
                _ = truth_y.swapRemove(iter_y.handle());
                try std.testing.expectEqual(expected.y.?, entity.y.*);
            }
            try std.testing.expect(truth_y.count() == 0);

            var iter_all = entities.iterator(.{});
            while (iter_all.next()) |_| {
                try std.testing.expect(truth_all.swapRemove(iter_all.handle()));
            }
            try std.testing.expect(truth_all.count() == 0);
        }
    }
}

test "minimal iter test" {
    var allocator = std.testing.allocator;
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    const entity_0 = entities.create(.{ .x = 10, .y = 20 });
    const entity_1 = entities.create(.{ .x = 30, .y = 40 });
    const entity_2 = entities.create(.{ .x = 50 });
    const entity_3 = entities.create(.{ .y = 60 });

    {
        var iter = entities.iterator(.{ .x, .y });
        var next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_0);
        try std.testing.expectEqual(next.x.*, 10);
        try std.testing.expectEqual(next.y.*, 20);
        next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_1);
        try std.testing.expectEqual(next.x.*, 30);
        try std.testing.expectEqual(next.y.*, 40);

        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{.x});
        var next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_0);
        try std.testing.expectEqual(next.x.*, 10);
        next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_1);
        try std.testing.expectEqual(next.x.*, 30);
        next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_2);
        try std.testing.expectEqual(next.x.*, 50);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{.y});
        var next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_0);
        try std.testing.expectEqual(next.y.*, 20);
        next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_1);
        try std.testing.expectEqual(next.y.*, 40);
        next = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_3);
        try std.testing.expectEqual(next.y.*, 60);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }

    {
        var iter = entities.iterator(.{});
        _ = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_0);
        _ = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_1);
        _ = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_2);
        _ = iter.next().?;
        try std.testing.expectEqual(iter.handle(), entity_3);
        try std.testing.expect(iter.next() == null);
        try std.testing.expect(iter.next() == null);
    }
}

test "prefabs" {
    var allocator = std.testing.allocator;

    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    var prefab: Prefab(@TypeOf(entities)) = .{ .y = 10, .z = 20 };
    var instance = entities.create(prefab);

    try std.testing.expect(entities.getComponent(instance, .x) == null);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);

    entities.addComponents(instance, Prefab(@TypeOf(entities)){ .x = 30 });
    try std.testing.expect(entities.getComponent(instance, .x).?.* == 30);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);
}
