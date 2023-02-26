const std = @import("std");
const builtin = @import("builtin");

const max_entities: EntityIndex = 1000000;

const EntityIndex = u32;

const EntityGeneration = switch (builtin.mode) {
    .Debug, .ReleaseSafe => u32,
    .ReleaseSmall, .ReleaseFast => u0,
};

pub const EntityHandle = struct {
    generation: EntityGeneration,
    index: EntityIndex,
};

pub fn Entities(comptime components: anytype) type {
    // Make sure all components are unique
    {
        var l = 0;
        inline while (l < components.len) : (l += 1) {
            var r = l + 1;
            while (r < components.len) : (r += 1) {
                if (components[r] == components[l]) {
                    @compileError("duplicate components registered");
                }
            }
        }
    }

    // Create the type
    return struct {
        const Archetype: type = std.bit_set.IntegerBitSet(@typeInfo(@TypeOf(components)).Struct.fields.len);

        entities: []EntityGeneration,
        free: []EntityIndex,

        fn init() !@This() {
            return .{
                .entities = entities: {
                    var entities = try std.heap.page_allocator.alloc(EntityGeneration, max_entities);
                    entities.len = 0;
                    break :entities entities;
                },
                .free = free: {
                    var free = try std.heap.page_allocator.alloc(EntityIndex, max_entities);
                    free.len = 0;
                    break :free free;
                },
            };
        }

        fn deinit(self: *@This()) void {
            std.heap.page_allocator.free(self.entities);
            std.heap.page_allocator.free(self.free);
        }

        fn createEntityChecked(self: *@This()) ?EntityHandle {
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
                    self.entities[top] = 0;
                    break :index @intCast(EntityIndex, top);
                } else {
                    return null;
                }
            };
            return EntityHandle{
                .index = index,
                .generation = self.entities[index],
            };
        }

        pub fn createEntity(self: *@This()) EntityHandle {
            return self.createEntityChecked() orelse
                std.debug.panic("out of entities", .{});
        }

        fn removeEntityChecked(self: *@This(), entity: EntityHandle) !void {
            // Check that the entity is valid. These should be assertions, but I've made them error
            // codes for easier unit testing.
            if (entity.index >= self.entities.len) {
                return error.BadIndex;
            }
            if (self.entities[entity.index] != entity.generation) {
                return error.BadGeneration;
            }
            if (self.free.len == max_entities) {
                return error.FreelistFull;
            }

            // Increment this entity slot's generation so future uses will fail
            self.entities[entity.index] +%= 1;

            // Add the entity to the free list
            const top = self.free.len;
            self.free.len += 1;
            self.free[top] = entity.index;
        }

        pub fn removeEntity(self: *@This(), entity: EntityHandle) void {
            self.removeEntityChecked(entity) catch unreachable;
        }

        fn componentMask(comptime Component: type) Archetype {
            comptime var i = 0;
            inline for (components) |c| {
                if (c == Component) {
                    comptime var mask = Archetype.initEmpty();
                    mask.set(i);
                    return mask;
                }
                i += 1;
            }
            @compileError("component type not registered");
        }

        fn archetype(comptime archetypeComponents: anytype) Archetype {
            comptime var result = Archetype.initEmpty();
            inline for (archetypeComponents) |component| {
                result = result.unionWith(componentMask(component));
            }
            return result;
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
            const entity = entities.createEntity();
            try std.testing.expectEqual(EntityHandle{ .index = i, .generation = 0 }, entity);
            try created.append(entity);
        }
        try std.testing.expect(entities.createEntityChecked() == null);
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
                entities.createEntity(),
            );
        }
        try std.testing.expect(entities.createEntityChecked() == null);
    }

    // Wrap a generation counter
    {
        var entity = EntityHandle{ .index = 0, .generation = std.math.maxInt(EntityGeneration) };
        entities.entities[entity.index] = entity.generation;
        entities.removeEntity(entity);
        try std.testing.expectEqual(
            EntityHandle{ .index = 0, .generation = @intCast(EntityGeneration, 0) },
            entities.createEntity(),
        );
    }
}

test "create destroy" {
    var entities = try Entities(.{}).init();
    defer entities.deinit();

    const entity_0_0 = entities.createEntity();
    const entity_1_0 = entities.createEntity();
    const entity_2_0 = entities.createEntity();
    const entity_3_0 = entities.createEntity();

    entities.removeEntity(entity_1_0);
    entities.removeEntity(entity_3_0);

    const entity_3_1 = entities.createEntity();
    const entity_1_1 = entities.createEntity();
    const entity_4_0 = entities.createEntity();

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

    const entity = entities.createEntity();
    entities.removeEntity(entity);
    try std.testing.expectError(error.BadGeneration, entities.removeEntityChecked(entity));
    try std.testing.expectError(error.BadIndex, entities.removeEntityChecked(EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}

test "archetype masks" {
    var entities = try Entities(.{ u32, u8 }).init();
    defer entities.deinit();

    var archetype = @TypeOf(entities).Archetype.initEmpty();
    try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{}));
    try std.testing.expect(!archetype.eql(comptime @TypeOf(entities).archetype(.{u8})));
    archetype.set(0);
    try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{u32}));
    archetype.set(1);
    try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ u32, u8 }));
    try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{ u8, u32 }));
    archetype.unset(0);
    try std.testing.expectEqual(archetype, comptime @TypeOf(entities).archetype(.{u8}));
}
