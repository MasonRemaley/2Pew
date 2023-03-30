const std = @import("std");
const builtin = @import("builtin");
const SegmentedList = @import("segmented_list.zig").SegmentedList;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
const Type = std.builtin.Type;

const SlotIndex = u32;
const EntityGeneration = switch (builtin.mode) {
    .Debug, .ReleaseSafe => u32,
    .ReleaseSmall, .ReleaseFast => u0,
};

pub const max_entities: SlotIndex = 1000000;
const invalid_entity_index = std.math.maxInt(SlotIndex);
const page_size = 4096;

const max_pages = max_entities / 32;
const max_archetypes = 40000;

pub const EntityHandle = struct {
    index: SlotIndex,
    generation: EntityGeneration,
};

pub fn Entities(comptime componentTypes: anytype) type {
    return struct {
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

        // XXX: temp for refactor
        const EntityIndex = struct {
            index_in_page: u32,
        };
        // XXX: temp for refactor
        const EntityPointer = struct {
            page_list: *PageList,
            index: EntityIndex,
        };

        // Each entity handle points to a slot which in turn points to the actual entity data.
        // This indirection allows the actual data to move without invalidating the handle.
        const EntitySlot = struct {
            generation: EntityGeneration,
            entity_pointer: EntityPointer,
        };

        // XXX: rename this idk to what yet
        // A linked list of max_pages of a single archetype. Pages with available space are kept sorted
        // to the front of the list.
        const PageList = struct {
            const Components = components: {
                var fields: [@typeInfo(Entity).Struct.fields.len]Type.StructField = undefined;
                for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    const FieldType = SegmentedList(field.type, 0);
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
            handles: SegmentedList(EntityHandle, 0) = .{},
            comps: Components = .{},
            archetype: Archetype,
            // XXX: this as a type?
            len: SlotIndex,

            fn init(archetype: Archetype) !PageList {
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
            fn removeEntity(self: *PageList, entity_index: EntityIndex, slots: *[]EntitySlot) void {
                // XXX: instead of separate len use handles len? or fold all into same thing eventually anyway..?
                // XXX: only needed in debug mode right?
                assert(entity_index.index_in_page < self.len);
                inline for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    if (self.archetype.isSet(i)) {
                        // XXX: here and below, i think it's okay to pop assign as lon gas we do unchecked, since
                        // the memory is guarenteed to be there right? (the problem case is swap removing if size 1)
                        var components = &@field(self.comps, field.name);
                        components.uncheckedAt(entity_index.index_in_page).* = components.pop().?;
                    }
                }
                const moved_handle = self.handles.pop().?;
                // XXX: only really need to update the generation here right?
                self.handles.uncheckedAt(entity_index.index_in_page).* = moved_handle;
                // XXX: checking this in case we're deleting the last one in which case we don't wanna mess with
                // slots...? we also maybe don't wanna do the above stuff but may not matter?? is there a way to
                // make this less error prone? maybe in general don't do logic when last one, or return stuff to
                // be used outside to avoid probme based on order, etc
                if (entity_index.index_in_page != self.handles.len) {
                    // XXX: don't need to check generation, always checked at public interface right?
                    slots.*[moved_handle.index].entity_pointer.index.index_in_page = entity_index.index_in_page;
                }
                self.len -= 1;
            }

            fn ComponentType(comptime componentField: Component) type {
                return std.meta.fieldInfo(Entity, componentField).type;
            }

            fn ComponentIterator(comptime componentField: Component) type {
                return SegmentedList(ComponentType(componentField), 0).Iterator;
            }

            fn componentIterator(self: *@This(), comptime componentField: Component) ComponentIterator(componentField) {
                return @field(self.comps, std.meta.fieldInfo(Entity, componentField).name).iterator(0);
            }

            // XXX: do we still need invalid handles or no? (if so do it the better way where zig's type system
            // knows about it...)
            const HandleIterator = SegmentedList(EntityHandle, 0).Iterator;

            fn handleIterator(self: *@This()) HandleIterator {
                return self.handles.iterator(0);
            }

            fn getComponent(self: *@This(), index: EntityIndex, comptime componentField: Component) *ComponentType(componentField) {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return @field(self.comps, std.meta.fieldInfo(Entity, componentField).name).uncheckedAt(index.index_in_page);
            }

            fn getHandle(self: *@This(), index: EntityIndex) EntityHandle {
                // XXX: unchecked is correct right? assert in debug mode or no?
                return self.handles.uncheckedAt(index.index_in_page);
            }
        };

        // XXX: any easy way to encapsulate this? i guess into the slot map pattern or what?
        allocator: Allocator,
        slots: []EntitySlot,
        free_slot_indices: []SlotIndex,
        page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList),

        pub fn init(allocator: Allocator) !@This() {
            return .{
                .allocator = allocator,
                .slots = entities: {
                    var entities = try allocator.alloc(EntitySlot, max_entities);
                    entities.len = 0;
                    break :entities entities;
                },
                .free_slot_indices = free_slot_indices: {
                    var free_slot_indices = try allocator.alloc(SlotIndex, max_entities);
                    free_slot_indices.len = 0;
                    break :free_slot_indices free_slot_indices;
                },
                .page_lists = page_lists: {
                    var page_lists = AutoArrayHashMapUnmanaged(Archetype, PageList){};
                    // We leave room for one extra because we don't know whether or not getOrPut
                    // will allocate until afte it's done.
                    try page_lists.ensureTotalCapacity(allocator, max_archetypes + 1);
                    break :page_lists page_lists;
                },
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.slots);
            self.allocator.free(self.free_slot_indices);
            for (self.page_lists.values()) |*page_list| {
                page_list.deinit(self.allocator);
            }
            self.page_lists.deinit(self.allocator);
        }

        pub fn create(self: *@This(), entity: anytype) EntityHandle {
            return self.createChecked(entity) catch |err|
                std.debug.panic("failed to create entity: {}", .{err});
        }

        pub fn createChecked(self: *@This(), components: anytype) !EntityHandle {
            // Find a free index for the entity
            const index = index: {
                if (self.free_slot_indices.len > 0) {
                    // Pop an id from the free list
                    const top = self.free_slot_indices.len - 1;
                    const index = self.free_slot_indices[top];
                    self.free_slot_indices.len = top;
                    break :index index;
                } else if (self.slots.len < max_entities) {
                    if (self.slots.len == max_entities / 2) {
                        // XXX: why does this only show up in debug builds of bench?
                        std.log.warn("entity slots halfway depleted", .{});
                    }
                    // Add a new entity to the end of the list
                    const top = self.slots.len;
                    self.slots.len += 1;
                    self.slots[top] = .{
                        .generation = 0,
                        .entity_pointer = undefined,
                    };
                    break :index @intCast(SlotIndex, top);
                } else {
                    return error.OutOfEntities;
                }
            };

            const entity = EntityHandle{
                .index = index,
                .generation = self.slots[index].generation,
            };

            return try self.setArchetype(entity, components, .{}, true);
        }

        pub fn remove(self: *@This(), entity: EntityHandle) void {
            return self.removeChecked(entity) catch |err|
                std.debug.panic("failed to remove entity {}: {}", .{ entity, err });
        }

        fn removeChecked(self: *@This(), entity: EntityHandle) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            // Make sure our free list is not empty, this is only reachable with generation safety
            // turned off (or if a counter wraps and our currently implementation doesn't check for
            // that.)
            if (self.free_slot_indices.len == max_entities) {
                return error.DoubleFree;
            }

            // Unset the exists bit, and reorder the page
            const slot = &self.slots[entity.index];
            slot.entity_pointer.page_list.removeEntity(slot.entity_pointer.index, &self.slots);

            // Increment this entity slot's generation so future uses will fail
            if (EntityGeneration != u0) {
                slot.generation +%= 1;
            }

            // Add the entity to the free list
            const top = self.free_slot_indices.len;
            self.free_slot_indices.len += 1;
            self.free_slot_indices[top] = entity.index;
        }

        pub fn addComponents(self: *@This(), entity: EntityHandle, components: anytype) void {
            self.addComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to add components: {}", .{err});
        }

        // TODO: test errors
        fn addComponentsChecked(self: *@This(), entity: EntityHandle, components: anytype) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            _ = try self.setArchetype(entity, components, .{}, false);
        }

        // TODO: return a bool indicating if it was present or no? also we could have a faster
        // hasComponents check for when you don't need the actual data?
        pub fn removeComponents(self: *@This(), entity: EntityHandle, components: anytype) void {
            self.removeComponentsChecked(entity, components) catch |err|
                std.debug.panic("failed to remove components: {}", .{err});
        }

        // TODO: test errors
        fn removeComponentsChecked(self: *@This(), entity: EntityHandle, components: anytype) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            _ = try self.setArchetype(entity, .{}, components, false);
        }

        fn getOrPutPageListEnsureAvailable(self: *@This(), archetype: Archetype) !*PageList {
            comptime assert(max_archetypes > 0);

            const entry = self.page_lists.getOrPutAssumeCapacity(archetype);

            if (!entry.found_existing) {
                // XXX: just do this with the allocator now? check once at the end of every frame for the halfway
                // mark or whatever
                if (self.page_lists.count() >= max_archetypes) {
                    return error.OutOfArchetypes;
                } else if (self.page_lists.count() == max_archetypes / 2) {
                    std.log.warn("archetype map halfway depleted", .{});
                }
                entry.value_ptr.* = try PageList.init(archetype);
            }

            return entry.value_ptr;
        }

        // TODO: test the failure conditions here?
        // TODO: early out if no change?
        // TODO: make remove_components comptime?
        fn setArchetype(
            self: *@This(),
            entity: EntityHandle,
            add_components: anytype,
            remove_components: anytype,
            comptime create_entity: bool,
        ) !EntityHandle {
            if (create_entity and remove_components.len > 0) {
                @compileError("cannot remove components if the entity does not yet exist");
            }

            const previous_archetype = if (create_entity)
                Archetype.initEmpty()
            else
                self.slots[entity.index].entity_pointer.page_list.archetype;

            const components_added = components_added: {
                if (@TypeOf(add_components) == Prefab) {
                    var components_added = Archetype.initEmpty();
                    inline for (comptime @typeInfo(@TypeOf(add_components)).Struct.fields) |field| {
                        if (@field(add_components, field.name) != null) {
                            components_added.set(std.meta.fieldIndex(Entity, field.name).?);
                        }
                    }
                    break :components_added components_added;
                } else comptime {
                    var components_added = Archetype.initEmpty();
                    for (@typeInfo(@TypeOf(add_components)).Struct.fields) |field| {
                        components_added.set(std.meta.fieldIndex(Entity, field.name).?);
                    }
                    break :components_added components_added;
                }
            };

            const components_removed = components_removed: {
                var components_removed = Archetype.initEmpty();
                inline for (remove_components) |removed| {
                    const fieldEnum: Component = removed;
                    components_removed.set(@enumToInt(fieldEnum));
                }
                break :components_removed components_removed;
            };

            const archetype = previous_archetype.unionWith(components_added)
                .differenceWith(components_removed);

            // Create the new entity
            const slot = &self.slots[entity.index];
            const old_entity_pointer = slot.entity_pointer;
            const page_list = try self.getOrPutPageListEnsureAvailable(archetype);
            slot.entity_pointer.page_list = page_list;
            slot.entity_pointer.index.index_in_page = try page_list.createEntity(self.allocator, entity);

            // If this entity data is replacing an existing one, copy the original components over
            if (!create_entity) {
                // Copy the old components
                const copy = previous_archetype.intersectWith(archetype)
                    .differenceWith(components_added);
                inline for (0..@typeInfo(Entity).Struct.fields.len) |i| {
                    if (copy.isSet(i)) {
                        const field = @intToEnum(Component, i);
                        slot.entity_pointer.page_list.getComponent(slot.entity_pointer.index, field).* = old_entity_pointer.page_list.getComponent(old_entity_pointer.index, field).*;
                    }
                }

                // Delete the old entity
                old_entity_pointer.page_list.removeEntity(old_entity_pointer.index, &self.slots);
            }

            // Initialize the new entity
            inline for (@typeInfo(@TypeOf(add_components)).Struct.fields) |f| {
                const field = @intToEnum(Component, std.meta.fieldIndex(Entity, f.name).?);
                if (@TypeOf(add_components) == Prefab) {
                    if (@field(add_components, f.name)) |component| {
                        slot.entity_pointer.page_list.getComponent(slot.entity_pointer.index, field).* = component;
                    }
                } else {
                    slot.entity_pointer.page_list.getComponent(slot.entity_pointer.index, field).* = @field(add_components, f.name);
                }
            }

            // Return the handle to the entity
            return entity;
        }

        // TODO: check assertions
        fn getComponentChecked(self: *@This(), entity: EntityHandle, comptime component: Component) !?*std.meta.fieldInfo(Entity, component).type {
            // TODO: dup code
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            // XXX: should it just return null from there or is that slower?
            const slot = self.slots[entity.index];
            if (!slot.entity_pointer.page_list.archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return slot.entity_pointer.page_list.getComponent(slot.entity_pointer.index, component);
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
                page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList).Iterator,
                page_list: ?*PageList,
                handle_iterator: PageList.HandleIterator,

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
                        .page_lists = entities.page_lists.iterator(),
                        .page_list = null,
                        // XXX: ...
                        .handle_iterator = undefined,
                    };
                }

                pub fn next(self: *@This()) ?Item {
                    while (true) {
                        // If we don't have a page list, find the next compatible archetype's page
                        // list
                        if (self.page_list == null) {
                            self.page_list = while (self.page_lists.next()) |page| {
                                if (page.key_ptr.supersetOf(self.archetype)) {
                                    break page.value_ptr;
                                }
                            } else return null;
                            self.handle_iterator = self.page_list.?.handleIterator();
                        }

                        // Get the next entity in this page list, if it exists
                        if (self.handle_iterator.peek()) |handle| {
                            var item: Item = undefined;
                            item.handle = handle.*;
                            inline for (@typeInfo(Components).Struct.fields) |field| {
                                @field(item.comps, field.name) = &@field(self.page_list.?.comps, field.name).dynamic_segments[self.handle_iterator.shelf_index][self.handle_iterator.box_index];
                            }
                            _ = self.handle_iterator.next();
                            return item;
                        }

                        // XXX: can't we just ask for it here..?
                        self.page_list = null;
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

test "free list" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();

    const entity_0_0 = entities.create(.{});
    try std.testing.expectEqual(entity_0_0, EntityHandle{ .index = 0, .generation = 0 });
    const entity_1_0 = entities.create(.{});
    try std.testing.expectEqual(entity_1_0, EntityHandle{ .index = 1, .generation = 0 });
    const entity_2_0 = entities.create(.{});
    try std.testing.expectEqual(entity_2_0, EntityHandle{ .index = 2, .generation = 0 });
    const entity_3_0 = entities.create(.{});
    try std.testing.expectEqual(entity_3_0, EntityHandle{ .index = 3, .generation = 0 });

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index.index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index.index_in_page, 3);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

    entities.remove(entity_1_0);

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index.index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 0);

    entities.remove(entity_3_0);

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 1);

    _ = entities.create(.{});
    _ = entities.create(.{});
    _ = entities.create(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_0_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].entity_pointer.index.index_in_page, 3);
    try std.testing.expectEqual(entities.slots[entity_1_0.index].generation, 1);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].generation, 0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index.index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].generation, 1);
    try std.testing.expectEqual(entities.slots[4].entity_pointer.index.index_in_page, 4);
    try std.testing.expectEqual(entities.slots[4].generation, 0);
}

