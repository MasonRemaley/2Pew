const std = @import("std");
const builtin = @import("builtin");
const SegmentedListFirstShelfCount = @import("segmented_list.zig").SegmentedListFirstShelfCount;
const SlotMap = @import("slot_map.zig").SlotMap;

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

pub fn Entities(comptime componentTypes: anytype) type {
    return struct {
        const HandleSlotMap = SlotMap(EntityPointer, max_entities, EntityGeneration);
        const EntityPointer = struct {
            archetype_list: *ArchetypeList,
            index: u32,
        };

        pub const EntityHandle = HandleSlotMap.Handle;
        pub const Component = FieldEnum(Entity);

        // `Archetype` is a bit set with a bit for each component type.
        const Archetype: type = std.bit_set.IntegerBitSet(@typeInfo(Entity).Struct.fields.len);

        // XXX: sorting based on size no longer matters for these!
        // `Entity` has a field for every possible component type. This is for convenience, it is
        // not used at runtime. Fields are sorted from greatest to least alignment, see `PageHeader` for
        // rational.
        pub const Entity = entity: {
            const component_names = @typeInfo(@TypeOf(componentTypes)).Struct.fields;
            var fields: [component_names.len]Type.StructField = undefined;
            for (component_names, 0..) |component_name, i| {
                fields[i] = Type.StructField{
                    .name = component_name.name,
                    .type = @field(componentTypes, component_name.name),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(component_name.type),
                };
            }
            const AlignmentDescending = struct {
                fn lessThan(_: void, comptime lhs: Type.StructField, comptime rhs: Type.StructField) bool {
                    return @alignOf(rhs.type) < @alignOf(lhs.type);
                }
            };
            std.sort.sort(Type.StructField, &fields, {}, AlignmentDescending.lessThan);
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

        pub const Prefab = prefab: {
            const component_types = @typeInfo(Entity).Struct.fields;
            var fields: [component_types.len]Type.StructField = undefined;
            for (component_types, 0..) |field, i| {
                fields[i] = Type.StructField{
                    .name = field.name,
                    .type = ?field.type,
                    .default_value = &null,
                    .is_comptime = false,
                    .alignment = @alignOf(?field.type),
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

        // Stores component data and handles for entities of a given archetype.
        const ArchetypeList = struct {
            const first_shelf_count = 8;
            const Components = components: {
                var fields: [@typeInfo(Entity).Struct.fields.len]Type.StructField = undefined;
                for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    const FieldType = SegmentedListFirstShelfCount(field.type, first_shelf_count, false);
                    fields[i] = Type.StructField{
                        .name = field.name,
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

            // A segmented list for each component.
            handles: SegmentedListFirstShelfCount(EntityHandle, first_shelf_count, false) = .{},
            comps: Components = .{},
            archetype: Archetype,
            // XXX: this as a type?
            len: HandleSlotMap.Index,

            fn init(archetype: Archetype) !ArchetypeList {
                return .{
                    .archetype = archetype,
                    .len = 0,
                };
            }

            fn deinit(self: *@This(), allocator: Allocator) void {
                inline for (@typeInfo(Entity).Struct.fields) |field| {
                    @field(self.comps, field.name).deinit(allocator);
                }
                self.handles.deinit(allocator);
            }

            // XXX: better api that returns pointers so don't have to recalculate them?
            fn createEntity(self: *@This(), allocator: Allocator, handle: EntityHandle) !u32 {
                // XXX: could optimize this logic a little since all lists are gonna match eachother, also
                // only really need one size, etc
                // XXX: self.archetype vs making these nullable?
                inline for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    if (self.archetype.isSet(i)) {
                        // XXX: dup math cross components, here and iterator and remove
                        _ = try @field(self.comps, field.name).addOne(allocator);
                    }
                }
                // XXX: same notes here
                try self.handles.append(allocator, handle);
                // XXX: can't overflow because fails earlier right?
                const index = self.len;
                self.len += 1;
                return index;
            }

            // XXX: put in (debug mode?) protection to prevent doing this while iterating? same for creating?
            // XXX: document that the ecs moves structures (so e.g. internal pointers will get invalidated). this
            // was already true but only happened when changing shape before which is less commonly done.
            fn removeEntity(self: *ArchetypeList, index: u32, slot_map: *HandleSlotMap) void {
                // XXX: instead of separate len use handles len? or fold all into same thing eventually anyway..?
                // XXX: only needed in debug mode right?
                assert(index < self.len);
                inline for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    if (self.archetype.isSet(i)) {
                        // XXX: here and below, i think it's okay to pop assign as lon gas we do unchecked, since
                        // the memory is guarenteed to be there right? (the problem case is swap removing if size 1)
                        var components = &@field(self.comps, field.name);
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
                self.len -= 1;
            }

            fn ComponentType(comptime componentField: Component) type {
                return std.meta.fieldInfo(Entity, componentField).type;
            }

            fn ComponentIterator(comptime componentField: Component) type {
                return SegmentedListFirstShelfCount(ComponentType(componentField), first_shelf_count, false).Iterator;
            }

            fn componentIterator(self: *@This(), comptime componentField: Component) ComponentIterator(componentField) {
                return @field(self.comps, std.meta.fieldInfo(Entity, componentField).name).iterator(0);
            }

            // XXX: do we still need invalid handles or no? (if so do it the better way where zig's type system
            // knows about it...)
            const HandleIterator = SegmentedListFirstShelfCount(EntityHandle, first_shelf_count, false).Iterator;

            fn handleIterator(self: *@This()) HandleIterator {
                return self.handles.iterator(0);
            }

            fn getComponent(self: *@This(), index: u32, comptime componentField: Component) *ComponentType(componentField) {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return @field(self.comps, std.meta.fieldInfo(Entity, componentField).name).uncheckedAt(index);
            }

            fn getHandle(self: *@This(), index: u32) EntityHandle {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return self.handles.uncheckedAt(index);
            }
        };

        allocator: Allocator,
        slot_map: HandleSlotMap,
        archetype_lists: AutoArrayHashMapUnmanaged(Archetype, ArchetypeList),

        // TODO: need errdefers here, and maybe elsewhere too, for the allocations
        pub fn init(allocator: Allocator) !@This() {
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

        pub fn create(self: *@This(), entity: anytype) EntityHandle {
            return self.createChecked(entity) catch |err|
                std.debug.panic("failed to create entity: {}", .{err});
        }

        fn setComponents(pointer: *const EntityPointer, components: anytype) void {
            inline for (@typeInfo(@TypeOf(components.*)).Struct.fields) |f| {
                const field = @intToEnum(Component, std.meta.fieldIndex(Entity, f.name).?);
                if (@TypeOf(components.*) == Prefab) {
                    if (@field(components.*, f.name)) |component| {
                        pointer.archetype_list.getComponent(pointer.index, field).* = component;
                    }
                } else {
                    pointer.archetype_list.getComponent(pointer.index, field).* = @field(components.*, f.name);
                }
            }
        }

        pub fn createChecked(self: *@This(), components: anytype) !EntityHandle {
            const archetype = componentsArchetype(components);
            const archetype_list = try self.getOrPutArchetypeList(archetype);
            const handle = try self.slot_map.create(undefined);
            const pointer = self.slot_map.getUnchecked(handle);
            pointer.* = EntityPointer{
                .archetype_list = archetype_list,
                .index = try archetype_list.createEntity(self.allocator, handle),
            };
            setComponents(pointer, &components);
            return handle;
        }

        pub fn remove(self: *@This(), entity: EntityHandle) void {
            return self.removeChecked(entity) catch |err|
                std.debug.panic("failed to remove entity {}: {}", .{ entity, err });
        }

        fn removeChecked(self: *@This(), entity: EntityHandle) !void {
            const entity_pointer = try self.slot_map.remove(entity);
            entity_pointer.archetype_list.removeEntity(entity_pointer.index, &self.slot_map);
        }

        pub fn addComponents(self: *@This(), entity: EntityHandle, components: anytype) void {
            self.addComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to add components: {}", .{err});
        }

        // TODO: test errors
        fn addComponentsChecked(self: *@This(), handle: EntityHandle, components: anytype) !void {
            try self.changeArchetype(handle, components, .{});
        }

        // TODO: return a bool indicating if it was present or no? also we could have a faster
        // hasComponents check for when you don't need the actual data?
        pub fn removeComponents(self: *@This(), entity: EntityHandle, components: anytype) void {
            self.removeComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to remove components: {}", .{err});
        }

        // TODO: test errors
        fn removeComponentsChecked(self: *@This(), handle: EntityHandle, components: anytype) !void {
            try self.changeArchetype(handle, .{}, components);
        }

        fn getOrPutArchetypeList(self: *@This(), archetype: Archetype) !*ArchetypeList {
            comptime assert(max_archetypes > 0);

            const entry = self.archetype_lists.getOrPutAssumeCapacity(archetype);

            if (!entry.found_existing) {
                // XXX: just do this with the allocator now? check once at the end of every frame for the halfway
                // mark or whatever
                if (self.archetype_lists.count() >= max_archetypes) {
                    return error.OutOfArchetypes;
                } else if (self.archetype_lists.count() == max_archetypes / 2) {
                    std.log.warn("archetype map halfway depleted", .{});
                }
                entry.value_ptr.* = try ArchetypeList.init(archetype);
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
                        archetype.set(std.meta.fieldIndex(Entity, field.name).?);
                    }
                }
                return archetype;
            } else if (@typeInfo(@TypeOf(components)).Struct.is_tuple) {
                var archetype = Archetype.initEmpty();
                inline for (components) |c| {
                    const component: Component = c;
                    archetype.set(@enumToInt(component));
                }
                return archetype;
            } else comptime {
                var archetype = Archetype.initEmpty();
                for (@typeInfo(@TypeOf(components)).Struct.fields) |field| {
                    archetype.set(std.meta.fieldIndex(Entity, field.name).?);
                }
                return archetype;
            }
        }

        fn copyComponents(to: *const EntityPointer, from: EntityPointer, which: Archetype) void {
            inline for (0..@typeInfo(Entity).Struct.fields.len) |i| {
                if (which.isSet(i)) {
                    const field = @intToEnum(Component, i);
                    to.archetype_list.getComponent(to.index, field).* = from.archetype_list.getComponent(from.index, field).*;
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
            handle: EntityHandle,
            add_components: anytype,
            remove_components: anytype,
        ) !void {
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
                .index = try archetype_list.createEntity(self.allocator, handle),
            };

            // Set the component data at the new location
            copyComponents(pointer, old_pointer, components_copied);
            setComponents(pointer, &add_components);

            // Delete the old data
            old_pointer.archetype_list.removeEntity(old_pointer.index, &self.slot_map);
        }

        // TODO: check assertions
        fn getComponentChecked(self: *@This(), entity: EntityHandle, comptime component: Component) !?*std.meta.fieldInfo(Entity, component).type {
            // XXX: should it just return null from there or is that slower?
            const entity_pointer = try self.slot_map.get(entity);
            if (!entity_pointer.archetype_list.archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return entity_pointer.archetype_list.getComponent(entity_pointer.index, component);
        }

        pub fn getComponent(self: *@This(), entity: EntityHandle, comptime component: Component) ?*std.meta.fieldInfo(Entity, component).type {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn Iterator(comptime components: anytype) type {
            return struct {
                const Components = entity: {
                    var fields: [@typeInfo(@TypeOf(components)).Struct.fields.len]Type.StructField = undefined;
                    var i = 0;
                    for (components) |component| {
                        const entityFieldEnum: Component = component;
                        const entityField = std.meta.fieldInfo(Entity, entityFieldEnum);
                        const FieldType = *entityField.type;
                        fields[i] = Type.StructField{
                            .name = entityField.name,
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
                    handle: EntityHandle,
                    comps: Components,
                };

                archetype: Archetype,
                archetype_lists: AutoArrayHashMapUnmanaged(Archetype, ArchetypeList).Iterator,
                archetype_list: ?*ArchetypeList,
                handle_iterator: ArchetypeList.HandleIterator,

                fn init(entities: *Entities(componentTypes)) @This() {
                    return .{
                        // TODO: replace with getter if possible
                        .archetype = comptime archetype: {
                            var archetype = Archetype.initEmpty();
                            for (components) |field| {
                                const entityField: Component = field;
                                archetype.set(@enumToInt(entityField));
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
            };
        }

        pub fn iterator(self: *@This(), components: anytype) Iterator(components) {
            return Iterator(components).init(self);
        }

        // XXX: ...
        pub fn deleteAll(self: *@This(), comptime component: Component) void {
            var it = self.iterator(.{component});
            while (it.next()) |entity| {
                self.remove(entity.handle);
            }
        }
    };
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
//     try std.testing.expectEqual(entity_0_0, EntityHandle{ .index = 0, .generation = 0 });
//     const entity_1_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_1_0, EntityHandle{ .index = 1, .generation = 0 });
//     const entity_2_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_2_0, EntityHandle{ .index = 2, .generation = 0 });
//     const entity_3_0 = entities.create(.{});
//     try std.testing.expectEqual(entity_3_0, EntityHandle{ .index = 3, .generation = 0 });

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 2);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 3);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

//     entities.remove(entity_1_0);

//     try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index, 0);
//     try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index, 2);
//     try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index, 1);
//     try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

//     entities.remove(entity_3_0);

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
    const EntityHandle = @TypeOf(entities).EntityHandle;
    defer entities.deinit();
    var created = std.ArrayList(EntityHandle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(EntityHandle{ .index = @intCast(Entities(.{}).HandleSlotMap.Index, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expectError(error.AtCapacity, entities.createChecked(.{}));
    // XXX: ...
    // const page_pool_size = entities.page_pool.items.len;

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.remove(entity);
    }
    // XXX: ...
    // try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // Assert that all pages are empty
    {
        var archetype_lists = entities.archetype_lists.iterator();
        while (archetype_lists.next()) |archetype_list| {
            try std.testing.expect(archetype_list.value_ptr.len == 0);
        }
    }

    // Create a bunch of entities again
    for (0..max_entities) |i| {
        try std.testing.expectEqual(
            EntityHandle{ .index = @intCast(Entities(.{}).HandleSlotMap.Index, i), .generation = 1 },
            entities.create(.{}),
        );
    }
    try std.testing.expectError(error.AtCapacity, entities.createChecked(.{}));
    // XXX: ...
    // try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // XXX: update this test or no since we have it externally?
    // // Wrap a generation counter
    // {
    //     const entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
    //     entities.slots[entity.index].generation = entity.generation;
    //     entities.remove(entity);
    //     try std.testing.expectEqual(
    //         EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
    //         entities.create(.{}),
    //     );
    // }
}

test "safety" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();

    const entity = entities.create(.{});
    entities.remove(entity);
    try std.testing.expectError(error.DoubleFree, entities.removeChecked(entity));
    try std.testing.expectError(error.OutOfBounds, entities.removeChecked(@TypeOf(entities).EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}

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
        handle: E.EntityHandle,
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
                        entities.remove(removed.handle);
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
            var truth_xyz = std.AutoArrayHashMap(E.EntityHandle, Data).init(std.testing.allocator);
            defer truth_xyz.deinit();
            var truth_xz = std.AutoArrayHashMap(E.EntityHandle, Data).init(std.testing.allocator);
            defer truth_xz.deinit();
            var truth_y = std.AutoArrayHashMap(E.EntityHandle, Data).init(std.testing.allocator);
            defer truth_y.deinit();
            var truth_all = std.AutoArrayHashMap(E.EntityHandle, Data).init(std.testing.allocator);
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
