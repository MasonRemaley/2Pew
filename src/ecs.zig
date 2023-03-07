const std = @import("std");
const builtin = @import("builtin");

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
// TODO: can now tweak for perf. note that lower numbers are better
// tests though, may wanna make configurable for that reason.
const page_size = 4096;

// TODO: set reasonable values for these
const max_pages = max_entities / 32;
const max_archetypes = 40000;

pub const EntityHandle = struct {
    index: SlotIndex,
    generation: EntityGeneration,
};

// TODO: really it should just be called components but then can't use that anywhere else...
pub fn Entities(comptime componentTypes: anytype) type {
    return struct {
        // `Archetype` is a bit set with a bit for each component type.
        const Archetype: type = std.bit_set.IntegerBitSet(std.meta.fields(Entity).len);

        // TODO: rename to components?
        // `Entity` has a field for every possible component type. This is for convenience, it is
        // not used at runtime. Fields are sorted from greatest to least alignment, see `PageHeader` for
        // rational.
        pub const Entity = entity: {
            var fields: [std.meta.fields(@TypeOf(componentTypes)).len]Type.StructField = undefined;
            for (std.meta.fields(@TypeOf(componentTypes)), 0..) |registered, i| {
                fields[i] = Type.StructField{
                    .name = registered.name,
                    .type = @field(componentTypes, registered.name),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(registered.type),
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
            var fields: [std.meta.fields(Entity).len]Type.StructField = undefined;
            for (std.meta.fields(Entity), 0..) |field, i| {
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

        // Each entity handle points to a slot which in turn points to the actual entity data.
        // This indirection allows the actual data to move without invalidating the handle.
        const EntitySlot = struct {
            generation: EntityGeneration,
            page: *PageHeader,
            index_in_page: u16,
        };

        // A page contains entities of a single archetype.
        const PageHeader = struct {
            next: ?*PageHeader,
            prev: ?*PageHeader,
            archetype: Archetype,
            len: u16,
            capacity: u16,
            component_arrays: u16,
            handle_array: u16,

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
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (archetype.isSet(i)) {
                        if (first) {
                            first = false;
                            max_component_alignment = @alignOf(component.type);
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
                    .next = null,
                    .prev = null,
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

            fn createEntity(self: *@This(), handle: EntityHandle) u16 {
                var handles = self.handleArray();
                for (0..self.capacity) |i| {
                    if (handles[i].index == invalid_entity_index) {
                        handles[i] = handle;
                        self.len += 1;
                        return @intCast(u16, i);
                    }
                }
                // TODO: restructure so this assertions is checked at the beginning of this call again by having it return null?
                unreachable;
            }

            fn remove(self: *PageHeader, index: usize) void {
                self.len -= 1;
                self.handleArray()[index].index = invalid_entity_index;
            }

            fn handleArray(self: *@This()) [*]EntityHandle {
                return @intToPtr([*]EntityHandle, @ptrToInt(self) + self.handle_array);
            }

            fn componentArray(self: *PageHeader, comptime componentField: FieldEnum(Entity)) [*]std.meta.fieldInfo(Entity, componentField).type {
                var ptr: usize = self.component_arrays;
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (self.archetype.isSet(i)) {
                        if (@intToEnum(FieldEnum(Entity), i) == componentField) {
                            return @intToPtr([*]std.meta.fieldInfo(Entity, componentField).type, @ptrToInt(self) + ptr);
                        }

                        ptr += @sizeOf(component.type) * self.capacity;
                    }
                }
                unreachable;
            }
        };

        // A linked list of max_pages of a single archetype. Pages with available space are kept sorted
        // to the front of the list.
        const PageList = struct {
            head: ?*PageHeader = null,
            tail: ?*PageHeader = null,

            fn moveToHead(self: *@This(), page: *PageHeader) void {
                if (self.head != page) {
                    self.remove(page);
                    self.prepend(page);
                }
            }

            fn moveToTail(self: *@This(), page: *PageHeader) void {
                if (self.tail != page) {
                    self.remove(page);
                    self.append(page);
                }
            }

            fn remove(self: *@This(), page: *PageHeader) void {
                // Update head/tail
                if (self.head == page)
                    self.head = page.next;
                if (self.tail == page)
                    self.tail = page.prev;

                // Update the previous node
                if (page.prev) |prev| {
                    prev.next = page.next;
                }

                // Update the next node
                if (page.next) |next| {
                    next.prev = page.prev;
                }

                // Invaidate prev/next
                page.prev = undefined;
                page.next = undefined;
            }

            fn prepend(self: *@This(), page: *PageHeader) void {
                // Update prev/next
                page.prev = null;
                page.next = self.head;

                // Update the current head's prev
                if (self.head) |head| {
                    head.prev = page;
                }

                // Update head and tail
                self.head = page;
                if (self.tail == null) self.tail = page;
            }

            fn append(self: *@This(), page: *PageHeader) void {
                // Update prev/next
                page.prev = self.tail;
                page.next = null;

                // Update the current tail's next
                if (self.tail) |tail| {
                    tail.next = page;
                }

                // Update head and tail
                self.tail = page;
                if (self.head == null) self.head = page;
            }
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
                        .page = undefined,
                        .index_in_page = undefined,
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
            const page = slot.page;
            const was_full = page.len == page.capacity;
            page.remove(slot.index_in_page);

            // If this page didn't have space before but does now, move it to the front of the page
            // list
            if (was_full) {
                const page_list: *PageList = self.page_lists.getPtr(page.archetype).?;
                page_list.moveToHead(page);
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
                self.slots[entity.index].page.archetype;

            const components_added = components_added: {
                if (@TypeOf(add_components) == Prefab) {
                    var components_added = Archetype.initEmpty();
                    inline for (comptime std.meta.fieldNames(@TypeOf(add_components))) |fieldName| {
                        if (@field(add_components, fieldName) != null) {
                            components_added.set(std.meta.fieldIndex(Entity, fieldName).?);
                        }
                    }
                    break :components_added components_added;
                } else comptime {
                    var components_added = Archetype.initEmpty();
                    for (std.meta.fieldNames(@TypeOf(add_components))) |fieldName| {
                        components_added.set(std.meta.fieldIndex(Entity, fieldName).?);
                    }
                    break :components_added components_added;
                }
            };

            const components_removed = components_removed: {
                var components_removed = Archetype.initEmpty();
                inline for (remove_components) |removed| {
                    const fieldEnum: FieldEnum(Entity) = removed;
                    components_removed.set(@enumToInt(fieldEnum));
                }
                break :components_removed components_removed;
            };

            const archetype = previous_archetype.unionWith(components_added)
                .differenceWith(components_removed);

            // Get the page list for this archetype
            const page_list: *PageList = page: {
                comptime assert(max_archetypes > 0);
                const entry = self.page_lists.getOrPutAssumeCapacity(archetype);
                if (!entry.found_existing) {
                    if (self.page_lists.count() >= max_archetypes) {
                        return error.OutOfArchetypes;
                    } else if (self.page_lists.count() == max_archetypes / 2) {
                        std.log.warn("archetype map halfway depleted", .{});
                    }
                    const newPage = try PageHeader.init(&self.page_pool, archetype);
                    entry.value_ptr.* = PageList{};
                    entry.value_ptr.*.prepend(newPage);
                }
                break :page entry.value_ptr;
            };

            // TODO: only possiblly necessary if didn't juts create one
            // If the head does not have space, create a new head that has space
            if (page_list.head.?.len == page_list.head.?.capacity) {
                const newPage = try PageHeader.init(&self.page_pool, archetype);
                page_list.prepend(newPage);
            }
            const page = page_list.head.?;

            // Create the new entity
            const slot = &self.slots[entity.index];
            const old_page = slot.page;
            const old_index_in_page = slot.index_in_page;
            slot.page = page;
            slot.index_in_page = page.createEntity(entity);

            // If this entity data is replacing an existing one, copy the original components over
            if (!create_entity) {
                // Copy the old components
                const copy = previous_archetype.intersectWith(archetype)
                    .differenceWith(components_added);
                inline for (0..std.meta.fields(Entity).len) |i| {
                    if (copy.isSet(i)) {
                        const field = @intToEnum(FieldEnum(Entity), i);
                        page.componentArray(field)[slot.index_in_page] = old_page.componentArray(field)[old_index_in_page];
                    }
                }

                // TODO: dup code from Entities(...){...}.remove(...)
                // Delete the old entity
                const was_full = page.len == page.capacity;
                old_page.remove(old_index_in_page);

                // If the old page didn't have space before but does now, move it to the front of
                // the page list
                if (was_full) {
                    const old_page_list: *PageList = self.page_lists.getPtr(slot.page.archetype).?;
                    old_page_list.moveToHead(page);
                }
            }

            // If the new page is now full, move it to the end of the page list
            if (page.len == page.capacity) {
                page_list.moveToTail(page);
            }

            // Initialize the new entity
            inline for (std.meta.fields(@TypeOf(add_components))) |f| {
                const field = @intToEnum(FieldEnum(Entity), std.meta.fieldIndex(Entity, f.name).?);
                if (@TypeOf(add_components) == Prefab) {
                    if (@field(add_components, f.name)) |component| {
                        page.componentArray(field)[slot.index_in_page] = component;
                    }
                } else {
                    page.componentArray(field)[slot.index_in_page] = @field(add_components, f.name);
                }
            }

            // Return the handle to the entity
            return entity;
        }

        // TODO: check assertions
        fn getComponentChecked(self: *@This(), entity: EntityHandle, comptime component: FieldEnum(Entity)) !?*std.meta.fieldInfo(Entity, component).type {
            // TODO: dup code
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            const slot = self.slots[entity.index];
            if (!slot.page.archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return &slot.page.componentArray(component)[slot.index_in_page];
        }

        pub fn getComponent(self: *@This(), entity: EntityHandle, comptime component: FieldEnum(Entity)) ?*std.meta.fieldInfo(Entity, component).type {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn Iterator(comptime components: anytype) type {
            return struct {
                const Components = entity: {
                    var fields: [std.meta.fields(@TypeOf(components)).len]Type.StructField = undefined;
                    var i = 0;
                    for (components) |component| {
                        const entityFieldEnum: FieldEnum(Entity) = component;
                        const entityField = std.meta.fields(Entity)[@enumToInt(entityFieldEnum)];
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

                // TODO: mostly dup of above just made * [*]? can we clean this up?
                const ComponentArrays = entity: {
                    var fields: [std.meta.fields(@TypeOf(components)).len]Type.StructField = undefined;
                    var i = 0;
                    for (components) |component| {
                        const entityFieldEnum: FieldEnum(Entity) = component;
                        const entityField = std.meta.fields(Entity)[@enumToInt(entityFieldEnum)];
                        const FieldType = [*]entityField.type;
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
                page_lists: *const AutoArrayHashMapUnmanaged(Archetype, PageList),
                page_lists_i: usize,
                page: ?*PageHeader,
                index_in_page: u16,
                component_arrays: ComponentArrays,
                handle_array: [*]EntityHandle,

                fn init(entities: *Entities(componentTypes)) @This() {
                    return .{
                        // TODO: replace with getter if possible
                        .archetype = comptime archetype: {
                            var archetype = Archetype.initEmpty();
                            for (components) |field| {
                                const entityField: FieldEnum(Entity) = field;
                                archetype.set(@enumToInt(entityField));
                            }
                            break :archetype archetype;
                        },
                        .page_lists = &entities.page_lists,
                        .page_lists_i = 0,
                        .page = null,
                        .index_in_page = 0,
                        .component_arrays = undefined,
                        .handle_array = undefined,
                    };
                }

                fn setPage(self: *@This(), page: ?*PageHeader) void {
                    self.page = page;
                    self.index_in_page = 0;
                    if (page) |pl| {
                        self.handle_array = pl.handleArray();
                        inline for (std.meta.fields(ComponentArrays)) |field| {
                            const entity_field = @intToEnum(FieldEnum(Entity), std.meta.fieldIndex(Entity, field.name).?);
                            @field(self.component_arrays, field.name) = pl.componentArray(entity_field);
                        }
                    }
                }

                pub fn next(self: *@This()) ?Item {
                    while (true) {
                        // If we don't have a page list, find the next compatible archetype's page
                        // list
                        if (self.page == null) {
                            const nextPageList = while (self.page_lists_i < self.page_lists.count()) {
                                const i = self.page_lists_i;
                                self.page_lists_i += 1;
                                if (self.page_lists.keys()[i].supersetOf(self.archetype)) {
                                    break self.page_lists.values()[i].head;
                                }
                            } else return null;
                            self.setPage(nextPageList);
                        }

                        // Find the next entity in this archetype page
                        while (self.index_in_page < self.page.?.capacity) : (self.index_in_page += 1) {
                            if (self.handle_array[self.index_in_page].index != invalid_entity_index) {
                                break;
                            }
                        } else {
                            // If we didn't find anything, advance to the next page in this archetype
                            // page list
                            self.setPage(self.page.?.next);
                            continue;
                        }

                        // If it exists, return it
                        var item: Item = undefined;
                        item.handle = self.handle_array[self.index_in_page];
                        inline for (std.meta.fields(Components)) |field| {
                            @field(item.comps, field.name) = &@field(self.component_arrays, field.name)[self.index_in_page];
                        }
                        self.index_in_page += 1;
                        return item;
                    }
                }
            };
        }

        pub fn iterator(self: *@This(), components: anytype) Iterator(components) {
            return Iterator(components).init(self);
        }
    };
}

test "limits" {
    // The max entity id should be considered invalid
    assert(max_entities < std.math.maxInt(SlotIndex));

    // Make sure our page index type is big enough
    {
        // TODO: break this out into constant?
        const EntitySlot = Entities(.{}).EntitySlot;
        const IndexInPage = std.meta.fields(EntitySlot)[std.meta.fieldIndex(EntitySlot, "index_in_page").?].type;
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
            var page: ?*@TypeOf(entities).PageHeader = page_list.value_ptr.head;
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

    try std.testing.expectEqual(entities.slots[entity_0_0.index].index_in_page, 0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    entities.remove(entity_1_0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].index_in_page, 3);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    entities.remove(entity_3_0);

    const entity_3_1 = entities.create(.{});
    const entity_1_1 = entities.create(.{});
    const entity_4_0 = entities.create(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_3_1.index].index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_1.index].index_in_page, 3);
    try std.testing.expectEqual(entities.slots[entity_4_0.index].index_in_page, 4);

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

    for (0..2000) |_| {
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
