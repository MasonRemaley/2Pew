const std = @import("std");
const builtin = @import("builtin");
const ecs = @import("ecs/index.zig");
const MinimumAlignmentAllocator = @import("minimum_alignment_allocator.zig").MinimumAlignmentAllocator;
const Entities = ecs.entities.Entities;
const EntityHandle = ecs.entities.Handle;

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
    var pa = std.heap.page_allocator;
    var buffer = try pa.alloc(u8, ecs.entities.max_entities * 1024);
    defer pa.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var maa = MinimumAlignmentAllocator(64).init(fba.allocator());
    const allocator = maa.allocator();

    // Init
    var timer = try std.time.Timer.start();
    var entities = try Entities(.{ .x = u128, .y = u256, .z = u128 }).init(allocator);

    defer entities.deinit();
    std.debug.print("\tinit: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Create entities
    for (0..(ecs.entities.max_entities - 1)) |_| {
        _ = entities.create(.{ .x = 24, .y = 12 });
    }
    _ = entities.create(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Iter over entities
    {
        var iter = entities.iterator(.{ .x = .{}, .y = .{} });
        while (iter.next()) |e| {
            try std.testing.expect(e.x.* == 24);
            try std.testing.expect(e.y.* == 12);
        }
        std.debug.print("\titer(all): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Iter one entity
    {
        var iter = entities.iterator(.{ .z = .{} });
        while (iter.next()) |e| {
            try std.testing.expect(e.z.* == 13);
        }
        std.debug.print("\titer(1): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    var all = std.ArrayList(EntityHandle).init(allocator);
    defer all.deinit();
    {
        var iter = entities.iterator(.{});
        while (iter.next()) |_| {
            try all.append(iter.handle());
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
    std.debug.print("\tgetComponent(all): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Removing components
    for (all.items) |entity| {
        entities.removeComponents(entity, .{.x});
    }
    std.debug.print("\tremoveComponents(all, .{{.x}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Adding components
    for (all.items, 0..) |entity, i| {
        entities.addComponents(entity, .{ .x = i });
    }
    std.debug.print("\taddComponents(all, .{{.x = i}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // XXX: profile removing from iterator too or instead?
    // Remove all entities
    for (all.items) |entity| {
        entities.swapRemove(entity);
    }
    std.debug.print("\tremove(all): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
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
    var array = try std.ArrayList(Entity).initCapacity(allocator, ecs.entities.max_entities);
    defer array.deinit();
    std.debug.print("\tinit: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Create entities
    _ = timer.lap();
    for (0..(ecs.entities.max_entities - 1)) |_| {
        array.appendAssumeCapacity(.{ .x = 24, .y = 12 });
    }
    array.appendAssumeCapacity(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

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
        std.debug.print("\titer(all): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Iter one entity
    {
        for (array.items) |item| {
            if (item.z) |z| {
                try std.testing.expect(z == 13);
            }
        }
        std.debug.print("\titer(1): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Remove components
    {
        for (array.items) |*item| {
            item.x = null;
        }
        std.debug.print("\tremoveComponents(all, .{{.x}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Add components
    {
        for (array.items, 0..) |*item, i| {
            item.x = i;
        }
        std.debug.print("\taddComponents(all, .{{.x = i}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Remove all
    {
        while (array.items.len > 0)
            _ = array.swapRemove(0);
        std.debug.print("\tremove all: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
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
    try array.setCapacity(allocator, ecs.entities.max_entities);
    defer array.deinit(allocator);
    std.debug.print("\tinit: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Create entities
    _ = timer.lap();
    for (0..(ecs.entities.max_entities - 1)) |_| {
        array.appendAssumeCapacity(.{ .x = 24, .y = 12 });
    }
    array.appendAssumeCapacity(.{ .x = 24, .y = 12, .z = 13 });
    std.debug.print("\tfill: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});

    // Iter over entities
    {
        for (array.items(.x), array.items(.y)) |x, y| {
            try std.testing.expect(y.? == 12);
            try std.testing.expect(x.? == 24);
        }
        std.debug.print("\titer(all): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Iter one entity
    {
        for (array.items(.z)) |z| {
            if (z) |found| {
                try std.testing.expect(found == 13);
            }
        }
        std.debug.print("\titer(1): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Remove components
    {
        for (array.items(.x)) |*x| {
            x.* = null;
        }
        std.debug.print("\tremoveComponents(all, .{{.x}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Add components
    {
        for (array.items(.x), 0..) |*x, i| {
            x.* = i;
        }
        std.debug.print("\taddComponents(all, .{{.x = i}}): {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }

    // Remove all
    {
        while (array.len > 0)
            _ = array.swapRemove(0);
        std.debug.print("\tremove all: {d}ms\n", .{@as(f32, @floatFromInt(timer.lap())) / 1000000.0});
    }
}
