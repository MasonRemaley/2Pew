const std = @import("std");
const builtin = @import("builtin");
const slot_map = @import("../slot_map.zig");
const SegmentedListFirstShelfCount = @import("../segmented_list.zig").SegmentedListFirstShelfCount;

const assert = std.debug.assert;

const SlotMap = @import("../slot_map.zig").SlotMap;
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const Type = std.builtin.Type;

pub const max_entities: u32 = 1000000;
const page_size = 4096;

const max_pages = max_entities / 32;
const max_archetypes = 40000;
const first_shelf_count = 8;

pub const Handle = slot_map.Handle(max_entities, u32);

pub fn Entities(comptime registered_components: anytype) type {
    return struct {
        const Self = @This();

        // Component info
        pub const ComponentTag = std.meta.FieldEnum(@TypeOf(registered_components));
        pub const component_types = ct: {
            const fields = @typeInfo(@TypeOf(registered_components)).Struct.fields;
            var values: [fields.len]type = undefined;
            for (fields, 0..) |field, i| {
                values[i] = @field(registered_components, field.name);
            }
            break :ct &values;
        };
        pub const component_names = std.meta.fieldNames(@TypeOf(registered_components));

        allocator: Allocator,
        handles: SlotMap(EntityPointer, Handle),
        archetype_lists: AutoArrayHashMapUnmanaged(ComponentFlags, ArchetypeList),

        // Is designed to ensure compatibility with allocators that do not implement free.
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            var handles = try SlotMap(EntityPointer, Handle).init(allocator);
            errdefer handles.deinit(allocator);

            var archetype_lists = archetype_lists: {
                var archetype_lists = AutoArrayHashMapUnmanaged(ComponentFlags, ArchetypeList){};
                // We leave room for one extra because we don't know whether or not getOrPut
                // will allocate until afte it's done.
                try archetype_lists.ensureTotalCapacity(allocator, max_archetypes + 1);
                break :archetype_lists archetype_lists;
            };
            errdefer archetype_lists.deinit(allocator);

            return .{
                .allocator = allocator,
                .handles = handles,
                .archetype_lists = archetype_lists,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handles.deinit(self.allocator);
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.deinit(self.allocator);
            }
            self.archetype_lists.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn create(self: *Self, entity: anytype) Handle {
            return self.createChecked(entity) catch |err|
                std.debug.panic("failed to create entity: {}", .{err});
        }

        pub fn createChecked(self: *Self, components: anytype) Allocator.Error!Handle {
            const archetype = ComponentFlags.initFromComponents(components);
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            const handle = try self.handles.create(undefined);
            errdefer _ = self.handles.remove(handle) catch unreachable;
            const pointer = self.handles.getUnchecked(handle);
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
            const entity_pointer = try self.handles.remove(entity);
            entity_pointer.archetype_list.swapRemove(entity_pointer.index, &self.handles);
        }

        pub fn exists(self: *const Self, handle: Handle) bool {
            return self.handles.exists(handle);
        }

        pub fn addComponents(self: *Self, entity: Handle, add: anytype) void {
            self.addComponentsChecked(entity, add) catch |err|
                std.debug.panic("failed to add components: {}", .{err});
        }

        pub fn addComponentsChecked(self: *Self, handle: Handle, add: anytype) error{ UseAfterFree, OutOfMemory }!void {
            try self.changeArchetypeChecked(handle, .{ .add = add, .remove = .{} });
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
                    .remove = ComponentFlags.initFromKinds(remove),
                },
            );
        }

        pub fn changeArchetype(self: *Self, handle: Handle, changes: ArchetypeChange) void {
            self.changeArchetypeChecked(handle, changes) catch |err|
                std.debug.panic("failed to change archetype: {}", .{err});
        }

        // TODO: early out if no change?
        // Changes the components archetype. The logical equivalent of removing `changes.remove`,
        // and then adding `changes.add`.
        pub fn changeArchetypeChecked(self: *Self, handle: Handle, changes: ArchetypeChange) error{ UseAfterFree, OutOfMemory }!void {
            // Determine our archetype bitsets
            const pointer = try self.handles.get(handle);
            const previous_archetype = pointer.archetype_list.archetype;
            const components_added = ComponentFlags.initFromComponents(changes.add);
            const new_archetype = previous_archetype.differenceWith(changes.remove)
                .unionWith(components_added);

            // If the archetype actually changed, move the data
            if (new_archetype.int() != previous_archetype.int()) {
                // Allocate space of the new archetype
                const old_pointer: EntityPointer = pointer.*;
                const archetype_list = try self.getOrPutArchetypeList(new_archetype);
                const index = try archetype_list.append(self.allocator, handle);
                errdefer archetype_list.pop();
                pointer.* = .{
                    .archetype_list = archetype_list,
                    .index = index,
                };

                // Copy the old components that aren't being removed or overwritten over to the new location
                const to_copy = (previous_archetype.intersectWith(new_archetype)).differenceWith(components_added);
                copyComponents(pointer, old_pointer, to_copy);

                // Delete the data fom the old location
                old_pointer.archetype_list.swapRemove(old_pointer.index, &self.handles);
            }

            // Set the component data at the new location
            setComponents(pointer, changes.add);
        }

        pub fn getComponent(self: *const Self, entity: Handle, comptime component: ComponentTag) ?*component_types[@enumToInt(component)] {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn getComponentChecked(self: *const Self, entity: Handle, comptime component: ComponentTag) error{UseAfterFree}!?*component_types[@enumToInt(component)] {
            const entity_pointer = try self.handles.get(entity);
            return entity_pointer.archetype_list.getComponent(entity_pointer.index, component);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            // This empties the archetype lists, but keeps them in place. A more clever
            // implementation could also allow repurposing them for a different set of archetypes.
            for (self.archetype_lists.values()) |*archetype_list| {
                archetype_list.clearRetainingCapacity();
            }
            self.handles.clearRetainingCapacity();
        }

        pub fn iterator(self: *Self, comptime components: IteratorDescriptor) Iterator(components) {
            return Iterator(components).init(self);
        }

        pub fn constIterator(self: *const Self, comptime components: IteratorDescriptor) ConstIterator(components) {
            return ConstIterator(components).init(self);
        }

        pub fn len(self: *const Self) Handle.Index {
            return self.handles.len();
        }

        fn componentTag(comptime name: []const u8) ComponentTag {
            const maybe_index = std.meta.fieldIndex(@TypeOf(registered_components), name);
            if (maybe_index) |index| {
                return @intToEnum(ComponentTag, index);
            } else {
                @compileError("no registered component named '" ++ name ++ "'");
            }
        }

        fn getOrPutArchetypeList(self: *Self, archetype: ComponentFlags) Allocator.Error!*ArchetypeList {
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

        fn copyComponents(to: *const EntityPointer, from: EntityPointer, which: ComponentFlags) void {
            inline for (0..component_names.len) |i| {
                const component = @intToEnum(ComponentTag, i);
                if (which.isSet(component)) {
                    to.archetype_list.getComponentUnchecked(to.index, component).* = from.archetype_list.getComponentUnchecked(from.index, component).*;
                }
            }
        }

        fn setComponents(pointer: *const EntityPointer, components: anytype) void {
            inline for (@typeInfo(@TypeOf(components)).Struct.fields) |f| {
                if (@TypeOf(components) == Self.PrefabEntity) {
                    if (@field(components, f.name)) |component| {
                        pointer.archetype_list.getComponentUnchecked(pointer.index, componentTag(f.name)).* = component;
                    }
                } else {
                    pointer.archetype_list.getComponentUnchecked(pointer.index, componentTag(f.name)).* = @field(components, f.name);
                }
            }
        }

        pub const PrefabEntity = ComponentMap(.Auto, struct {
            fn FieldType(comptime _: ComponentTag, comptime C: type) type {
                return ?C;
            }

            fn default_value(comptime _: ComponentTag, comptime _: type) ?*const anyopaque {
                return &null;
            }
        });
        pub const ArchetypeChange = struct {
            add: PrefabEntity = .{},
            remove: ComponentFlags = ComponentFlags.initFromKinds(.{}),
        };
        pub const ComponentFlags = packed struct {
            pub const Int = std.meta.Int(.unsigned, @bitSizeOf(ComponentFlags));
            pub const ShiftInt = std.math.Log2Int(Int);
            const Mask = ComponentMap(.Packed, struct {
                fn FieldType(comptime _: ComponentTag, comptime _: type) type {
                    return bool;
                }

                fn default_value(comptime _: ComponentTag, comptime _: type) ?*const anyopaque {
                    return &false;
                }
            });

            mask: Mask = .{},

            pub fn initFromKinds(tuple: anytype) ComponentFlags {
                var self = ComponentFlags{};
                inline for (tuple) |kind| {
                    self.set(kind);
                }
                return self;
            }

            pub fn initFromComponents(components: anytype) ComponentFlags {
                if (@TypeOf(components) == PrefabEntity) {
                    var self = ComponentFlags{};
                    inline for (comptime @typeInfo(@TypeOf(components)).Struct.fields) |field| {
                        if (@field(components, field.name) != null) {
                            self.setName(field.name);
                        }
                    }
                    return self;
                } else return comptime blk: {
                    var self = ComponentFlags{};
                    for (@typeInfo(@TypeOf(components)).Struct.fields) |field| {
                        self.setName(field.name);
                    }
                    break :blk self;
                };
            }

            pub fn initFromIteratorDescriptorRequired(descriptor: IteratorDescriptor) ComponentFlags {
                comptime var self = ComponentFlags{};
                inline for (component_names) |comp_name| {
                    if (@field(descriptor, comp_name)) |comp| {
                        if (!comp.optional) {
                            self.setName(comp_name);
                        }
                    }
                }
                return self;
            }

            pub fn int(self: ComponentFlags) Int {
                return @bitCast(Int, self);
            }

            pub fn supersetOf(self: ComponentFlags, of: ComponentFlags) bool {
                return (self.int() & of.int()) == of.int();
            }

            pub fn subsetOf(self: ComponentFlags, of: ComponentFlags) bool {
                return (self.int() & of.int()) == self.int();
            }

            pub fn unionWith(self: ComponentFlags, with: ComponentFlags) ComponentFlags {
                return .{ .mask = @bitCast(Mask, self.int() | with.int()) };
            }

            pub fn intersectWith(self: ComponentFlags, with: ComponentFlags) ComponentFlags {
                return .{ .mask = @bitCast(Mask, self.int() & with.int()) };
            }

            pub fn differenceWith(self: ComponentFlags, sub: ComponentFlags) ComponentFlags {
                return .{ .mask = @bitCast(Mask, self.int() & ~sub.int()) };
            }

            fn maskBit(component: ComponentTag) Int {
                return @as(Int, 1) << @intCast(ShiftInt, @enumToInt(component));
            }

            pub fn isSet(self: ComponentFlags, component: ComponentTag) bool {
                return (self.int() & maskBit(component)) != 0;
            }

            pub fn isNameSet(self: ComponentFlags, comptime name: []const u8) bool {
                return @field(self.mask, name);
            }

            pub fn set(self: *ComponentFlags, component: ComponentTag) void {
                self.mask = @bitCast(Mask, self.int() | maskBit(component));
            }

            pub fn setName(self: *ComponentFlags, comptime name: []const u8) void {
                @field(self.mask, name) = true;
            }

            pub fn unset(self: *ComponentFlags, component: ComponentTag) void {
                self.mask = self.bitCast(Mask, self.int() & ~maskBit(component));
            }

            pub fn unsetName(self: *ComponentFlags, comptime name: []const u8) void {
                @field(self.mask, name) = false;
            }
        };

        fn ComponentMap(
            comptime layout: std.builtin.Type.ContainerLayout,
            comptime Map: type,
        ) type {
            var fields: [component_types.len]Type.StructField = undefined;
            var i: usize = 0;
            for (component_types, component_names, 0..) |comp_type, comp_name, component_i| {
                const component = @intToEnum(ComponentTag, component_i);
                if (!@hasDecl(Map, "skip") or !Map.skip(component)) {
                    const FieldType = Map.FieldType(component, comp_type);
                    fields[i] = Type.StructField{
                        .name = comp_name,
                        .type = FieldType,
                        .default_value = Map.default_value(component, FieldType),
                        .is_comptime = false,
                        .alignment = if (layout == .Packed) 0 else @alignOf(FieldType),
                    };
                    i += 1;
                }
            }
            return @Type(Type{
                .Struct = Type.Struct{
                    .layout = layout,
                    .backing_integer = null,
                    .fields = fields[0..i],
                    .decls = &[_]Type.Declaration{},
                    .is_tuple = false,
                },
            });
        }
        const EntityPointer = struct {
            archetype_list: *ArchetypeList,
            index: u32, // TODO: how did we decide on u32 here?
        };

        pub const IteratorComponentDescriptor = packed struct {
            mutable: bool = false,
            optional: bool = false,
        };

        pub const IteratorDescriptor = ComponentMap(.Auto, struct {
            fn FieldType(comptime _: ComponentTag, comptime _: type) type {
                return ?IteratorComponentDescriptor;
            }

            fn default_value(comptime _: ComponentTag, comptime _: type) ?*const anyopaque {
                return &null;
            }
        });

        pub fn ConstIterator(comptime descriptor: IteratorDescriptor) type {
            return BaseIterator(false, descriptor);
        }

        pub fn Iterator(comptime descriptor: IteratorDescriptor) type {
            return BaseIterator(true, descriptor);
        }

        fn BaseIterator(comptime mutable: bool, comptime descriptor: IteratorDescriptor) type {
            return struct {
                const required_components = ComponentFlags.initFromIteratorDescriptorRequired(descriptor);
                const Item = ComponentMap(.Auto, struct {
                    fn FieldType(comptime component: ComponentTag, comptime C: type) type {
                        const name = component_names[@enumToInt(component)];

                        var Result = C;

                        if (@field(descriptor, name).?.mutable) {
                            Result = *Result;
                        } else {
                            Result = *const Result;
                        }

                        if (@field(descriptor, name).?.optional) {
                            Result = ?Result;
                        }

                        return Result;
                    }

                    fn default_value(comptime component: ComponentTag, comptime _: type) ?*const anyopaque {
                        if (!required_components.isSet(component)) {
                            return null;
                        } else {
                            return &null;
                        }
                    }

                    fn skip(comptime component: ComponentTag) bool {
                        return @field(descriptor, component_names[@enumToInt(component)]) == null;
                    }
                });

                entities: if (mutable) *Self else *const Self,
                // It's measurably faster to use the iterator rather than index (less indirection), removing
                // indirection by storing pointer to array is equiavlent in release mode and faster in debug
                // mode.
                archetype_lists: AutoArrayHashMapUnmanaged(ComponentFlags, ArchetypeList).Iterator,
                archetype_list: ?*ArchetypeList,
                handle_iterator: ArchetypeList.HandleIterator,
                current_handle: Handle,

                pub fn next(self: *@This()) ?Item {
                    while (true) {
                        // If we don't have a page list, find the next compatible archetype's page
                        // list
                        if (self.archetype_list == null) {
                            self.archetype_list = while (self.archetype_lists.next()) |archetype_list| {
                                if (archetype_list.value_ptr.archetype.supersetOf(required_components)) {
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
                                // Make sure the component list is compatible with the handle iterator
                                comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).prealloc_count == 0);
                                comptime assert(@TypeOf(@field(self.archetype_list.?.comps, field.name)).first_shelf_exp == @TypeOf(self.archetype_list.?.handles).first_shelf_exp);

                                comptime var component = componentTag(field.name);
                                comptime var ComponentType = component_types[@enumToInt(component)];

                                const required = @field(descriptor, field.name) != null and !@field(descriptor, field.name).?.optional;
                                const next_exists = required or self.archetype_list.?.archetype.isNameSet(field.name);

                                if (next_exists) {
                                    if (@sizeOf(ComponentType) == 0) {
                                        // TODO: https://github.com/ziglang/zig/issues/3325
                                        @field(item, field.name) = @intToPtr(*ComponentType, 0xaaaaaaaaaaaaaaaa);
                                    } else {
                                        @field(item, field.name) = &@field(self.archetype_list.?.comps, field.name).dynamic_segments[self.handle_iterator.shelf_index][self.handle_iterator.box_index];
                                    }
                                } else {
                                    @field(item, field.name) = null;
                                }
                            }
                            _ = self.handle_iterator.next();
                            return item;
                        }

                        self.archetype_list = null;
                    }
                }

                // TODO: test coverage
                pub fn handle(self: *const @This()) Handle {
                    assert(self.archetype_list != null);
                    return self.current_handle;
                }

                pub fn swapRemove(self: *@This()) void {
                    self.swapRemoveChecked() catch unreachable;
                }

                fn swapRemoveChecked(self: *@This()) error{NothingToRemove}!void {
                    if (!mutable) {
                        @compileError("remove not supported on constant iterator");
                    }
                    if (self.archetype_list == null) return error.NothingToRemove;
                    _ = self.handle_iterator.prev();
                    self.entities.swapRemoveChecked(self.handle_iterator.peek().?.*) catch unreachable;
                }

                fn init(entities: anytype) @This() {
                    return .{
                        .entities = entities,
                        .archetype_lists = entities.archetype_lists.iterator(),
                        .archetype_list = null,
                        .handle_iterator = undefined,
                        .current_handle = undefined,
                    };
                }
            };
        }

        const ArchetypeList = struct {
            const ComponentLists = ComponentMap(.Auto, struct {
                fn FieldType(comptime _: ComponentTag, comptime C: type) type {
                    return SegmentedListFirstShelfCount(C, first_shelf_count, false);
                }

                fn default_value(comptime _: ComponentTag, comptime C: type) ?*const anyopaque {
                    return &C{};
                }
            });

            pub const HandleIterator = SegmentedListFirstShelfCount(Handle, first_shelf_count, false).ConstIterator;

            archetype: ComponentFlags,
            handles: SegmentedListFirstShelfCount(Handle, first_shelf_count, false) = .{},
            comps: ComponentLists = .{},

            pub fn init(archetype: ComponentFlags) @This() {
                return .{ .archetype = archetype };
            }

            pub fn deinit(self: *@This(), allocator: Allocator) void {
                inline for (component_names) |comp_name| {
                    @field(self.comps, comp_name).deinit(allocator);
                }
                self.handles.deinit(allocator);
                self.* = undefined;
            }

            // TODO: could return a set of optional pointers to avoid recalculating them, could
            // have the append math between the lists be shared
            pub fn append(self: *@This(), allocator: Allocator, handle: Handle) Allocator.Error!u32 {
                inline for (component_names) |comp_name| {
                    if (self.archetype.isNameSet(comp_name)) {
                        _ = try @field(self.comps, comp_name).addOne(allocator);
                    }
                }
                const index = self.handles.len;
                try self.handles.append(allocator, handle);
                comptime assert(std.math.maxInt(u32) > max_entities);
                return @intCast(u32, index);
            }

            pub fn swapRemove(self: *@This(), index: u32, handles: *const SlotMap(EntityPointer, Handle)) void {
                assert(index < self.handles.len);
                inline for (component_names) |name| {
                    if (self.archetype.isNameSet(name)) {
                        var components = &@field(self.comps, name);
                        components.uncheckedAt(index).* = components.pop().?;
                    }
                }
                const moved_handle = self.handles.pop().?;
                self.handles.uncheckedAt(index).* = moved_handle;
                // TODO: why do i have to skip this if last?
                if (index != self.handles.len) {
                    handles.getUnchecked(moved_handle).index = index;
                }
            }

            pub fn handleIterator(self: *const @This()) HandleIterator {
                return self.handles.constIterator(0);
            }

            pub fn getComponent(self: *@This(), index: u32, comptime component: ComponentTag) ?*component_types[@enumToInt(component)] {
                if (!self.archetype.isSet(component)) {
                    return null;
                }
                return self.getComponentUnchecked(index, component);
            }

            pub fn getComponentUnchecked(self: *@This(), index: u32, comptime component: ComponentTag) *component_types[@enumToInt(component)] {
                return @field(self.comps, component_names[@enumToInt(component)]).uncheckedAt(index);
            }

            pub fn clearRetainingCapacity(self: *@This()) void {
                self.handles.clearRetainingCapacity();
                inline for (component_names) |comp_name| {
                    @field(self.comps, comp_name).clearRetainingCapacity();
                }
            }
        };
    };
}

