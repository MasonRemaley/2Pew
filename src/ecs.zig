const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Type = std.builtin.Type;

const SlotIndex = u32;
const EntityGeneration = switch (builtin.mode) {
    .Debug, .ReleaseSafe => u32,
    .ReleaseSmall, .ReleaseFast => u0,
};

pub const max_entities: SlotIndex = 1000000;
const invalid_entity_index = std.math.maxInt(SlotIndex);

pub const EntityHandle = struct {
    index: SlotIndex,
    generation: EntityGeneration,
};

pub fn Entities(comptime componentTypes: anytype) type {
    return struct {
        // `Archetype` is a bit set with a bit for each component type.
        const Archetype: type = std.bit_set.IntegerBitSet(std.meta.fields(Entity).len);

        // `Entity` has a field for every possible component type. This is for convenience, it is
        // not used at runtime. Fields are sorted from greatest to least alignment, see `Page` for
        // rational.
        const Entity = entity: {
            var fields: [std.meta.fields(@TypeOf(componentTypes)).len]Type.StructField = undefined;
            inline for (std.meta.fields(@TypeOf(componentTypes)), 0..) |registered, i| {
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

        // Each entity handle points to a slot which in turn points to the actual entity data.
        // This indirection allows the actual data to move without invalidating the handle.
        const EntitySlot = struct {
            generation: EntityGeneration,
            page: *Page,
            index_in_page: u16,
        };

        // A page contains entities of a single archetype.
        const Page = opaque {
            const Header = struct {
                next: ?*Page,
                prev: ?*Page,
                archetype: Archetype,
                len: u16,
                capacity: u16,
                component_arrays: u16,
                handle_array: u16,
            };

            const BackingType = [std.mem.page_size]u8;

            fn init(allocator: Allocator, archetype: Archetype) !*Page {
                var ptr: u16 = 0;

                // Store the header, no alignment necessary since we start out page aligned
                ptr += @sizeOf(Header);

                // Store the handle array
                comptime assert(@alignOf(Header) >= @alignOf(EntityHandle));
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
                const conservative_capacity = (std.mem.page_size - ptr - padding_conservative) / entity_size;

                assert(conservative_capacity > 0);

                ptr += @sizeOf(EntityHandle) * conservative_capacity;

                // Store the component arrays
                ptr = std.mem.alignForwardGeneric(u16, ptr, max_component_alignment);
                const component_arrays = ptr;

                var page = @ptrCast(*Page, try allocator.create(BackingType));
                page.header().* = .{
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

            fn deinit(self: *Page, allocator: Allocator) void {
                allocator.destroy(self.data());
            }

            fn data(self: *Page) *[std.mem.page_size]u8 {
                return @ptrCast(*[std.mem.page_size]u8, self);
            }

            fn header(self: *Page) *Header {
                return @ptrCast(*Header, @alignCast(@alignOf(Header), self.data()));
            }

            fn create(self: *@This(), handle: EntityHandle) u16 {
                var handles = self.handleArray();
                for (0..self.header().capacity) |i| {
                    if (handles[i].index == invalid_entity_index) {
                        handles[i] = handle;
                        self.header().len += 1;
                        return @intCast(u16, i);
                    }
                }
                // TODO: restructure so this assertions is checked at the beginning of this call again by having it return null?
                unreachable;
            }

            fn removeEntity(self: *Page, index: usize) void {
                self.header().len -= 1;
                self.handleArray()[index].index = invalid_entity_index;
            }

            fn handleArray(self: *@This()) [*]EntityHandle {
                return @ptrCast([*]EntityHandle, @alignCast(@alignOf(EntityHandle), &self.data()[self.header().handle_array]));
            }

            fn componentArray(self: *Page, comptime componentField: FieldEnum(Entity)) [*]std.meta.fieldInfo(Entity, componentField).type {
                var ptr: usize = self.header().component_arrays;
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (self.header().archetype.isSet(i)) {
                        if (@intToEnum(FieldEnum(Entity), i) == componentField) {
                            return @ptrCast([*]component.type, @alignCast(@alignOf(component.type), &self.data()[ptr]));
                        }

                        ptr += @sizeOf(component.type) * self.header().capacity;
                    }
                }
                unreachable;
            }
        };

        // A linked list of pages of a single archetype. Pages with available space are kept sorted
        // to the front of the list.
        const PageList = struct {
            head: ?*Page = null,
            tail: ?*Page = null,

            fn moveToHead(self: *@This(), page: *Page) void {
                if (self.head != page) {
                    self.remove(page);
                    self.prepend(page);
                }
            }

            fn moveToTail(self: *@This(), page: *Page) void {
                if (self.tail != page) {
                    self.remove(page);
                    self.append(page);
                }
            }

            fn remove(self: *@This(), page: *Page) void {
                // Update head/tail
                if (self.head == page)
                    self.head = page.header().next;
                if (self.tail == page)
                    self.tail = page.header().prev;

                // Update the previous node
                if (page.header().prev) |prev| {
                    prev.header().next = page.header().next;
                }

                // Update the next node
                if (page.header().next) |next| {
                    next.header().prev = page.header().prev;
                }

                // Invaidate prev/next
                page.header().prev = undefined;
                page.header().next = undefined;
            }

            fn prepend(self: *@This(), page: *Page) void {
                // Update prev/next
                page.header().prev = null;
                page.header().next = self.head;

                // Update the current head's prev
                if (self.head) |head| {
                    head.header().prev = page;
                }

                // Update head and tail
                self.head = page;
                if (self.tail == null) self.tail = page;
            }

            fn append(self: *@This(), page: *Page) void {
                // Update prev/next
                page.header().prev = self.tail;
                page.header().next = null;

                // Update the current tail's next
                if (self.tail) |tail| {
                    tail.header().next = page;
                }

                // Update head and tail
                self.tail = page;
                if (self.head == null) self.head = page;
            }
        };

        slots: []EntitySlot,
        free_slot_indices: []SlotIndex,
        pages: ArrayListUnmanaged(*Page),
        page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList),
        // XXX: eventually don't store this, once we don't allocate after init!
        allocator: Allocator,

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
                .page_lists = .{},
                .pages = .{},
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.slots);
            self.allocator.free(self.free_slot_indices);
            self.page_lists.deinit(self.allocator);
            for (self.pages.items) |page| {
                page.deinit(self.allocator);
            }
            self.pages.deinit(self.allocator);
        }

        fn createChecked(self: *@This(), entity: anytype) ?EntityHandle {
            const archetype = comptime archetype: {
                var archetype = Archetype.initEmpty();
                inline for (std.meta.fieldNames(@TypeOf(entity))) |fieldName| {
                    archetype.set(std.meta.fieldIndex(Entity, fieldName).?);
                }
                break :archetype archetype;
            };

            // Find a free index for the entity
            const index = index: {
                if (self.free_slot_indices.len > 0) {
                    // Pop an id from the free list
                    const top = self.free_slot_indices.len - 1;
                    const index = self.free_slot_indices[top];
                    self.free_slot_indices.len = top;
                    break :index index;
                } else if (self.slots.len < max_entities) {
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
                    return null;
                }
            };

            // TODO: don't ignore errors in this function, and remember to use errdefer where appropriate
            // Get the page list for this archetype
            const page_list: *PageList = page: {
                // Find or allocate a page for this entity
                const entry = self.page_lists.getOrPut(
                    self.allocator,
                    archetype,
                ) catch unreachable;
                if (!entry.found_existing) {
                    const newPage = Page.init(self.allocator, archetype) catch unreachable;
                    self.pages.append(self.allocator, newPage) catch unreachable;
                    entry.value_ptr.* = PageList{};
                    entry.value_ptr.*.prepend(newPage);
                }
                break :page entry.value_ptr;
            };

            // TODO: only possiblly necessary if didn't juts create one
            // If the head does not have space, create a new head that has space
            if (page_list.head.?.header().len == page_list.head.?.header().capacity) {
                const newPage = Page.init(self.allocator, archetype) catch unreachable;
                self.pages.append(self.allocator, newPage) catch unreachable;
                page_list.prepend(newPage);
            }
            const page = page_list.head.?;

            // Create a new entity
            const handle = EntityHandle{
                .index = index,
                .generation = self.slots[index].generation,
            };
            const slot = &self.slots[index];
            slot.page = page;
            slot.index_in_page = page.create(handle);

            // If the page is now full, move it to the end of the page list
            if (page.header().len == page.header().capacity) {
                page_list.moveToTail(page);
            }

            // Initialize the new entity
            inline for (std.meta.fields(@TypeOf(entity))) |f| {
                const field = @intToEnum(FieldEnum(Entity), std.meta.fieldIndex(Entity, f.name).?);
                page.componentArray(field)[slot.index_in_page] = @field(entity, f.name);
            }

            // Return the handle to the entity
            return handle;
        }

        pub fn create(self: *@This(), entity: anytype) EntityHandle {
            return self.createChecked(entity).?;
        }

        fn removeEntityChecked(self: *@This(), entity: EntityHandle) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }
            if (self.free_slot_indices.len == max_entities) {
                return error.FreelistFull;
            }

            // Unset the exists bit, and reorder the page
            const slot = &self.slots[entity.index];
            const page = slot.page;
            const was_full = page.header().len == page.header().capacity;
            page.removeEntity(slot.index_in_page);

            // If this page didn't have space before but does now, move it to the front of the page
            // list
            if (was_full) {
                const page_list: *PageList = self.page_lists.getPtr(page.header().archetype).?;
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

        pub fn removeEntity(self: *@This(), entity: EntityHandle) void {
            self.removeEntityChecked(entity) catch unreachable;
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
            if (!slot.page.header().archetype.isSet(@enumToInt(component))) {
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
                    inline for (components) |component| {
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
                    inline for (components) |component| {
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
                page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList).Iterator,
                page_list: ?*Page,
                index_in_page: u16,
                component_arrays: ComponentArrays,
                handle_array: [*]EntityHandle,

                fn init(entities: *Entities(componentTypes)) @This() {
                    return .{
                        // TODO: replace with getter if possible
                        .archetype = comptime archetype: {
                            var archetype = Archetype.initEmpty();
                            inline for (components) |field| {
                                const entityField: FieldEnum(Entity) = field;
                                archetype.set(@enumToInt(entityField));
                            }
                            break :archetype archetype;
                        },
                        .page_lists = entities.page_lists.iterator(),
                        .page_list = null,
                        .index_in_page = 0,
                        .component_arrays = undefined,
                        .handle_array = undefined,
                    };
                }

                fn setPageList(self: *@This(), page_list: ?*Page) void {
                    self.page_list = page_list;
                    self.index_in_page = 0;
                    if (page_list) |pl| {
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
                        if (self.page_list == null) {
                            const nextPageList = while (self.page_lists.next()) |page| {
                                if (page.key_ptr.supersetOf(self.archetype)) {
                                    break page.value_ptr.head;
                                }
                            } else return null;
                            self.setPageList(nextPageList);
                        }

                        // Find the next entity in this archetype page
                        while (self.index_in_page < self.page_list.?.header().capacity) : (self.index_in_page += 1) {
                            if (self.handle_array[self.index_in_page].index != invalid_entity_index) {
                                break;
                            }
                        } else {
                            // If we didn't find anything, advance to the next page in this archetype
                            // page list
                            self.setPageList(self.page_list.?.header().next);
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
        assert(std.math.maxInt(IndexInPage) > std.mem.page_size);
    }

    var entities = try Entities(.{}).init(std.heap.page_allocator);
    defer entities.deinit();
    var created = std.ArrayList(EntityHandle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.create(.{});
        try std.testing.expectEqual(EntityHandle{ .index = @intCast(SlotIndex, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expect(entities.createChecked(.{}) == null);
    const page_pool_size = entities.pages.items.len;

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.removeEntity(entity);
    }
    try std.testing.expectEqual(page_pool_size, entities.pages.items.len);

    // Assert that all pages are empty
    {
        var page_lists = entities.page_lists.iterator();
        while (page_lists.next()) |page_list| {
            var page: ?*@TypeOf(entities).Page = page_list.value_ptr.head;
            while (page) |p| {
                try std.testing.expect(p.header().len == 0);
                page = p.header().next;
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
    try std.testing.expect(entities.createChecked(.{}) == null);
    try std.testing.expectEqual(page_pool_size, entities.pages.items.len);

    // Wrap a generation counter
    {
        const entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
        entities.slots[entity.index].generation = entity.generation;
        entities.removeEntity(entity);
        try std.testing.expectEqual(
            EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
            entities.create(.{}),
        );
    }
}

test "free list" {
    var entities = try Entities(.{}).init(std.heap.page_allocator);
    defer entities.deinit();

    const entity_0_0 = entities.create(.{});
    const entity_1_0 = entities.create(.{});
    const entity_2_0 = entities.create(.{});
    const entity_3_0 = entities.create(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].index_in_page, 0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    entities.removeEntity(entity_1_0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].index_in_page, 3);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    entities.removeEntity(entity_3_0);

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
    var entities = try Entities(.{}).init(std.heap.page_allocator);
    defer entities.deinit();

    const entity = entities.create(.{});
    entities.removeEntity(entity);
    try std.testing.expectError(error.BadGeneration, entities.removeEntityChecked(entity));
    try std.testing.expectError(error.BadIndex, entities.removeEntityChecked(EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}

test "random data" {
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(std.heap.page_allocator);
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

    for (0..1000) |_| {
        switch (rnd.random().enumValue(enum { create, modify, destroy })) {
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
            .destroy => {
                for (0..rnd.random().uintLessThan(usize, 3)) |_| {
                    if (truth.items.len > 0) {
                        const index = rnd.random().uintLessThan(usize, truth.items.len);
                        const removed = truth.orderedRemove(index);
                        entities.removeEntity(removed.handle);
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
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init(std.heap.page_allocator);
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
