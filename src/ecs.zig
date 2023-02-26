const std = @import("std");
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const builtin = @import("builtin");

const max_entities: EntityIndex = 1000000;

const EntityIndex = u32;

const track_generation = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseSmall, .ReleaseFast => false,
};

const EntityGeneration = if (track_generation) u32 else u0;

// XXX: pack and use all bits?
pub const EntityHandle = struct {
    generation: EntityGeneration,
    index: EntityIndex,
};

const EntitySlot = struct {
    generation: EntityGeneration,
};

pub fn Entities(comptime RegisteredComponents: type) type {
    return struct {
        const Archetype: type = std.bit_set.IntegerBitSet(@typeInfo(RegisteredComponents).Struct.fields.len);
        const PageHeader = struct {
            next: ?*anyopaque = null,
        };

        entities: []EntitySlot,
        free: []EntityIndex,
        // XXX: better way to allocate this..? should we even be using the hashmap here?
        pageLists: AutoArrayHashMapUnmanaged(Archetype, *anyopaque),

        // XXX: maybe make helpers that convert between the various reprs..?
        // XXX: naming of arg..?
        // XXX: how does allocation/stack space/etc work during comptime?
        fn Page(comptime EntityUnordered: type) type {
            const Entity = Entity: {
                comptime var fields: [@typeInfo(EntityUnordered).Struct.fields.len]std.builtin.Type.StructField = undefined;
                comptime var i = 0;
                inline for (@typeInfo(RegisteredComponents).Struct.fields) |registered| {
                    inline for (@typeInfo(EntityUnordered).Struct.fields) |component| {
                        if (std.mem.eql(u8, component.name, registered.name)) {
                            fields[i] = std.builtin.Type.StructField{
                                .name = registered.name,
                                .type = registered.type,
                                .default_value = null,
                                .is_comptime = false,
                                .alignment = @alignOf(registered.type),
                            };
                            i += 1;
                            break;
                        }
                    }
                }
                if (i < fields.len) {
                    // XXX: give better error, also prevent writing TOO MANY somehow etc or not possible?
                    @compileError("not all fields found");
                }
                break :Entity @Type(std.builtin.Type{
                    .Struct = std.builtin.Type.Struct{
                        .layout = .Auto,
                        .backing_integer = null,
                        .fields = &fields,
                        .decls = &[_]std.builtin.Type.Declaration{},
                        .is_tuple = false,
                    },
                });
            };

            // Create the page type
            const PageType = struct {
                header: PageHeader,
                entities: [std.mem.page_size - @sizeOf(PageHeader)]?Entity,

                // XXX: maybe have an internal free list or such to accelerate this and early out when it's full etc
                // XXX: make sure this cast is always safe at comptime?
                fn createEntity(self: *@This()) ?u16 {
                    for (self.entities, 0..) |entity, i| {
                        if (entity) |_| {
                            return @intCast(u16, i);
                        }
                    }
                    return null;
                }
            };

            // XXX: is there some better way to set the entities size so this always works..?
            // // Make sure it's the right size, and then return it
            // if (@sizeOf(PageType) != std.mem.page_size) {
            //     @compileError("unreachable: Page struct is of wrong size");
            // }
            return PageType;
        }

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
            };
        }

        fn deinit(self: *@This()) void {
            std.heap.page_allocator.free(self.entities);
            std.heap.page_allocator.free(self.free);
            self.pageLists.deinit(std.heap.page_allocator);
            // XXX: actually free the pages...
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
                    };
                    break :index @intCast(EntityIndex, top);
                } else {
                    return null;
                }
            };

            // XXX: don't ignore errors here...just trying things out
            // XXX: allocate pages up front in pool when possible?
            // Find or allocate a page for this entity
            var entry = self.pageLists.getOrPut(
                std.heap.page_allocator,
                @This().archetype(entity),
            ) catch unreachable;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.heap.page_allocator.create(Page(@TypeOf(entity))) catch unreachable;
            }
            const page: *Page(@TypeOf(entity)) = @ptrCast(*Page(@TypeOf(entity)), @alignCast(@alignOf(*Page(@TypeOf(entity))), entry.value_ptr.*));

            // XXX: assumes there's room in this page for now, never creates a new one
            // Populate the entity
            const indexInPage = page.createEntity() orelse unreachable;
            // XXX: rename to entity
            page.entities[indexInPage] = entity;
            // XXX: now we wanna also store the indexinpage, as well as the page, on the entityslot
            // so that we can look it back up later in a getComponents call or such!

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

        // XXX: wait type ids are a thing? do we even need this?
        fn componentMask(comptime component: []const u8) Archetype {
            comptime {
                inline for (@typeInfo(RegisteredComponents).Struct.fields, 0..) |c, i| {
                    if (std.mem.eql(u8, c.name, component)) {
                        var mask = Archetype.initEmpty();
                        mask.set(i);
                        return mask;
                    }
                }
                @compileError("component '" ++ component ++ "' not registered");
            }
        }

        fn componentType(comptime component: []const u8) type {
            comptime {
                // XXX: use std.meta.fields instead?
                inline for (@typeInfo(RegisteredComponents).Struct.fields) |c| {
                    if (std.mem.eql(u8, c.name, component)) {
                        return c.type;
                    }
                }
                @compileError("component '" ++ component ++ "' not registered");
            }
        }

        fn archetype(components: anytype) Archetype {
            comptime {
                var result = Archetype.initEmpty();
                inline for (@typeInfo(@TypeOf(components)).Struct.fields) |component| {
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

    var entities = try Entities(struct {}).init();
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
    var entities = try Entities(struct {}).init();
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
    var entities = try Entities(struct {}).init();
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
    var entities = try Entities(struct { x: u8, y: u8 }).init();
    defer entities.deinit();

    // XXX: ...
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