test "basic" {
    var entities = try Entities(.{ .x = u32, .y = u8 }).init(std.testing.allocator);
    defer entities.deinit();

    const e0 = entities.create(.{ .x = 10, .y = 'a' });
    const e1 = entities.create(.{ .x = 11 });

    try std.testing.expect(entities.getComponent(e0, .x).?.* == 10);
    try std.testing.expect(entities.getComponent(e0, .y).?.* == 'a');
    try std.testing.expect(entities.getComponent(e1, .x).?.* == 11);
    try std.testing.expect(entities.getComponent(e1, .y) == null);

    var iter = entities.iterator(.{ .x = .{}, .y = .{} });
    var e = iter.next().?;
    try std.testing.expect(e.x.* == 10);
    try std.testing.expect(e.y.* == 'a');
    try std.testing.expect(iter.next() == null);
}

test "zero-sized-component" {
    var allocator = std.testing.allocator;
    var entities = try Entities(.{ .x = void }).init(allocator);
    defer entities.deinit();

    const a = entities.create(.{ .x = {} });
    const b = entities.create(.{});

    try std.testing.expect(entities.getComponent(a, .x) != null);
    try std.testing.expect(entities.getComponent(b, .x) == null);

    {
        var iter = entities.iterator(.{ .x = .{} });
        try std.testing.expect(iter.next() != null);
        try std.testing.expect(iter.next() == null);
    }

    {
        const Expected = struct { x: ?void = null };
        var expected = std.AutoHashMap(Handle, Expected).init(allocator);
        defer expected.deinit();
        try expected.put(a, .{ .x = {} });
        try expected.put(b, .{});
        var iter = entities.iterator(.{ .x = .{ .optional = true } });
        while (iter.next()) |entity| {
            try std.testing.expectEqual(expected.get(iter.handle()), .{
                .x = if (entity.x) |x| x.* else null,
            });
            _ = expected.remove(iter.handle());
        }
        try std.testing.expect(expected.count() == 0);
    }
}

