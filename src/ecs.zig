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

fn compareEntityFields(_: void, comptime lhs: std.builtin.Type.StructField, comptime rhs: std.builtin.Type.StructField) bool {
    return @alignOf(lhs.type) > @alignOf(rhs.type);
}

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
            std.sort.sort(std.builtin.Type.StructField, &fields, {}, compareEntityFields);
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
        const EntitySlot = struct {
            generation: EntityGeneration,
            page: *Page,
            index_in_page: u32,
        };

        // TODO: pack this tightly, cache right data
        const PageHeader = struct {
            next: ?*Page,
            archetype: Archetype,
            capacity: EntityIndex,
            entity_size: usize,
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
                inline for (std.meta.fields(Entity), 0..) |registered, i| {
                    if (archetype.isSet(i)) {
                        entity_size += @sizeOf(registered.type);
                    }
                }
                // TODO: okay to access len here?
                const capacity = @intCast(EntityIndex, self.data.len / entity_size);

                self.* = Page{
                    .header = .{
                        .next = null,
                        .archetype = archetype,
                        .capacity = capacity,
                        .entity_size = entity_size,
                    },
                    .data = undefined,
                };
            }

            // TODO: maybe have an internal free list or such to accelerate this and early out when it's full etc
            // TODO: make sure this cast is always safe at comptime?
            // TODO: return type
            fn createEntity(self: *@This()) ?EntityIndex {
                // TODO: subs out the exists flag..a little confusing and more math than necessary, does one other place too
                const start = (self.header.entity_size - 1) * self.header.capacity;
                for (self.data[start..], 0..) |*b, i| {
                    if (!@ptrCast(*bool, b).*) {
                        return @intCast(EntityIndex, i);
                    }
                }
                return null;
            }

            // TODO: i was previously thinking i needed a reference to the handle here--is that correct or no? maybe
            // required for the iterator?
            fn getExists(self: *Page, index: usize) *bool {
                // TODO: subs out the exists flag..a little confusing and more math than necessary, does one other place too
                return @ptrCast(*bool, &self.data[(self.header.entity_size - 1) * self.header.capacity + index]);
            }

            // TODO: usize as index?
            fn getComponent(self: *Page, comptime component: std.meta.FieldEnum(Entity), index: usize) *std.meta.fieldInfo(Entity, component).type {
                var ptr: usize = 0;
                inline for (std.meta.fields(Entity), 0..) |registered, i| {
                    if (self.header.archetype.isSet(i)) {
                        if (i == @enumToInt(component)) {
                            ptr += index * @sizeOf(registered.type);
                            return @ptrCast(*registered.type, @alignCast(@alignOf(registered.type), &self.data[ptr]));
                        }
                        ptr += @sizeOf(registered.type) * self.header.capacity;
                    }
                }
                unreachable;
            }
        };

        entities: []EntitySlot,
        free: []EntityIndex,
        // TODO: better way to allocate this..? should we even be using the hashmap here?
        pagePool: ArrayListUnmanaged(*Page),
        pageLists: AutoArrayHashMapUnmanaged(Archetype, *Page),

        fn init() !@This() {
            return .{
                .entities = entities: {
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
            std.heap.page_allocator.free(self.entities);
            std.heap.page_allocator.free(self.free);
            self.pageLists.deinit(std.heap.page_allocator);
            for (self.pagePool.items) |page| {
                std.heap.page_allocator.destroy(page);
            }
            self.pagePool.deinit(std.heap.page_allocator);
        }

        fn createEntityChecked(self: *@This(), entity: anytype) ?EntityHandle {
            // Find a free index for the entity
            const index = index: {
                if (self.free.len > 0) {
                    // Pop an id from the free list
                    const top = self.free.len - 1;
                    const index = self.free[top];
                    self.free.len = top;
                    break :index index;
                } else if (self.entities.len < max_entities) {
                    // Add a new entity to the end of the list
                    const top = self.entities.len;
                    self.entities.len += 1;
                    self.entities[top] = .{
                        .generation = 0,
                        // TODO: ...
                        .page = undefined,
                        .index_in_page = undefined,
                    };
                    break :index @intCast(EntityIndex, top);
                } else {
                    return null;
                }
            };

            // TODO: don't ignore errors here...just trying things out
            // TODO: allocate pages up front in pool when possible
            // Find or allocate a page for this entity
            var archetype = @This().getArchetype(@TypeOf(entity));
            var entry = self.pageLists.getOrPut(
                std.heap.page_allocator,
                archetype,
            ) catch unreachable;
            if (!entry.found_existing) {
                var page = (std.heap.page_allocator.create(Page) catch unreachable);
                page.init(archetype);
                self.pagePool.append(std.heap.page_allocator, page) catch unreachable;
                entry.value_ptr.* = page;
            }

            // TODO: assumes there's room in this page for now, never creates a new one
            // TODO: cache array lookup?
            // Populate the entity
            self.entities[index].index_in_page = entry.value_ptr.*.createEntity() orelse unreachable;
            self.entities[index].page = entry.value_ptr.*;

            // TODO: loop fastest or can cache math?
            // XXX: error handling for fields that don't match...
            var page: *Page = entry.value_ptr.*;
            inline for (std.meta.fields(@TypeOf(entity))) |f| {
                page.getComponent(
                    @intToEnum(std.meta.FieldEnum(Entity), std.meta.fieldIndex(Entity, f.name) orelse unreachable),
                    self.entities[index].index_in_page,
                ).* = @field(entity, f.name);
            }

            // Return a handle to the entity
            return EntityHandle{
                .index = index,
                .generation = self.entities[index].generation,
            };
        }

        pub fn createEntity(self: *@This(), entity: anytype) EntityHandle {
            return self.createEntityChecked(entity) orelse
                std.debug.panic("out of entities", .{});
        }

        fn removeEntityChecked(self: *@This(), entity: EntityHandle) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.entities.len) {
                return error.BadIndex;
            }
            if (self.entities[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }
            if (self.free.len == max_entities) {
                return error.FreelistFull;
            }

            // Increment this entity slot's generation so future uses will fail
            self.entities[entity.index].generation +%= 1;

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
            if (entity.index >= self.entities.len) {
                return error.BadIndex;
            }
            if (self.entities[entity.index].generation != entity.generation) {
                return error.BadGeneration;
            }

            // TODO: repeatedly searching for index of type...store as that.. or doesn't matter cause comptime?
            var slot = self.entities[entity.index];
            if (!Archetype.subsetOf(@This().componentMask_(component), slot.page.header.archetype)) {
                return null;
            }
            return slot.page.getComponent(component, slot.index_in_page);
        }

        // TODO: const vs non const?
        pub fn getComponent(self: *@This(), entity: EntityHandle, comptime component: std.meta.FieldEnum(Entity)) ?*std.meta.fieldInfo(Entity, component).type {
            return self.getComponentChecked(entity, component) catch unreachable;
        }

        // XXX: ...
        fn componentMask_(comptime component: std.meta.FieldEnum(Entity)) Archetype {
            var mask = Archetype.initEmpty();
            mask.set(@enumToInt(component));
            return mask;
        }
        fn componentMask(comptime component: []const u8) Archetype {
            // TODO: comptime blocks necessary?
            comptime {
                if (std.meta.fieldIndex(Entity, component)) |i| {
                    var mask = Archetype.initEmpty();
                    mask.set(i);
                    return mask;
                }
                @compileError("component '" ++ component ++ "' not registered");
            }
        }

        // XXX: omg FieldEnum and FieldType!!
        fn componentType(comptime component: []const u8) type {
            comptime {
                inline for (std.meta.fields(Entity)) |c| {
                    if (std.mem.eql(u8, c.name, component)) {
                        return c.type;
                    }
                }
                @compileError("component '" ++ component ++ "' not registered");
            }
        }

        fn getArchetype(comptime Components: type) Archetype {
            comptime {
                var result = Archetype.initEmpty();
                inline for (std.meta.fields(Components)) |component| {
                    result = result.unionWith(componentMask(component.name));
                }
                return result;
            }
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
        var i: EntityIndex = 0;
        while (i < max_entities) : (i += 1) {
            const entity = entities.createEntity(.{});
            try std.testing.expectEqual(EntityHandle{ .index = i, .generation = 0 }, entity);
            try created.append(entity);
        }
        try std.testing.expect(entities.createEntityChecked(.{}) == null);
    }

    // Remove all the entities
    {
        var i: EntityIndex = max_entities - 1;
        while (true) {
            entities.removeEntity(created.items[i]);
            if (i == 0) break else i -= 1;
        }
    }

    // Create a bunch of entities again
    {
        var i: EntityIndex = 0;
        while (i < max_entities) : (i += 1) {
            try std.testing.expectEqual(
                EntityHandle{ .index = i, .generation = 1 },
                entities.createEntity(.{}),
            );
        }
        try std.testing.expect(entities.createEntityChecked(.{}) == null);
    }

    // Wrap a generation counter
    {
        var entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
        entities.entities[entity.index].generation = entity.generation;
        entities.removeEntity(entity);
        try std.testing.expectEqual(
            EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
            entities.createEntity(.{}),
        );
    }
}

