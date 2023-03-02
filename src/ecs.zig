const std = @import("std");
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const builtin = @import("builtin");

const max_entities: EntityIndex = 1000000;

const EntityIndex = u32;

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

        // TODO: pack this tightly, cache right data
        const PageHeader = struct {
            next: ?*Page,
            prev: ?*Page,
            archetype: Archetype,
            capacity: EntityIndex,
            entity_size: usize,
            len: usize,
        };
        const PageList = struct {
            head: *Page,
            tail: *Page,
        };
        // TODO: make sure exactly one page size, make sure ordered correctly, may need to store everything
        // in byte array
        // TODO: comptime make sure capacity large enough even if all components used at once?
        // TODO: explain alignment sort here
        const Page = struct {
            data: [std.mem.page_size - @sizeOf(PageHeader)]u8 align(std.mem.page_size),
            header: PageHeader,

            fn init(self: *Page, archetype: Archetype) void {
                // Calculate the space one entity takes up. No space is wasted due to padding, since
                // the data field is page aligned and the components are sorted from largest
                // alignment to smallest.
                var entity_size: usize = 0;
                entity_size += 1; // One byte for the existence flag
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (archetype.isSet(i)) {
                        entity_size += @sizeOf(component.type);
                    }
                }
                const capacity = @intCast(EntityIndex, self.data.len / entity_size);

                self.* = Page{
                    .header = .{
                        .next = null,
                        .prev = null,
                        .archetype = archetype,
                        .capacity = capacity,
                        .entity_size = entity_size,
                        .len = 0,
                    },
                    .data = undefined,
                };
            }

            // TODO: should probably have an internal free list to accelerate this
            // TODO: make sure this cast is always safe at comptime?
            fn createEntity(self: *@This()) EntityIndex {
                // TODO: subs out the exists flag..a little confusing and more math than necessary, does one other place too
                const start = (self.header.entity_size - 1) * self.header.capacity;
                for (self.data[start..(start + self.header.capacity)], 0..) |*b, i| {
                    if (!@ptrCast(*bool, b).*) {
                        // TODO: make assertions in get component that it exists first
                        @ptrCast(*bool, b).* = true;
                        self.header.len += 1;
                        return @intCast(EntityIndex, i);
                    }
                }
                // TODO: restructure so this assertions is checked at the beginning of this call again by having it return null?
                unreachable;
            }

            // TODO: i was previously thinking i needed a reference to the handle here--is that correct or no? maybe
            // required for the iterator?
            fn removeEntity(self: *Page, index: usize) void {
                self.header.len -= 1;
                // TODO: subs out the exists flag..a little confusing and more math than necessary, does one other place too
                @ptrCast(*bool, &self.data[(self.header.entity_size - 1) * self.header.capacity + index]).* = false;
            }

            // TODO: usize as index?
            // TODO: faster method when setting multiple components at once?
            fn getComponent(self: *Page, comptime componentField: std.meta.FieldEnum(Entity), index: usize) *std.meta.fieldInfo(Entity, componentField).type {
                var ptr: usize = 0;
                inline for (std.meta.fields(Entity), 0..) |component, i| {
                    if (self.header.archetype.isSet(i)) {
                        if (@intToEnum(std.meta.FieldEnum(Entity), i) == componentField) {
                            ptr += index * @sizeOf(component.type);
                            return @ptrCast(*component.type, @alignCast(@alignOf(component.type), &self.data[ptr]));
                        }
                        ptr += @sizeOf(component.type) * self.header.capacity;
                    }
                }
                unreachable;
            }
        };

        slots: []EntitySlot,
        free: []EntityIndex,
        // TODO: better way to allocate this..? should we even be using the hashmap here?
        pagePool: ArrayListUnmanaged(*Page),
        // Ordered so that pages with space available are always at the front.
        pageLists: AutoArrayHashMapUnmanaged(Archetype, PageList),

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
                .pageLists = .{},
                // TODO: init capacity? not actually really pooling these yet just accumulating them
                .pagePool = .{},
            };
        }

        fn deinit(self: *@This()) void {
            std.heap.page_allocator.free(self.slots);
            std.heap.page_allocator.free(self.free);
            self.pageLists.deinit(std.heap.page_allocator);
            for (self.pagePool.items) |page| {
                std.heap.page_allocator.destroy(page);
            }
            self.pagePool.deinit(std.heap.page_allocator);
        }

        fn createEntityChecked(self: *@This(), entity: anytype) ?EntityHandle {
            // Determine the archetype of this entity
            comptime var archetype = Archetype.initEmpty();
            // TODO: why is comptime block required here?
            comptime {
                inline for (std.meta.fieldNames(@TypeOf(entity))) |fieldName| {
                    archetype.set(std.meta.fieldIndex(Entity, fieldName).?);
                }
            }

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

            // TODO: don't ignore errors in this function...just trying things out
            // Get the page list for this archetype
            const pageList: *PageList = page: {
                // TODO: allocate pages up front in pool when possible
                // Find or allocate a page for this entity
                const entry = self.pageLists.getOrPut(
                    std.heap.page_allocator,
                    archetype,
                ) catch unreachable;
                if (!entry.found_existing) {
                    const head = (std.heap.page_allocator.create(Page) catch unreachable);
                    head.init(archetype);
                    self.pagePool.append(std.heap.page_allocator, head) catch unreachable;
                    entry.value_ptr.* = .{
                        .head = head,
                        // TODO: do we ever use tail?
                        .tail = head,
                    };
                }
                break :page entry.value_ptr;
            };

            // If the head does not have space, create a new head that has space
            if (pageList.head.header.len == pageList.head.header.capacity) {
                // XXX: dup init code...
                const newPage = (std.heap.page_allocator.create(Page) catch unreachable);
                newPage.init(archetype);
                self.pagePool.append(std.heap.page_allocator, newPage) catch unreachable;
                newPage.header.next = pageList.head;
                pageList.head = newPage;
                pageList.head.header.next.?.header.prev = pageList.head;
            }
            const page = pageList.head;

            // Create a new entity
            self.slots[index].location = EntityLocation{
                .page = page,
                .index_in_page = page.createEntity(),
            };

            // If the page is now full, move it to the end of the page list
            if (page.header.len == page.header.capacity) {
                if (page.header.next) |next| {
                    // Remove page from the list
                    pageList.head = next;

                    // Insert page at the end of the list
                    pageList.tail.header.next = page;
                    page.header.prev = pageList.tail;
                    pageList.tail = page;
                }
            }

            // Initialize the new entity
            // TODO: loop fastest or can cache math?
            inline for (std.meta.fields(@TypeOf(entity))) |f| {
                page.getComponent(
                    @intToEnum(std.meta.FieldEnum(Entity), std.meta.fieldIndex(Entity, f.name).?),
                    self.slots[index].location.index_in_page,
                ).* = @field(entity, f.name);
            }

            // Return a handle to the entity
            return EntityHandle{
                .index = index,
                .generation = self.slots[index].generation,
            };
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

            // TODO: use const in more places--not transitive through ptrs right?
            // TODO: dup index?
            // TODO: have a setter and assert not already set? or just add assert?
            // Unset the exists bit, and reorder the page
            const page = self.slots[entity.index].location.page;
            page.removeEntity(self.slots[entity.index].location.index_in_page);
            const pageList: *PageList = self.pageLists.getPtr(page.header.archetype).?;

            // Move the page to the front of the page list
            if (pageList.head != page) {
                // Remove the page from the list
                if (page.header.prev) |prev| {
                    prev.header.next = page.header.next;
                }
                if (page.header.next) |next| {
                    next.header.prev = page.header.prev;
                }

                // Reinsert it at head
                page.header.next = pageList.head;
                pageList.head = page;
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
            if (!slot.location.page.header.archetype.isSet(@enumToInt(component))) {
                return null;
            }
            return slot.location.page.getComponent(component, slot.location.index_in_page);
        }

        pub fn getComponent(self: *@This(), entity: EntityHandle, comptime component: std.meta.FieldEnum(Entity)) ?*std.meta.fieldInfo(Entity, component).type {
            return self.getComponentChecked(entity, component) catch unreachable;
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
    {
        for (0..max_entities) |i| {
            const entity = entities.createEntity(.{});
            try std.testing.expectEqual(EntityHandle{ .index = @intCast(EntityIndex, i), .generation = 0 }, entity);
            try created.append(entity);
        }
        try std.testing.expect(entities.createEntityChecked(.{}) == null);
    }

    // Remove all the entities
    {
        for (0..created.items.len) |i| {
            entities.removeEntity(created.items[created.items.len - i - 1]);
        }
    }

    // Create a bunch of entities again
    {
        for (0..max_entities) |i| {
            try std.testing.expectEqual(
                EntityHandle{ .index = @intCast(EntityIndex, i), .generation = 1 },
                entities.createEntity(.{}),
            );
        }
        try std.testing.expect(entities.createEntityChecked(.{}) == null);
    }

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

    for (0..5000) |_| {
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
    }
}

// TODO: missing features:
// - fast & convenient iteration
// - const/non const or no?
// - adding/removing components to live entities
// - tests for page free lists?
//   - assert that at each step they're sorted correctly?