test "iter desc" {
    var allocator = std.testing.allocator;

    var entities = try Entities(.{ .x = u32, .y = u8 }).init(allocator);
    defer entities.deinit();

    const e0 = entities.create(.{ .x = 10, .y = 'a' });
    const e1 = entities.create(.{ .x = 20, .y = 'b' });
    const e2 = entities.create(.{ .x = 30 });
    const e3 = entities.create(.{ .x = 40 });
    const e4 = entities.create(.{ .y = 'c' });
    const e5 = entities.create(.{ .y = 'd' });
    const e6 = entities.create(.{});
    const e7 = entities.create(.{});

    const Expected = struct {
        x: ?u32 = null,
        y: ?u8 = null,
    };

    {
        var expected = std.AutoHashMap(Handle, Expected).init(std.heap.page_allocator);
        defer expected.deinit();
        try expected.put(e0, .{ .x = 10, .y = 'a' });
        try expected.put(e1, .{ .x = 20, .y = 'b' });

        var iter = entities.iterator(.{ .x = .{}, .y = .{} });
        while (iter.next()) |entity| {
            try std.testing.expectEqual(expected.get(iter.handle()).?, .{
                .x = entity.x.*,
                .y = entity.y.*,
            });
            try std.testing.expect(expected.remove(iter.handle()));
        }
        try std.testing.expect(expected.count() == 0);
    }

    {
        var expected = std.AutoHashMap(Handle, Expected).init(std.heap.page_allocator);
        defer expected.deinit();
        try expected.put(e0, .{ .x = 10, .y = 'a' });
        try expected.put(e1, .{ .x = 20, .y = 'b' });
        try expected.put(e2, .{ .x = 30 });
        try expected.put(e3, .{ .x = 40 });

        var iter = entities.iterator(.{ .x = .{}, .y = .{ .optional = true } });
        while (iter.next()) |entity| {
            try std.testing.expectEqual(expected.get(iter.handle()).?, .{
                .x = entity.x.*,
                .y = if (entity.y) |y| y.* else null,
            });
            try std.testing.expect(expected.remove(iter.handle()));
        }
        try std.testing.expect(expected.count() == 0);
    }

    {
        var expected = std.AutoHashMap(Handle, Expected).init(std.heap.page_allocator);
        defer expected.deinit();
        try expected.put(e0, .{ .x = 10, .y = 'a' });
        try expected.put(e1, .{ .x = 20, .y = 'b' });
        try expected.put(e2, .{ .x = 30 });
        try expected.put(e3, .{ .x = 40 });
        try expected.put(e4, .{ .y = 'c' });
        try expected.put(e5, .{ .y = 'd' });
        try expected.put(e6, .{});
        try expected.put(e7, .{});

        var iter = entities.iterator(.{ .x = .{ .optional = true }, .y = .{ .optional = true } });
        while (iter.next()) |entity| {
            try std.testing.expectEqual(expected.get(iter.handle()).?, .{
                .x = if (entity.x) |x| x.* else null,
                .y = if (entity.y) |y| y.* else null,
            });
            try std.testing.expect(expected.remove(iter.handle()));
        }
        try std.testing.expect(expected.count() == 0);
    }

    {
        var expected = std.AutoHashMap(Handle, Expected).init(std.heap.page_allocator);
        defer expected.deinit();
        try expected.put(e0, .{ .x = 10, .y = 'a' });
        try expected.put(e1, .{ .x = 20, .y = 'b' });
        try expected.put(e4, .{ .y = 'c' });
        try expected.put(e5, .{ .y = 'd' });

        var iter = entities.iterator(.{ .x = .{ .optional = true }, .y = .{} });
        while (iter.next()) |entity| {
            try std.testing.expectEqual(expected.get(iter.handle()).?, .{
                .x = if (entity.x) |x| x.* else null,
                .y = entity.y.*,
            });
            try std.testing.expect(expected.remove(iter.handle()));
        }
        try std.testing.expect(expected.count() == 0);
    }

    {
        var iter = entities.iterator(.{ .x = .{ .mutable = true }, .y = .{} });
        while (iter.next()) |entity| {
            comptime assert(@TypeOf(entity.x) == *u32);
            comptime assert(@TypeOf(entity.y) == *const u8);
            entity.x.* += 1;
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 11);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 21);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 30);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 40);
    }

    {
        var iter = entities.iterator(.{ .x = .{ .mutable = true }, .y = .{ .optional = true } });
        while (iter.next()) |entity| {
            comptime assert(@TypeOf(entity.x) == *u32);
            comptime assert(@TypeOf(entity.y) == ?*const u8);
            entity.x.* += 1;
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 12);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 22);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 31);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 41);
    }

    {
        var iter = entities.iterator(.{ .x = .{ .mutable = true, .optional = true }, .y = .{ .optional = true } });
        while (iter.next()) |entity| {
            comptime assert(@TypeOf(entity.x) == ?*u32);
            comptime assert(@TypeOf(entity.y) == ?*const u8);
            if (entity.x) |x| {
                x.* += 1;
            }
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 13);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 23);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 32);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 42);
    }

    {
        var iter = entities.iterator(.{ .x = .{ .mutable = true, .optional = true }, .y = .{} });
        while (iter.next()) |entity| {
            comptime assert(@TypeOf(entity.x) == ?*u32);
            comptime assert(@TypeOf(entity.y) == *const u8);
            if (entity.x) |x| {
                x.* += 1;
            }
        }

        try std.testing.expect(entities.getComponent(e0, .x).?.* == 14);
        try std.testing.expect(entities.getComponent(e1, .x).?.* == 24);
        try std.testing.expect(entities.getComponent(e2, .x).?.* == 32);
        try std.testing.expect(entities.getComponent(e3, .x).?.* == 42);
    }
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
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

        var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 20);
            try std.testing.expect(iter.next().?.x.* == 30);
        }

        {
            var iter = entities.iterator(.{ .x = .{} });
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
            var iter = entities.iterator(.{ .x = .{} });
            try std.testing.expect(iter.next().?.x.* == 0);
            try std.testing.expect(iter.next().?.x.* == 10);
            try std.testing.expect(iter.next().?.x.* == 20);
            iter.swapRemove();
            try std.testing.expect(iter.next().?.x.* == 30);
        }

        {
            var iter = entities.iterator(.{ .x = .{} });
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
        const first_batch = [_]Handle{ e0, e1, x0, x1, y0, y1, xy0, xy1 };

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
        const second_batch = [_]Handle{ e0_new, e1_new, x0_new, x1_new, y0_new, y1_new, xy0_new, xy1_new };

        for (first_batch) |e| {
            try std.testing.expect(entities.getComponentChecked(e, .x) == error.UseAfterFree);
            try std.testing.expect(entities.getComponentChecked(e, .y) == error.UseAfterFree);
        }

        // TODO: test iters, test getcomponent on these

        for (first_batch, second_batch) |first, second| {
            var expected = first;
            expected.generation = @intToEnum(Handle.Generation, @enumToInt(expected.generation) + 1);
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

        var expected = std.AutoHashMap(Handle, void).init(allocator);
        defer expected.deinit();
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
        const IndexInPage = std.meta.fields(Entities(.{}).EntityPointer)[std.meta.fieldIndex(Entities(.{}).EntityPointer, "index").?].type;
        assert(std.math.maxInt(IndexInPage) > page_size);
    }

    var allocator = std.testing.allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();
    var created = std.ArrayList(Handle).init(allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(Handle{ .index = @intCast(Handle.Index, i), .generation = @intToEnum(Handle.Generation, 0) }, entity);
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
            Handle{ .index = @intCast(Handle.Index, i), .generation = @intToEnum(Handle.Generation, 1) },
            entities.create(.{}),
        );
    }
    try std.testing.expectError(error.OutOfMemory, entities.createChecked(.{}));

    // TODO: update this test or no since we have it externally?
    // // Wrap a generation counter
    // {
    //     const entity = Handle{ .index = 0, .generation = std.math.maxInt(Handle.Generation) };
    //     entities.slots[entity.index].generation = entity.generation;
    //     entities.swapRemove(entity);
    //     try std.testing.expectEqual(
    //         Handle{ .index = 0, .generation = @intCast(Handle.Generation, 0) },
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
    try std.testing.expectError(error.DoubleFree, entities.swapRemoveChecked(Handle{
        .index = 1,
        .generation = @intToEnum(Handle.Generation, 0),
    }));
}

