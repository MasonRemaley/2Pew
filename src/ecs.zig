const std = @import("std");
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const builtin = @import("builtin");

const max_entities: EntityIndex = 1000000;

const EntityIndex = u32;
const invalid_entity_index = std.math.maxInt(EntityIndex);

const track_generation = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseSmall, .ReleaseFast => false,
};

const EntityGeneration = if (track_generation) u32 else u0;

// TODO: pack this tightly
pub const EntityHandle = struct {
    generation: EntityGeneration,
    index: EntityIndex,
};

pub fn Entities(comptime componentTypes: anytype) type {
    return struct {
        // `Entity` has a field for every possible component type. This is for convenience, it is
        // not used at runtime. Fields are sorted from greatest to least alignment, see `Page` for
        // rational.
        const Entity = entity: {
            var fields: [std.meta.fields(@TypeOf(componentTypes)).len]std.builtin.Type.StructField = undefined;
            inline for (std.meta.fields(@TypeOf(componentTypes)), 0..) |registered, i| {
                fields[i] = std.builtin.Type.StructField{
                    .name = registered.name,
                    .type = @field(componentTypes, registered.name),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(registered.type),
                };
            }
            const CompareEntityFields = struct {
                fn cmp(_: void, comptime lhs: std.builtin.Type.StructField, comptime rhs: std.builtin.Type.StructField) bool {
                    return @alignOf(lhs.type) > @alignOf(rhs.type);
                }
            };
            std.sort.sort(std.builtin.Type.StructField, &fields, {}, CompareEntityFields.cmp);
            break :entity @Type(std.builtin.Type{
                .Struct = std.builtin.Type.Struct{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        };

        // `Archetype` has a bit for each component type.
        const Archetype: type = std.bit_set.IntegerBitSet(std.meta.fields(Entity).len);

        // TODO: pack this tightly, maybe use index instead of ptr for page
        const EntityLocation = struct {
            page: *Page,
            index_in_page: u32,
        };
        const EntitySlot = struct {
            generation: EntityGeneration,
            location: EntityLocation,
        };

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

        // TODO: pack this tightly, cache right data
        const PageHeader = struct {
            next: ?*Page,
            prev: ?*Page,
            archetype: Archetype,
            capacity: EntityIndex,
            entity_size: usize,
            len: usize,
            component_arrays: usize,
            handle_array: usize,
        };

        // TODO: make sure exactly one page size, make sure ordered correctly, may need to store everything
        // in byte array
        // TODO: comptime make sure capacity large enough even if all components used at once?
        // TODO: explain alignment sort here
        // TODO: instead of getting individual components, get component arrays?
        const Page = opaque {
            const BackingType = [std.mem.page_size]u8;

            // TODO: This math is cheap enough, but if adding a page to an existing list technically
            // could just copy it.
            fn init(archetype: Archetype) !*Page {
                var ptr: usize = 0;

                // Store the header, no alignment necessary since we start out page aligned
                ptr += @sizeOf(PageHeader);

                // Store the handle array
                // XXX: eventually will be alignof handle
                ptr = std.mem.alignForward(ptr, @alignOf(EntityHandle));
                const handle_array = ptr;

                // Calculate how many entities can actually be stored
                var components_size: usize = 0;
                var max_component_alignment: usize = 1;
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

                // TODO: add one if possible so no longer conservative?
                const padding_conservative = max_component_alignment - 1;
                const entity_size = @sizeOf(EntityHandle) + components_size;
                const conservative_capacity = @intCast(EntityIndex, (std.mem.page_size - ptr - padding_conservative) / entity_size);

                ptr += @sizeOf(EntityHandle) * conservative_capacity;

                // Store the component arrays
                ptr = std.mem.alignForward(ptr, max_component_alignment);
                const component_arrays = ptr;

                var page = @ptrCast(*Page, try std.heap.page_allocator.create(BackingType));
                page.header().* = .{
                    .next = null,
                    .prev = null,
                    .archetype = archetype,
                    .capacity = conservative_capacity,
                    .entity_size = entity_size,
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

            fn deinit(self: *Page) void {
                std.heap.page_allocator.destroy(self.data());
            }

            fn data(self: *Page) *[std.mem.page_size]u8 {
                return @ptrCast(*[std.mem.page_size]u8, self);
            }

            // TODO: may make more sense to put the header + any padding at the start
            fn header(self: *Page) *PageHeader {
                return @ptrCast(*PageHeader, @alignCast(@alignOf(PageHeader), self.data()));
            }

            // TODO: should probably have an internal free list to accelerate this
            // TODO: make sure this cast is always safe at comptime?
            // TODO: make assertions in get component that it exists first
            fn createEntity(self: *@This(), handle: EntityHandle) EntityIndex {
                // XXX: can i use a normal for loop on this, but cap it with a range or slice?
                var handles = self.handleArray();
                for (0..self.header().capacity) |i| {
                    if (handles[i].index == invalid_entity_index) {
                        handles[i] = handle;
                        self.header().len += 1;
                        return @intCast(EntityIndex, i);
                    }
                }
                // TODO: restructure so this assertions is checked at the beginning of this call again by having it return null?
                unreachable;
            }

            fn handleArray(self: *@This()) [*]EntityHandle {
                return @ptrCast([*]EntityHandle, @alignCast(@alignOf(EntityHandle), &self.data()[self.header().handle_array]));
            }

            // TODO: i was previously thinking i needed a reference to the handle here--is that correct or no? maybe
            // required for the iterator?
            fn removeEntity(self: *Page, index: usize) void {
                self.header().len -= 1;
                self.handleArray()[index].index = invalid_entity_index;
            }

            // TODO: usize as index?
            // TODO: faster method when setting multiple components at once?
            fn componentArray(self: *Page, comptime componentField: std.meta.FieldEnum(Entity)) [*]std.meta.fieldInfo(Entity, componentField).type {
                var ptr: usize = self.header().component_arrays;
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (self.header().archetype.isSet(i)) {
                        if (@intToEnum(std.meta.FieldEnum(Entity), i) == componentField) {
                            return @ptrCast([*]component.type, @alignCast(@alignOf(component.type), &self.data()[ptr]));
                        }

                        ptr += @sizeOf(component.type) * self.header().capacity;
                    }
                }
                unreachable;
            }
        };

        slots: []EntitySlot,
        free: []EntityIndex,
        // TODO: better way to allocate this..? should we even be using the hashmap here?
        page_pool: ArrayListUnmanaged(*Page),
        // Ordered so that pages with space available are always at the front.
        page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList),

        fn init() !@This() {
            return .{
                .slots = entities: {
                    // TODO: if we're gonna use a page allocator for array lists...always set to multiples of a page
                    var entities = try std.heap.page_allocator.alloc(EntitySlot, max_entities);
                    entities.len = 0;
                    break :entities entities;
                },
                .free = free: {
                    var free = try std.heap.page_allocator.alloc(EntityIndex, max_entities);
                    free.len = 0;
                    break :free free;
                },
                .page_lists = .{},
                // TODO: init capacity? not actually really pooling these yet just accumulating them
                .page_pool = .{},
            };
        }

        fn deinit(self: *@This()) void {
            std.heap.page_allocator.free(self.slots);
            std.heap.page_allocator.free(self.free);
            self.page_lists.deinit(std.heap.page_allocator);
            for (self.page_pool.items) |page| {
                page.deinit();
            }
            self.page_pool.deinit(std.heap.page_allocator);
        }

        fn createEntityChecked(self: *@This(), entity: anytype) ?EntityHandle {
            const archetype = comptime archetype: {
                var archetype = Archetype.initEmpty();
                inline for (std.meta.fieldNames(@TypeOf(entity))) |fieldName| {
                    archetype.set(std.meta.fieldIndex(Entity, fieldName).?);
                }
                break :archetype archetype;
            };

            // Find a free index for the entity
            const index = index: {
                if (self.free.len > 0) {
                    // Pop an id from the free list
                    const top = self.free.len - 1;
                    const index = self.free[top];
                    self.free.len = top;
                    break :index index;
                } else if (self.slots.len < max_entities) {
                    // Add a new entity to the end of the list
                    const top = self.slots.len;
                    self.slots.len += 1;
                    self.slots[top] = .{
                        .generation = 0,
                        // TODO: ...
                        .location = undefined,
                    };
                    break :index @intCast(EntityIndex, top);
                } else {
                    return null;
                }
            };

            // TODO: don't ignore errors in this function...just trying things out. add errdefer where needed
            // Get the page list for this archetype
            const page_list: *PageList = page: {
                // TODO: allocate pages up front in pool when possible
                // Find or allocate a page for this entity
                const entry = self.page_lists.getOrPut(
                    std.heap.page_allocator,
                    archetype,
                ) catch unreachable;
                if (!entry.found_existing) {
                    const newPage = Page.init(archetype) catch unreachable;
                    self.page_pool.append(std.heap.page_allocator, newPage) catch unreachable;
                    entry.value_ptr.* = PageList{};
                    entry.value_ptr.*.prepend(newPage);
                }
                break :page entry.value_ptr;
            };

            // TODO: only possiblly necessary if didn't juts create one..
            // If the head does not have space, create a new head that has space
            if (page_list.head.?.header().len == page_list.head.?.header().capacity) {
                const newPage = Page.init(archetype) catch unreachable;
                self.page_pool.append(std.heap.page_allocator, newPage) catch unreachable;
                page_list.prepend(newPage);
            }
            const page = page_list.head.?;

            // Create a new entity
            const handle = EntityHandle{
                .index = index,
                .generation = self.slots[index].generation,
            };
            self.slots[index].location = EntityLocation{
                .page = page,
                .index_in_page = page.createEntity(handle),
            };

            // If the page is now full, move it to the end of the page list
            if (page.header().len == page.header().capacity) {
                page_list.moveToTail(page);
            }

            // Initialize the new entity
            // TODO: loop fastest or can cache math?
            inline for (std.meta.fields(@TypeOf(entity))) |f| {
                page.componentArray(
                    @intToEnum(std.meta.FieldEnum(Entity), std.meta.fieldIndex(Entity, f.name).?),
                )[self.slots[index].location.index_in_page] = @field(entity, f.name);
            }

            // Return the handle to the entity
            return handle;
        }

        pub fn createEntity(self: *@This(), entity: anytype) EntityHandle {
            return self.createEntityChecked(entity).?;
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
            if (self.free.len == max_entities) {
                return error.FreelistFull;
            }

            // TODO: dup index?
            // TODO: have a setter and assert not already set? or just add assert?
            // Unset the exists bit, and reorder the page
            const page = self.slots[entity.index].location.page;
            const was_full = page.header().len == page.header().capacity;
            page.removeEntity(self.slots[entity.index].location.index_in_page);
            const page_list: *PageList = self.page_lists.getPtr(page.header().archetype).?;

            // If this page didn't have space before but does now, move it to the front of the page
            // list
            if (was_full) {
                page_list.moveToHead(page);
            }

            // Increment this entity slot's generation so future uses will fail
            self.slots[entity.index].generation +%= 1;

            // Add the entity to the free list
            const top = self.free.len;
            self.free.len += 1;
            self.free[top] = entity.index;
        }

        pub fn removeEntity(self: *@This(), entity: EntityHandle) void {
            self.removeEntityChecked(entity) catch unreachable;
        }

        // TODO: allow getting multiple at once?
        // TODO: check assertions
        fn getComponentChecked(self: *@This(), entity: EntityHandle, comptime component: std.meta.FieldEnum(Entity)) !?*std.meta.fieldInfo(Entity, component).type {
            // TODO: dup code, dup index
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.slots.len) {
                return error.BadIndex;
            }
            if (self.slots[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            const slot = self.slots[entity.index];
            if (!slot.location.page.header().archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return &slot.location.page.componentArray(component)[slot.location.index_in_page];
        }

        pub fn getComponent(self: *@This(), entity: EntityHandle, comptime component: std.meta.FieldEnum(Entity)) ?*std.meta.fieldInfo(Entity, component).type {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        pub fn Iterator(comptime components: anytype) type {
            return struct {
                const Components = entity: {
                    var fields: [std.meta.fields(@TypeOf(components)).len]std.builtin.Type.StructField = undefined;
                    var i = 0;
                    // XXX: wait inline for on tuples? indexing?
                    // XXX: i forgot (Entity) ont his, and it thought of it as the type of the function..??
                    inline for (components) |component| {
                        const entityFieldEnum: std.meta.FieldEnum(Entity) = component;
                        const entityField = std.meta.fields(Entity)[@enumToInt(entityFieldEnum)];
                        const FieldType = *entityField.type;
                        fields[i] = std.builtin.Type.StructField{
                            .name = entityField.name,
                            .type = FieldType,
                            .default_value = null,
                            .is_comptime = false,
                            .alignment = @alignOf(FieldType),
                        };
                        i += 1;
                    }
                    break :entity @Type(std.builtin.Type{
                        .Struct = std.builtin.Type.Struct{
                            .layout = .Auto,
                            .backing_integer = null,
                            .fields = &fields,
                            .decls = &[_]std.builtin.Type.Declaration{},
                            .is_tuple = false,
                        },
                    });
                };

                const Item = struct {
                    handle: EntityHandle,
                    comps: Components,
                };

                archetype: Archetype,
                page_lists: AutoArrayHashMapUnmanaged(Archetype, PageList).Iterator,
                page_list: ?*Page,
                index_in_page: u32,
                item: Item,

                fn init(entities: *Entities(componentTypes)) @This() {
                    return .{
                        // XXX: will we get the expected errors for non existent fields?
                        // XXX: why can't use a getter for this and the other place?
                        .archetype = comptime archetype: {
                            var archetype = Archetype.initEmpty();
                            inline for (std.meta.fields(@TypeOf(components))) |field| {
                                const entityField: std.meta.FieldEnum(Entity) = @field(components, field.name);
                                archetype.set(@enumToInt(entityField));
                            }
                            break :archetype archetype;
                        },
                        .page_lists = entities.page_lists.iterator(),
                        .page_list = null,
                        .index_in_page = 0,
                        .item = undefined,
                    };
                }

                // XXX: iterator invalidation...does our free list make it worse somehow? also can we make it safe
                // by setting flags in debug mode that indicate that an iterator is live?--
                // oh wait I think it's fine--we just can't create stuff of the archetype that we're itearting. but
                // if it just has a subset of the components that's fine. that's fine for the most common use cases
                // e.g. firing a bullet, and we can enforce it! make sure that's true but i think it should be fine!
                // we could also add a way to defer creation--more robust, but can't work with the entity right away. could
                // return a handle to an empty entity though.
                // XXX: add entity id to item...make sure can't clashs somehow, maybe make an outer struct
                // called item and make the above called components or something.
                fn next(self: *@This()) ?*Item {
                    while (true) {
                        // If we don't have a page list, find the next compatible archetype's page
                        // list
                        if (self.page_list == null) {
                            self.page_list = while (self.page_lists.next()) |page| {
                                if (page.key_ptr.supersetOf(self.archetype)) {
                                    break page.value_ptr.head;
                                }
                            } else {
                                // No more pages, give up
                                return null;
                            };
                            self.index_in_page = 0;
                        }

                        // Find the next entity in this archetype page
                        while (self.index_in_page < self.page_list.?.header().capacity) : (self.index_in_page += 1) {
                            if (self.page_list.?.handleArray()[self.index_in_page].index != invalid_entity_index) {
                                break;
                            }
                        }

                        // If it exists, return it
                        if (self.index_in_page < self.page_list.?.header().capacity) {
                            // XXX: found it! actually set the values here
                            // XXX: just increment the pointers here instead of using index in page?
                            // e.g. have a pointer to exists, and to each component, and increment
                            // each? (or increment exists and then add the right amount to the others)
                            self.item.handle = self.page_list.?.handleArray()[self.index_in_page];
                            inline for (std.meta.fields(Components)) |field| {
                                @field(self.item.comps, field.name) = &self.page_list.?.componentArray(
                                    @intToEnum(std.meta.FieldEnum(Entity), std.meta.fieldIndex(Entity, field.name).?),
                                )[self.index_in_page];
                            }
                            self.index_in_page += 1;
                            return &self.item;
                        }

                        // If we didn't find anything, advance to the next page in this archetype
                        // page list
                        self.page_list = self.page_list.?.header().next;
                        self.index_in_page = 0;
                    }
                }
            };
        }

        fn iterator(self: *@This(), components: anytype) Iterator(components) {
            return Iterator(components).init(self);
        }
    };
}

test "limits" {
    // The max entity id should be considered invalid
    std.debug.assert(max_entities < std.math.maxInt(EntityIndex));

    var entities = try Entities(.{}).init();
    defer entities.deinit();
    var created = std.ArrayList(EntityHandle).init(std.testing.allocator);
    defer created.deinit();

    // Add the max number of entities
    for (0..max_entities) |i| {
        const entity = entities.createEntity(.{});
        try std.testing.expectEqual(EntityHandle{ .index = @intCast(EntityIndex, i), .generation = 0 }, entity);
        try created.append(entity);
    }
    try std.testing.expect(entities.createEntityChecked(.{}) == null);
    const page_pool_size = entities.page_pool.items.len;

    // Remove all the entities
    while (created.popOrNull()) |entity| {
        entities.removeEntity(entity);
    }
    try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

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
            EntityHandle{ .index = @intCast(EntityIndex, i), .generation = 1 },
            entities.createEntity(.{}),
        );
    }
    try std.testing.expect(entities.createEntityChecked(.{}) == null);
    try std.testing.expectEqual(page_pool_size, entities.page_pool.items.len);

    // Wrap a generation counter
    {
        const entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
        entities.slots[entity.index].generation = entity.generation;
        entities.removeEntity(entity);
        try std.testing.expectEqual(
            EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
            entities.createEntity(.{}),
        );
    }
}

// TODO: test the page indices too?
test "free list" {
    var entities = try Entities(.{}).init();
    defer entities.deinit();

    const entity_0_0 = entities.createEntity(.{});
    const entity_1_0 = entities.createEntity(.{});
    const entity_2_0 = entities.createEntity(.{});
    const entity_3_0 = entities.createEntity(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].location.index_in_page, 0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    entities.removeEntity(entity_1_0);
    try std.testing.expectEqual(entities.slots[entity_3_0.index].location.index_in_page, 3);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    entities.removeEntity(entity_3_0);

    const entity_3_1 = entities.createEntity(.{});
    const entity_1_1 = entities.createEntity(.{});
    const entity_4_0 = entities.createEntity(.{});

    try std.testing.expectEqual(entities.slots[entity_0_0.index].location.index_in_page, 0);
    try std.testing.expectEqual(entities.slots[entity_2_0.index].location.index_in_page, 2);
    try std.testing.expectEqual(entities.slots[entity_3_1.index].location.index_in_page, 1);
    try std.testing.expectEqual(entities.slots[entity_1_1.index].location.index_in_page, 3);
    try std.testing.expectEqual(entities.slots[entity_4_0.index].location.index_in_page, 4);

    try std.testing.expectEqual(EntityHandle{ .index = 0, .generation = 0 }, entity_0_0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    try std.testing.expectEqual(EntityHandle{ .index = 2, .generation = 0 }, entity_2_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 1 }, entity_3_1);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 1 }, entity_1_1);
    try std.testing.expectEqual(EntityHandle{ .index = 4, .generation = 0 }, entity_4_0);
}

test "safety" {
    var entities = try Entities(.{}).init();
    defer entities.deinit();

    const entity = entities.createEntity(.{});
    entities.removeEntity(entity);
    try std.testing.expectError(error.BadGeneration, entities.removeEntityChecked(entity));
    try std.testing.expectError(error.BadIndex, entities.removeEntityChecked(EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}

// TODO: better error messages if adding wrong component? or just require unique types afterall, which is
// very reasonable?
test "random data" {
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init();
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

    for (0..10000) |_| {
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
                                        break :handle entities.createEntity(.{ .x = x, .y = y, .z = z });
                                    }
                                }
                            }
                            if (data.x) |x| {
                                if (data.y) |y| {
                                    break :handle entities.createEntity(.{ .x = x, .y = y });
                                }
                            }
                            if (data.x) |x| {
                                if (data.z) |z| {
                                    break :handle entities.createEntity(.{ .x = x, .z = z });
                                }
                            }
                            if (data.y) |y| {
                                if (data.z) |z| {
                                    break :handle entities.createEntity(.{ .y = y, .z = z });
                                }
                            }
                            if (data.x) |x| {
                                break :handle entities.createEntity(.{ .x = x });
                            }
                            if (data.y) |y| {
                                break :handle entities.createEntity(.{ .y = y });
                            }
                            if (data.z) |z| {
                                break :handle entities.createEntity(.{ .z = z });
                            }
                            break :handle entities.createEntity(.{});
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
                // TODO: destroy more at once?
                if (truth.items.len > 0) {
                    const index = rnd.random().uintLessThan(usize, truth.items.len);
                    const removed = truth.orderedRemove(index);
                    entities.removeEntity(removed.handle);
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

// XXX: just while writing it, write a more extensive test later
// XXX: okay so like it's adding entities that's slow...the second time is faster, but only a little
// bit, is something going wrong? are we allocating more often than we should or something?
test "minimal iter test" {
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init();
    defer entities.deinit();

    const entity_0 = entities.createEntity(.{ .x = 10, .y = 20 });
    const entity_1 = entities.createEntity(.{ .x = 30, .y = 40 });
    const entity_2 = entities.createEntity(.{ .x = 50 });
    const entity_3 = entities.createEntity(.{ .y = 60 });

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

// TODO: missing features:
// - fast & convenient iteration
//     - getComponent on the iterator for non-iter components, but still faster than going through the handle?
// - const/non const or no?
// - adding/removing components to live entities
// - tests for page free lists?
//   - assert that at each step they're sorted correctly?
// - check perf
