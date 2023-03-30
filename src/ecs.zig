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
            page: *PageHeader,
            index_in_page: u16,
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

        // A page contains entities of a single archetype.
        const PageHeader = struct {
            next_available: ?*PageHeader,
            next: ?*PageHeader,
            archetype: Archetype,
            len: u16,
            capacity: u16,
            component_arrays: u16,
            handle_array: u16,

            // XXX: assert page alignment or at least explain?
            fn init(page_pool: *ArrayListUnmanaged(*PageHeader), archetype: Archetype) !*PageHeader {
                comptime assert(@sizeOf(PageHeader) < page_size);

                var ptr: u16 = 0;

                // Store the header, no alignment necessary since we start out page aligned
                ptr += @sizeOf(PageHeader);

                // Store the handle array
                comptime assert(@alignOf(PageHeader) >= @alignOf(EntityHandle));
                const handle_array = ptr;

                // Calculate how many entities can actually be stored
                var components_size: u16 = 0;
                var max_component_alignment: u16 = 1;
                var first = true;
                inline for (@typeInfo(Entity).Struct.fields, 0..) |component, i| {
                    if (archetype.isSet(i)) {
                        if (first) {
                            first = false;
                            // XXX: inserted this fix to fix archetypes with ONLY zsts. there may be a better fix, but,
                            // we don't care cause we're replacing this memory layout anyway i just want the tests to pass.
                            max_component_alignment = std.math.max(@alignOf(component.type), 1);
                        }
                        components_size += @sizeOf(component.type);
                    }
                }

                const padding_conservative = max_component_alignment - 1;
                const entity_size = @sizeOf(EntityHandle) + components_size;
                const conservative_capacity = (page_size - ptr - padding_conservative) / entity_size;

                assert(conservative_capacity > 0);

                ptr += @sizeOf(EntityHandle) * conservative_capacity;

                // Store the component arrays
                ptr = std.mem.alignForwardGeneric(u16, ptr, max_component_alignment);
                const component_arrays = ptr;

                if (page_pool.items.len == page_pool.capacity) {
                    return error.OutOfPages;
                } else if (page_pool.items.len == page_pool.capacity / 2) {
                    std.log.warn("page pool halfway depleted", .{});
                }
                var page_index = page_pool.items.len;
                page_pool.items.len += 1;
                var page = page_pool.items[page_index];
                page.* = PageHeader{
                    .next_available = null,
                    // XXX: about to be overwritten?
                    .next = null,
                    .archetype = archetype,
                    .capacity = conservative_capacity,
                    .len = 0,
                    .handle_array = handle_array,
                    .component_arrays = component_arrays,
                };

                // Initialize with invalid handles
                var handles = page.handleArray();
                for (0..conservative_capacity) |i| {
                    handles[i].index = invalid_entity_index;
                }

                return page;
            }

            fn deinit(self: *PageHeader, allocator: Allocator) void {
                allocator.free(@ptrCast(*[page_size]u8, self));
            }

            fn createEntityAssumeCapacity(self: *@This(), handle: EntityHandle) u16 {
                var handles = self.handleArray();
                for (0..self.capacity) |i| {
                    if (handles[i].index == invalid_entity_index) {
                        handles[i] = handle;
                        self.len += 1;
                        return @intCast(u16, i);
                    }
                }
                // TODO: restructure so this assertions is checked at the beginning of this call again by having it return null?
                unreachable; // Page in available list has no space available
            }

            fn removeEntity(self: *PageHeader, index: usize) void {
                self.len -= 1;
                self.handleArray()[index].index = invalid_entity_index;
            }

            fn handleArray(self: *@This()) [*]EntityHandle {
                return @intToPtr([*]EntityHandle, @ptrToInt(self) + self.handle_array);
            }

            fn ComponentArray(comptime componentField: Component) type {
                return [*]std.meta.fieldInfo(Entity, componentField).type;
            }

            fn componentArray(self: *PageHeader, comptime componentField: Component) ComponentArray(componentField) {
                var ptr: usize = self.component_arrays;
                inline for (@typeInfo(Entity).Struct.fields, 0..) |component, i| {
                    if (self.archetype.isSet(i)) {
                        if (@intToEnum(Component, i) == componentField) {
                            return @intToPtr(ComponentArray(componentField), @ptrToInt(self) + ptr);
                        }

                        ptr += @sizeOf(component.type) * self.capacity;
                    }
                }
                unreachable;
            }
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

            // XXX: remove these eventually...
            available: ?*PageHeader,
            all: *PageHeader,

            // A segmented list for each component.
            comps: Components = .{},
            archetype: Archetype,
            len: SlotIndex,

            fn initEnsureAvailable(page_pool: *ArrayListUnmanaged(*PageHeader), archetype: Archetype) !PageList {
                const newPage = try PageHeader.init(page_pool, archetype);
                return .{
                    .all = newPage,
                    .available = newPage,
                    .archetype = archetype,
                    .len = 0,
                };
            }

            fn ensureAvailable(self: *PageList, page_pool: *ArrayListUnmanaged(*PageHeader)) !void {
                if (self.available == null) {
                    // XXX: self.all.archetype is a bit weird here but works...
                    const newPage = try PageHeader.init(page_pool, self.all.archetype);
                    self.available = newPage;
                    // XXX: just inline it?
                    self.prependAll(newPage);
                }
            }

            // XXX: better api that returns pointers so don't have to recalculate them?
            fn createEntityAssumeCapacity(self: *@This(), slot: *EntitySlot, handle: EntityHandle) void {
                // XXX: could optimize this logic a little since all lists are gonna match eachother, also
                // only really need one size, etc
                // XXX: self.archetype vs making these nullable?
                // slot.entity_pointer.index.index_in_page = self.len;
                // slot.entity_pointer.index.page = self; // ...
                inline for (@typeInfo(Entity).Struct.fields, 0..) |field, i| {
                    if (self.archetype.isSet(i)) {
                        // XXX: don't use page allocator lol, handle failure
                        _ = @field(self.comps, field.name).addOne(std.heap.page_allocator) catch unreachable;
                    }
                }
                // XXX: can't overflow because fails earlier right?
                self.len += 1;
                // XXX: create available if needed here?
                slot.entity_pointer.index.page = self.available.?;
                slot.entity_pointer.page_list = self;
                slot.entity_pointer.index.index_in_page = slot.entity_pointer.index.page.createEntityAssumeCapacity(handle);
                if (slot.entity_pointer.index.page.len == slot.entity_pointer.index.page.capacity) {
                    self.popFrontAvailable();
                }
            }

            fn removeEntity(self: *PageList, index: EntityIndex) void {
                _ = self; // ...
                index.page.removeEntity(index.index_in_page);
            }

            fn popFrontAvailable(self: *@This()) void {
                self.available = self.available.?.next_available;
            }

            fn prependAvailable(self: *@This(), page: *PageHeader) void {
                page.next_available = self.available;
                self.available = page;
            }

            fn prependAll(self: *@This(), page: *PageHeader) void {
                page.next = self.all;
                self.all = page;
            }

            fn ComponentType(comptime componentField: Component) type {
                return std.meta.fieldInfo(Entity, componentField).type;
            }

            fn ComponentIterator(comptime componentField: Component) type {
                const Item = ComponentType(componentField);
                return struct {
                    i: usize = 0,
                    page: ?*PageHeader,
                    fn next(self: *@This()) ?*Item {
                        while (self.page != null) {
                            while (self.i < self.page.?.capacity) : (self.i += 1) {
                                if (self.page.?.handleArray()[self.i].index != invalid_entity_index) {
                                    break;
                                }
                            } else {
                                self.i = 0;
                                self.page = self.page.?.next;
                                continue;
                            }

                            const item = &self.page.?.componentArray(componentField)[self.i];
                            self.i += 1;
                            return item;
                        }
                        return null;
                    }
                };
            }

            fn componentIterator(self: *@This(), comptime componentField: Component) ComponentIterator(componentField) {
                return .{ .page = self.all };
            }

            const HandleIterator = struct {
                i: usize = 0,
                page: ?*PageHeader,
                fn next(self: *@This()) ?EntityHandle {
                    while (self.page != null) {
                        while (self.i < self.page.?.capacity) : (self.i += 1) {
                            if (self.page.?.handleArray()[self.i].index != invalid_entity_index) {
                                break;
                            }
                        } else {
                            self.i = 0;
                            self.page = self.page.?.next;
                            continue;
                        }

                        const item = self.page.?.handleArray()[self.i];
                        self.i += 1;
                        return item;
                    }
                    return null;
                }
            };

            fn handleIterator(self: *@This()) HandleIterator {
                return .{ .page = self.all };
            }

            fn getComponent(self: *@This(), index: EntityIndex, comptime componentField: Component) *ComponentType(componentField) {
                _ = self;
                return &index.page.componentArray(componentField)[index.index_in_page];
            }

            fn getHandle(self: *@This(), index: EntityIndex) EntityHandle {
                _ = self;
                return index.index.page.handleArray()[index.index_in_page];
            }

            // fn handleArray(self: *@This()) [*]EntityHandle {
            //     return @intToPtr([*]EntityHandle, @ptrToInt(self) + self.handle_array);
            // }

            // fn ComponentArray(comptime componentField: Component) type {
            //     return [*]std.meta.fieldInfo(Entity, componentField).type;
            // }

            // fn componentArray(self: *PageHeader, comptime componentField: Component) ComponentArray(componentField) {
            //     var ptr: usize = self.component_arrays;
            //     inline for (@typeInfo(Entity).Struct.fields, 0..) |component, i| {
            //         if (self.archetype.isSet(i)) {
            //             if (@intToEnum(Component, i) == componentField) {
            //                 return @intToPtr(ComponentArray(componentField), @ptrToInt(self) + ptr);
            //             }

            //             ptr += @sizeOf(component.type) * self.capacity;
            //         }
            //     }
            //     unreachable;
            // }
        };

        slots: []EntitySlot,
        free_slot_indices: []SlotIndex,
        page_pool: ArrayListUnmanaged(*PageHeader),
        page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList),

        pub fn init(allocator: Allocator) !@This() {
            return .{
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
                .page_pool = page_pool: {
                    var page_pool = try ArrayListUnmanaged(*PageHeader).initCapacity(allocator, max_pages);
                    _ = page_pool.addManyAsArrayAssumeCapacity(max_pages);
                    for (page_pool.items) |*page| {
                        page.* = @ptrCast(*PageHeader, try allocator.alignedAlloc(
                            [page_size]u8,
                            std.mem.page_size,
                            1,
                        ));
                    }
                    page_pool.items.len = 0;
                    break :page_pool page_pool;
                },
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.slots);
            allocator.free(self.free_slot_indices);
            self.page_lists.deinit(allocator);
            self.page_pool.items.len = max_pages;
            for (self.page_pool.items) |page| {
                page.deinit(allocator);
            }
            self.page_pool.deinit(allocator);
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
            const was_full = slot.entity_pointer.index.page.len == slot.entity_pointer.index.page.capacity;
            slot.entity_pointer.page_list.removeEntity(slot.entity_pointer.index);
            if (was_full) {
                const page_list: *PageList = self.page_lists.getPtr(slot.entity_pointer.index.page.archetype).?;
                page_list.prependAvailable(slot.entity_pointer.index.page);
            }

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

            if (entry.found_existing) {
                try entry.value_ptr.*.ensureAvailable(&self.page_pool);
            } else {
                if (self.page_lists.count() >= max_archetypes) {
                    return error.OutOfArchetypes;
                } else if (self.page_lists.count() == max_archetypes / 2) {
                    std.log.warn("archetype map halfway depleted", .{});
                }
                entry.value_ptr.* = try PageList.initEnsureAvailable(&self.page_pool, archetype);
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
                self.slots[entity.index].entity_pointer.index.page.archetype;

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
            page_list.createEntityAssumeCapacity(slot, entity);

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

                // TODO: dup code from Entities(...){...}.remove(...)
                // Delete the old entity
                const was_full = old_entity_pointer.index.page.len == old_entity_pointer.index.page.capacity;
                old_entity_pointer.index.page.removeEntity(old_entity_pointer.index.index_in_page);

                // If the old page didn't have space before but does now, move it to the front of
                // the page list
                if (was_full) {
                    old_entity_pointer.page_list.prependAvailable(old_entity_pointer.index.page);
                }
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
            if (!slot.entity_pointer.index.page.archetype.isSet(@enumToInt(component))) {
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

                const ComponentIterators = entity: {
                    var fields: [@typeInfo(@TypeOf(components)).Struct.fields.len]Type.StructField = undefined;
                    var i = 0;
                    for (components) |component| {
                        const entityFieldEnum: Component = component;
                        const entityField = std.meta.fieldInfo(Entity, entityFieldEnum);
                        const FieldType = PageList.ComponentIterator(entityFieldEnum);
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
                component_iterators: ComponentIterators,
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
                        .component_iterators = undefined,
                        .handle_iterator = undefined,
                    };
                }

                fn setPageList(self: *@This(), page_list: ?*PageList) void {
                    self.page_list = page_list;
                    if (self.page_list) |pl| {
                        self.handle_iterator = pl.handleArray();
                        inline for (@typeInfo(ComponentIterators).Struct.fields) |field| {
                            const entity_field = @intToEnum(Component, std.meta.fieldIndex(Entity, field.name).?);
                            @field(self.component_iterators, field.name) = pl.componentIterator(entity_field);
                        }
                    }
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
                            inline for (@typeInfo(ComponentIterators).Struct.fields) |field| {
                                const entity_field = @intToEnum(Component, std.meta.fieldIndex(Entity, field.name).?);
                                @field(self.component_iterators, field.name) = self.page_list.?.componentIterator(entity_field);
                            }
                        }

                        // Get the next entity in this page list, if it exists
                        if (self.handle_iterator.next()) |handle| {
                            var item: Item = undefined;
                            item.handle = handle;
                            inline for (@typeInfo(Components).Struct.fields) |field| {
                                @field(item.comps, field.name) = @field(self.component_iterators, field.name).next().?;
                            }
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

// Could use a more exhaustive test, this at least makes sure it compiles which was a problem
// at one point!
test "zero-sized-component" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{ .x = struct {} }).init(allocator);
    defer entities.deinit(allocator);

    const a = entities.create(.{ .x = .{} });
    const b = entities.create(.{});

    try std.testing.expect(entities.getComponent(a, .x) != null);
    try std.testing.expect(entities.getComponent(b, .x) == null);
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
    defer entities.deinit(allocator);
    var created = std.ArrayList(EntityHandle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(EntityHandle{ .index = @intCast(SlotIndex, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expectError(error.OutOfEntities, entities.createChecked(.{}));
    const page_pool_size = entities.page_pool.items.len;

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.remove(entity);
    }
    try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // Assert that all pages are empty
    {
        var page_lists = entities.page_lists.iterator();
        while (page_lists.next()) |page_list| {
            var page: ?*@TypeOf(entities).PageHeader = page_list.value_ptr.all;
            while (page) |p| {
                try std.testing.expect(p.len == 0);
                page = p.next;
            }
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
    try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

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

test "free list" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit(allocator);

    const entity_0_0 = entities.create(.{});
    const entity_1_0 = entities.create(.{});
    const entity_2_0 = entities.create(.{});
    const entity_3_0 = entities.create(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    entities.remove(entity_1_0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].entity_pointer.index.index_in_page, 3);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    entities.remove(entity_3_0);

    const entity_3_1 = entities.create(.{});
    const entity_1_1 = entities.create(.{});
    const entity_4_0 = entities.create(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].entity_pointer.index.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].entity_pointer.index.index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_3_1.index].entity_pointer.index.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_1.index].entity_pointer.index.index_in_page, 3);
    try std.testing.expectEqual(entities.slots[entity_4_0.index].entity_pointer.index.index_in_page, 4);

    try std.testing.expectEqual(EntityHandle{ .index = 0, .generation = 0 }, entity_0_0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    try std.testing.expectEqual(EntityHandle{ .index = 2, .generation = 0 }, entity_2_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 1 }, entity_3_1);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 1 }, entity_1_1);
    try std.testing.expectEqual(EntityHandle{ .index = 4, .generation = 0 }, entity_4_0);
}

test "safety" {
    var allocator = std.heap.page_allocator;
    var entities = try Entities(.{}).init(allocator);
    defer entities.deinit(allocator);

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
    defer entities.deinit(allocator);

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
    defer entities.deinit(allocator);

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
    defer entities.deinit(allocator);

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