test "change archetype" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const E = Entities(.{ .x = u32, .y = u8, .z = u16 });
    var entities = try E.init(allocator);
    defer entities.deinit();

    const ComponentFlags = E.ComponentFlags;

    var e = entities.create(.{});
    try expectEqual(entities.getComponent(e, .x), null);
    try expectEqual(entities.getComponent(e, .y), null);
    try expectEqual(entities.getComponent(e, .z), null);

    // Add a component, remove none
    entities.changeArchetype(e, .{
        .add = .{
            .x = 10,
        },
        .remove = ComponentFlags.initFromKinds(.{}),
    });
    try expectEqual(entities.getComponent(e, .x).?.*, 10);
    try expectEqual(entities.getComponent(e, .y), null);
    try expectEqual(entities.getComponent(e, .z), null);

    // Add a component, remove one that doesn't exist
    entities.changeArchetype(e, .{
        .add = .{
            .y = 20,
        },
        .remove = ComponentFlags.initFromKinds(.{.z}),
    });
    try expectEqual(entities.getComponent(e, .x).?.*, 10);
    try expectEqual(entities.getComponent(e, .y).?.*, 20);
    try expectEqual(entities.getComponent(e, .z), null);

    // Add a component that exists, remove one
    entities.changeArchetype(e, .{
        .add = .{
            .y = 30,
        },
        .remove = ComponentFlags.initFromKinds(.{.x}),
    });
    try expectEqual(entities.getComponent(e, .x), null);
    try expectEqual(entities.getComponent(e, .y).?.*, 30);
    try expectEqual(entities.getComponent(e, .z), null);

    // Add and remove the same component that doesn't exist
    entities.changeArchetype(e, .{
        .add = .{
            .z = 40,
        },
        .remove = ComponentFlags.initFromKinds(.{.z}),
    });
    try expectEqual(entities.getComponent(e, .x), null);
    try expectEqual(entities.getComponent(e, .y).?.*, 30);
    try expectEqual(entities.getComponent(e, .z).?.*, 40);

    // Add and remove the same component that does exist
    entities.changeArchetype(e, .{
        .add = .{
            .z = 50,
        },
        .remove = ComponentFlags.initFromKinds(.{.z}),
    });
    try expectEqual(entities.getComponent(e, .x), null);
    try expectEqual(entities.getComponent(e, .y).?.*, 30);
    try expectEqual(entities.getComponent(e, .z).?.*, 50);
}