test "limits" {
    // The max entity id should be considered invalid
    assert(max_entities < std.math.maxInt(SlotIndex));

    // Make sure our page index type is big enough
    {
        // TODO: break this out into constant?
        const EntityIndex = Entities(.{}).EntityIndex;
        const IndexInPage = std.meta.fields(EntityIndex)[std.meta.fieldIndex(EntityIndex, "index_in_page").?].type;
        assert(std.math.maxInt(IndexInPage) > page_size);
    }

    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();
    var created = std.ArrayList(EntityHandle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(EntityHandle{ .index = @intCast(SlotIndex, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expectError(error.OutOfEntities, entities.createChecked(.{}));
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
        var page_lists = entities.page_lists.iterator();
        while (page_lists.next()) |page_list| {
            try std.testing.expect(page_list.value_ptr.len == 0);
        }
    }

    // Create a bunch of entities again
    for (0..max_entities) |i| {
        try std.testing.expectEqual(
            EntityHandle{ .index = @intCast(SlotIndex, i), .generation = 1 },
            entities.create(.{}),
        );
    }
    try std.testing.expectError(error.OutOfEntities, entities.createChecked(.{}));
    // XXX: ...
    // try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // Wrap a generation counter
    {
        const entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
        entities.slots[entity.index].generation = entity.generation;
        entities.remove(entity);
        try std.testing.expectEqual(
            EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
            entities.create(.{}),
        );
    }
}

test "safety" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit();

    const entity = entities.create(.{});
    entities.remove(entity);
    try std.testing.expectError(error.BadGeneration, entities.removeChecked(entity));
    try std.testing.expectError(error.BadIndex, entities.removeChecked(EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}

// TODO: test 0 sized components? (used in game seemingly correctly!)
test "random data" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(allocator);
    defer entities.deinit();

    const Data = struct {
        x: ?u32 = null,
        y: ?u8 = null,
        z: ?u16 = null,
    };
    const Created = struct {
        data: Data,
        handle: EntityHandle,
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
            var truth_xyz = std.AutoArrayHashMap(EntityHandle, Data).init(std.testing.allocator);
            defer truth_xyz.deinit();
            var truth_xz = std.AutoArrayHashMap(EntityHandle, Data).init(std.testing.allocator);
            defer truth_xz.deinit();
            var truth_y = std.AutoArrayHashMap(EntityHandle, Data).init(std.testing.allocator);
            defer truth_y.deinit();
            var truth_all = std.AutoArrayHashMap(EntityHandle, Data).init(std.testing.allocator);
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
