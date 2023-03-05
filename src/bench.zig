const std = @import("std");
const builtin = @import("builtin");
const ecs = @import("ecs.zig");
const Entities = ecs.Entities;
const EntityHandle = ecs.EntityHandle;

pub fn main() !void {
    std.debug.print("ECS:\n", .{});
    try benchEcs();
    std.debug.print("\n", .{});

    std.debug.print("ArrayList:\n", .{});
    try perfArrayList();
    std.debug.print("\n", .{});

    std.debug.print("MultiArrayList:\n", .{});
    try benchMultiArrayList();
    std.debug.print("\n", .{});

    if (builtin.mode != .ReleaseFast) {
        std.debug.print("\nWARNING: bench run in {} mode\n\n", .{builtin.mode});
    }
}

fn benchEcs() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Init
    var timer = try std.time.Timer.start();
    var entities = try Entities(.{ .x = u128, .y = u256, .z = u128 }).init(allocator);
    defer entities.deinit(allocator);
    std.debug.print("\tinit: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Create entities
    for (0..(ecs.max_entities - 1)) |_| {
        _ = entities.create(.{ .x = 24, .y = 12 });
    }
    _ = entities.create(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Iter over entities
    {
        var iter = entities.iterator(.{ .x, .y });
        while (iter.next()) |e| {
            try std.testing.expect(e.comps.x.* == 24);
            try std.testing.expect(e.comps.y.* == 12);
        }
        std.debug.print("\titer(all): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    // Iter one entity
    {
        var iter = entities.iterator(.{.z});
        while (iter.next()) |e| {
            try std.testing.expect(e.comps.z.* == 13);
        }
        std.debug.print("\titer(1): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    var all = std.ArrayList(EntityHandle).init(allocator);
    defer all.deinit();
    {
        var iter = entities.iterator(.{});
        while (iter.next()) |next| {
            try all.append(next.handle);
        }
    }
    _ = timer.lap();

    // Getting components
    for (all.items, 0..) |entity, i| {
        try std.testing.expect(entities.getComponent(entity, .y).?.* == 12);
        const x = entities.getComponent(entity, .x).?.*;
        // try std.testing.expect(x == i or x == 2);
        _ = i;
        _ = x;
    }
    std.debug.print("\tgetComponent(all): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Remove all entities
    for (all.items) |entity| {
        entities.removeEntity(entity);
    }
    std.debug.print("\tremove(all): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
}

pub fn perfArrayList() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const Entity = struct {
        x: ?u128 = null,
        y: ?u256 = null,
        z: ?u128 = null,
    };

    var timer = try std.time.Timer.start();
    var array = try std.ArrayList(Entity).initCapacity(allocator, ecs.max_entities);
    defer array.deinit();
    std.debug.print("\tinit: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Create entities
    _ = timer.lap();
    for (0..(ecs.max_entities - 1)) |_| {
        array.appendAssumeCapacity(.{ .x = 24, .y = 12 });
    }
    array.appendAssumeCapacity(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Iter over entities
    {
        for (array.items) |item| {
            if (item.x) |x| {
                if (item.y) |y| {
                    try std.testing.expect(y == 12);
                    try std.testing.expect(x == 24);
                }
            }
        }
        std.debug.print("\titer(all): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    // Iter one entity
    {
        for (array.items) |item| {
            if (item.z) |z| {
                try std.testing.expect(z == 13);
            }
        }
        std.debug.print("\titer(1): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    {
        while (array.items.len > 0)
            _ = array.swapRemove(0);
        std.debug.print("\tremove all: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }
}

pub fn benchMultiArrayList() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const Entity = struct {
        x: ?u128 = null,
        y: ?u256 = null,
        z: ?u128 = null,
    };

    var timer = try std.time.Timer.start();
    var array = std.MultiArrayList(Entity){};
    try array.setCapacity(allocator, ecs.max_entities);
    defer array.deinit(allocator);
    std.debug.print("\tinit: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Create entities
    _ = timer.lap();
    for (0..(ecs.max_entities - 1)) |_| {
        array.appendAssumeCapacity(.{ .x = 24, .y = 12 });
    }
    array.appendAssumeCapacity(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});

    // Iter over entities
    {
        for (array.items(.x), array.items(.y)) |x, y| {
            try std.testing.expect(y.? == 12);
            try std.testing.expect(x.? == 24);
        }
        std.debug.print("\titer(all): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    // Iter one entity
    {
        for (array.items(.z)) |z| {
            if (z) |found| {
                try std.testing.expect(found == 13);
            }
        }
        std.debug.print("\titer(1): {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }

    {
        while (array.len > 0)
            _ = array.swapRemove(0);
        std.debug.print("\tremove all: {d}ms\n", .{@intToFloat(f32, timer.lap()) / 1000000.0});
    }
}