test "random data" {
    const E = Entities(.{ .x = u32, .y = u8, .z = u16 });
    const ComponentFlags = E.ComponentFlags;
    const ArchetypeChange = E.ArchetypeChange;

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
        handle: Handle,
    };

    var rnd = std.rand.DefaultPrng.init(0);
    var truth = std.ArrayList(Created).init(allocator);
    defer truth.deinit();

    for (0..4000) |_| {
        switch (rnd.random().enumValue(enum { create, modify, change_arch, destroy })) {
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
            .change_arch => {
                if (truth.items.len > 0) {
                    for (0..rnd.random().uintLessThan(usize, 10)) |_| {
                        const index = rnd.random().uintLessThan(usize, truth.items.len);
                        var entity: *Created = &truth.items[index];
                        var change = ArchetypeChange{
                            .add = .{
                                .x = rnd.random().int(u32),
                                .y = rnd.random().int(u8),
                                .z = rnd.random().int(u16),
                            },
                            .remove = ComponentFlags.initFromKinds(.{}),
                        };

                        switch (rnd.random().enumValue(enum { none, x, y, z, xy, xz, yz, xyz })) {
                            .none => {},
                            .x => {
                                change.remove.set(.x);
                            },
                            .y => {
                                change.remove.set(.y);
                            },
                            .z => {
                                change.remove.set(.z);
                            },
                            .xy => {
                                change.remove.set(.x);
                                change.remove.set(.y);
                            },
                            .xz => {
                                change.remove.set(.x);
                                change.remove.set(.z);
                            },
                            .yz => {
                                change.remove.set(.y);
                                change.remove.set(.z);
                            },
                            .xyz => {
                                change.remove.set(.x);
                                change.remove.set(.y);
                                change.remove.set(.z);
                            },
                        }

                        if (change.remove.isSet(.x)) entity.data.x = null;
                        if (change.remove.isSet(.y)) entity.data.y = null;
                        if (change.remove.isSet(.z)) entity.data.z = null;

                        switch (rnd.random().enumValue(enum { none, x, y, z, xy, xz, yz, xyz })) {
                            .none => {
                                change.add.x = null;
                                change.add.y = null;
                                change.add.z = null;
                            },
                            .x => {
                                change.add.y = null;
                                change.add.z = null;
                            },
                            .y => {
                                change.add.x = null;
                                change.add.z = null;
                            },
                            .z => {
                                change.add.x = null;
                                change.add.y = null;
                            },
                            .xy => {
                                change.add.z = null;
                            },
                            .xz => {
                                change.add.y = null;
                            },
                            .yz => {
                                change.add.x = null;
                            },
                            .xyz => {},
                        }

                        if (change.add.x) |x| entity.data.x = x;
                        if (change.add.y) |y| entity.data.y = y;
                        if (change.add.z) |z| entity.data.z = z;

                        entities.changeArchetype(entity.handle, change);
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
            var truth_xyz = std.AutoArrayHashMap(Handle, Data).init(allocator);
            defer truth_xyz.deinit();
            var truth_xz = std.AutoArrayHashMap(Handle, Data).init(allocator);
            defer truth_xz.deinit();
            var truth_y = std.AutoArrayHashMap(Handle, Data).init(allocator);
            defer truth_y.deinit();
            var truth_all = std.AutoArrayHashMap(Handle, Data).init(allocator);
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

            var iter_xyz = entities.iterator(.{ .x = .{}, .y = .{}, .z = .{} });
            while (iter_xyz.next()) |entity| {
                var expected = truth_xyz.get(iter_xyz.handle()).?;
                _ = truth_xyz.swapRemove(iter_xyz.handle());
                try std.testing.expectEqual(expected.x.?, entity.x.*);
                try std.testing.expectEqual(expected.y.?, entity.y.*);
                try std.testing.expectEqual(expected.z.?, entity.z.*);
            }
            try std.testing.expect(truth_xyz.count() == 0);

            var iter_xz = entities.iterator(.{ .x = .{}, .z = .{} });
            while (iter_xz.next()) |entity| {
                var expected = truth_xz.get(iter_xz.handle()).?;
                _ = truth_xz.swapRemove(iter_xz.handle());
                try std.testing.expectEqual(expected.x.?, entity.x.*);
                try std.testing.expectEqual(expected.z.?, entity.z.*);
            }
            try std.testing.expect(truth_xz.count() == 0);

            var iter_y = entities.iterator(.{ .y = .{} });
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
        var iter = entities.iterator(.{ .x = .{}, .y = .{} });
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
        var iter = entities.iterator(.{ .x = .{} });
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
        var iter = entities.iterator(.{ .y = .{} });
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

test "prefab entities" {
    var allocator = std.testing.allocator;

    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    var prefab: @TypeOf(entities).PrefabEntity = .{ .y = 10, .z = 20 };
    var instance = entities.create(prefab);

    try std.testing.expect(entities.getComponent(instance, .x) == null);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);

    entities.addComponents(instance, @TypeOf(entities).PrefabEntity{ .x = 30 });
    try std.testing.expect(entities.getComponent(instance, .x).?.* == 30);
    try std.testing.expect(entities.getComponent(instance, .y).?.* == 10);
    try std.testing.expect(entities.getComponent(instance, .z).?.* == 20);
}