test "create destroy" {
    var entities = try Entities(.{}).init();
    defer entities.deinit();

    const entity_0_0 = entities.createEntity(.{});
    const entity_1_0 = entities.createEntity(.{});
    const entity_2_0 = entities.createEntity(.{});
    const entity_3_0 = entities.createEntity(.{});

    entities.removeEntity(entity_1_0);
    entities.removeEntity(entity_3_0);

    const entity_3_1 = entities.createEntity(.{});
    const entity_1_1 = entities.createEntity(.{});
    const entity_4_0 = entities.createEntity(.{});

    try std.testing.expectEqual(EntityHandle{ .index = 0, .generation = 0 }, entity_0_0);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 0 }, entity_1_0);
    try std.testing.expectEqual(EntityHandle{ .index = 2, .generation = 0 }, entity_2_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 0 }, entity_3_0);
    try std.testing.expectEqual(EntityHandle{ .index = 3, .generation = 1 }, entity_3_1);
    try std.testing.expectEqual(EntityHandle{ .index = 1, .generation = 1 }, entity_1_1);
    try std.testing.expectEqual(EntityHandle{ .index = 4, .generation = 0 }, entity_4_0);
}

test "safety checks" {
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

test "archetype masks" {
    var entities = try Entities(.{ .x = u8, .y = u8 }).init();
    defer entities.deinit();

    // TODO: ...
    // var archetype = @TypeOf(entities).Archetype.initEmpty();
    // try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{}));
    // try std.testing.expect(!archetype.eql(comptime @TypeOf(entities).archetype(.{ .y = u8 })));
    // archetype.set(0);
    // try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ .x = u32 }));
    // archetype.set(1);
    // try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ .x = u32, .y = u8 }));
    // try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ .y = u8, .x = u32 }));
    // archetype.unset(0);
    // try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ .y = u8 }));

    // const A = struct {
    //     x: u8,
    //     y: u8,
    // };
    // const B = struct {
    //     y: u8,
    //     x: u8,
    // };
    _ = entities.createEntity(.{ .x = 1, .y = 2 });
    _ = entities.createEntity(.{ .y = 1, .x = 2 });
}

// // TODO: hmm this should be failing..why isn't it? we've commented out the code that actually does
// // the calculations
// fn testSizeAlignment(entities: anytype, comptime entity: type) !void {
//     try std.testing.expectEqual(
//         @TypeOf(entities).archetypeSizeAlignment(@TypeOf(entities).getArchetype(entity)).size,
//         @sizeOf(entity),
//     );
//     try std.testing.expectEqual(
//         @TypeOf(entities).archetypeSizeAlignment(@TypeOf(entities).getArchetype(entity)).alignment,
//         @alignOf(entity),
//     );
// }

// test "archetype size alignment" {
//     var entities = try Entities(struct { x: u8, y: u32, z: u16 }).init();
//     defer entities.deinit();

//     // TODO: okay I'm seeing the advantages of the aabbb layout, wastes less space on padding
//     try testSizeAlignment(entities, extern struct { x: u8 });
//     try testSizeAlignment(entities, extern struct { y: u32 });
//     try testSizeAlignment(entities, extern struct { z: u16 });
//     try testSizeAlignment(entities, extern struct { x: u8, y: u32 });
//     try testSizeAlignment(entities, extern struct { x: u8, z: u16 });
//     try testSizeAlignment(entities, extern struct { y: u32, z: u16 });
//     try testSizeAlignment(entities, extern struct { x: u8, y: u32, z: u16 });
// }

// TODO: ...
test "page" {
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init();
    defer entities.deinit();

    const Page = @TypeOf(entities).Page;

    var page = Page.init(@TypeOf(entities).getArchetype(struct { x: u32, z: u16 }));
    for (0..page.header.capacity) |i| {
        page.getComponent("x", u32, i).* = @intCast(u32, i);
        page.getComponent("z", u16, i).* = @intCast(u16, i * 10);
        page.getExists(i).* = i % 3 == 0;
    }

    for (0..page.header.capacity) |i| {
        try std.testing.expectEqual(i, page.getComponent("x", u32, i).*);
        try std.testing.expectEqual(i * 10, page.getComponent("z", u16, i).*);
        try std.testing.expectEqual(i % 3 == 0, page.getExists(i).*);
    }
}

// TODO: better error messages if adding wrong component? or just require unique types afterall, which is
// very reasonable?
test "page" {
    // XXX: would be less confusing to just pass name type pairs, so it's clear all other info is discareded.
    // Also would make errors better when missing a requested field I think, maybe?
    var entities = try Entities(.{ .x = u32, .y = u8, .z = u16 }).init();
    defer entities.deinit();

    const entity = entities.createEntity(.{ .x = 123, .y = 45 });
    try std.testing.expectEqual(@intCast(u32, 123), (entities.getComponent(entity, .x) orelse unreachable).*);
    try std.testing.expectEqual(@intCast(u16, 45), (entities.getComponent(entity, .y) orelse unreachable).*);
}
