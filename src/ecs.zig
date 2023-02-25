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

pub const Entities = struct {
    entities: []EntityGeneration,
    free: []EntityIndex,

    fn init() !Entities {
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

    fn deinit(self: *Entities) void {
        std.heap.page_allocator.free(self.entities);
        std.heap.page_allocator.free(self.free);
    }

    fn createEntityChecked(self: *Entities) ?EntityHandle {
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

    fn createEntity(self: *Entities) EntityHandle {
        return self.createEntityChecked() orelse
            std.debug.panic("out of entities", .{});
    }

    fn removeEntityChecked(self: *Entities, entity: EntityHandle) !void {
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

    fn removeEntity(self: *Entities, entity: EntityHandle) void {
        self.removeEntityChecked(entity) catch unreachable;
    }
};

test "limits" {
    // The max entity id should be considered invalid
    std.debug.assert(max_entities < std.math.maxInt(EntityIndex));

    var entities = try Entities.init();
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
    var entities = try Entities.init();
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
    var entities = try Entities.init();
    defer entities.deinit();

    const entity = entities.createEntity();
    entities.removeEntity(entity);
    try std.testing.expectError(error.BadGeneration, entities.removeEntityChecked(entity));
    try std.testing.expectError(error.BadIndex, entities.removeEntityChecked(EntityHandle{
        .index = 1,
        .generation = 0,
    }));
}
