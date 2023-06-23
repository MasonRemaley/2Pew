const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const EntityHandle = ecs.entities.Handle;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub fn init(comptime Entities: type) type {
    const PrefabEntity = Entities.PrefabEntity;

    return struct {
        /// A handle whose generation is invalid and whose index is relative to the start of the
        /// prefab.
        pub const Handle = struct {
            relative: EntityHandle,

            pub fn init(index: EntityHandle.Index) Handle {
                return .{
                    .relative = .{
                        .index = index,
                        .generation = .invalid,
                    },
                };
            }
        };

        /// A piece of a prefab.
        pub const Span = struct {
            /// The number of prefab entities in this span.
            len: usize,

            /// True if handles are relative to the start of this span, false if they're relative to
            /// the start of this prefab.
            self_contained: bool,
        };

        pub const InstantiateError = Allocator.Error || DeserializeHandleError;

        pub fn instantiate(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []const PrefabEntity) void {
            return instantiateSpans(
                temporary,
                entities,
                prefab,
                &[_]Span{.{
                    .len = prefab.len,
                    .self_contained = self_contained,
                }},
            );
        }

        pub fn instantiateChecked(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []const PrefabEntity) InstantiateError!void {
            return instantiateSpansChecked(
                temporary,
                entities,
                prefab,
                &[_]Span{.{
                    .len = prefab.len,
                    .self_contained = self_contained,
                }},
            );
        }

        /// Instantiate a prefab. Handles are assumed to be relative to the start of the prefab, and will be
        /// patched. If safety checks are enabled, asserts that spans cover all entities and are not out of
        /// bounds. Temporarily allocates an array of `EntityHandle`s the length of the prefabs.
        pub fn instantiateSpans(temporary: Allocator, entities: *Entities, prefab: []const PrefabEntity, spans: []const Span) void {
            instantiateSpansChecked(temporary, entities, prefab, spans) catch |err|
                std.debug.panic("failed to instantiate prefab: {}", .{err});
        }

        pub fn instantiateSpansChecked(temporary: Allocator, entities: *Entities, prefab: []const PrefabEntity, spans: []const Span) InstantiateError!void {
            // Instantiate the entities
            var live_handles = try temporary.alloc(EntityHandle, prefab.len);
            defer temporary.free(live_handles);
            for (prefab, 0..) |prefab_entity, i| {
                live_handles[i] = try entities.createChecked(prefab_entity);
            }

            // Patch the handles
            var i: usize = 0;
            for (spans) |span| {
                if (std.math.maxInt(@TypeOf(i)) -| span.len < i) {
                    std.debug.panic("prefab span overflow", .{});
                }
                const span_live_handles = live_handles[i .. i + span.len];
                for (span_live_handles) |live_handle| {
                    inline for (comptime std.meta.tags(Entities.ComponentTag)) |component_tag| {
                        if (entities.getComponent(live_handle, component_tag)) |component| {
                            const context = DeserializeContext{
                                .live_handles = if (span.self_contained)
                                    span_live_handles
                                else
                                    live_handles,
                                .self_contained = span.self_contained,
                            };
                            try visitHandles(
                                DeserializeHandleError,
                                context,
                                component,
                                @tagName(component_tag),
                                deserializeHandle,
                            );
                        }
                    }
                }
                i += span.len;
            }
            assert(i == prefab.len);
        }

        /// See `serializeChecked`.
        pub fn serialize(allocator: Allocator, entities: *const Entities) []PrefabEntity {
            return serializeChecked(allocator, entities) catch |err|
                std.debug.panic("serialize failed: {}", .{err});
        }

        /// Serializes all entities. This is an unfinished proof of concept: in reality the caller
        /// should be able to conctrol the memory allocation more directly, and they should be able
        /// to decide which entities to serialize. This probably involves a lower level interface
        /// by which they perform the iteration, add entities one at a time, and then call a
        /// finalize function that does the patch. We would likely also want to check that there are
        /// no outside references during finalize, and error if there are, or null them out.
        ///
        /// Alternatively if we really do want to serialize everything, patching is not actually
        /// necessary if we're willing to serialize holes.
        pub fn serializeChecked(allocator: Allocator, entities: *const Entities) Allocator.Error![]PrefabEntity {
            var serialized = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, entities.len());
            errdefer serialized.deinit(allocator);

            var index_map = try allocator.alloc(EntityHandle.Index, entities.handles.slots.items.len);
            defer allocator.free(index_map);

            // Serialize each entity
            {
                comptime var descriptor = Entities.IteratorDescriptor{};
                inline for (Entities.component_names) |comp_name| {
                    @field(descriptor, comp_name) = .{ .optional = true };
                }
                var iter = entities.constIterator(descriptor);
                while (iter.next()) |entity| {
                    var serialized_entity: PrefabEntity = undefined;
                    inline for (Entities.component_names) |comp_name| {
                        @field(serialized_entity, comp_name) = if (@field(entity, comp_name)) |comp|
                            comp.*
                        else
                            null;
                    }
                    index_map[iter.handle().index] = @intCast(EntityHandle.Index, serialized.items.len);
                    serialized.appendAssumeCapacity(serialized_entity);
                }
            }

            // Patch the handles
            const context = SerializeContext{
                .index_map = index_map,
                .entities = entities,
            };
            for (serialized.items) |*serialized_entity| {
                inline for (comptime std.meta.tags(Entities.ComponentTag)) |component_tag| {
                    if (@field(serialized_entity, @tagName(component_tag))) |*component| {
                        try visitHandles(
                            error{},
                            context,
                            component,
                            @tagName(component_tag),
                            serializeHandle,
                        );
                    }
                }
            }

            // Return the result
            return serialized.items;
        }

        const SerializeContext = struct {
            index_map: []const EntityHandle.Index,
            entities: *const Entities,
        };

        fn serializeHandle(context: SerializeContext, handle: *EntityHandle) error{}!void {
            if (context.entities.exists(handle.*)) {
                handle.* = .{
                    .index = context.index_map[handle.index],
                    .generation = .invalid,
                };
            } else {
                handle.generation = .none;
            }
        }

        const DeserializeContext = struct {
            live_handles: []const EntityHandle,
            self_contained: bool,
        };

        pub const DeserializeHandleError = error{ OutOfBounds, ExpectedSelfContained };

        fn deserializeHandle(context: DeserializeContext, handle: *EntityHandle) DeserializeHandleError!void {
            switch (handle.generation) {
                // We don't need to patch it if it's empty
                .none => {},
                // If it's currently invalid, patch it
                .invalid => {
                    // Panic if we're out of bounds
                    if (handle.index >= context.live_handles.len) {
                        return error.OutOfBounds;
                    }

                    // Apply the patch
                    handle.* = context.live_handles.ptr[handle.index];
                },
                // We don't need to patch it if it's pointing to a live entity, but this should
                // fail in self contained mode
                _ => if (context.self_contained) {
                    return error.ExpectedSelfContained;
                },
            }
        }

        fn unsupportedType(
            comptime component_name: []const u8,
            comptime ty: type,
            comptime desc: []const u8,
        ) noreturn {
            @compileError("prefabs do not support " ++ desc ++ ", but component `" ++ component_name ++ "` contains `" ++ @typeName(ty) ++ "`");
        }

        fn visitHandles(
            comptime Error: type,
            context: anytype,
            value: anytype,
            comptime component_name: []const u8,
            cb: fn (@TypeOf(context), *EntityHandle) Error!void,
        ) Error!void {
            if (@TypeOf(value.*) == EntityHandle) {
                return cb(context, value);
            }

            switch (@typeInfo(@TypeOf(value.*))) {
                // Ignore
                .Type,
                .Void,
                .Bool,
                .NoReturn,
                .Int,
                .Float,
                .ComptimeFloat,
                .ComptimeInt,
                .Undefined,
                .Null,
                .ErrorUnion,
                .ErrorSet,
                .Enum,
                .EnumLiteral,
                => {},

                // Recurse
                .Optional => if (value.*) |*inner| try visitHandles(Error, context, inner, component_name, cb),
                .Array => for (value) |*item| try visitHandles(Error, context, item, component_name, cb),
                .Struct => |s| inline for (s.fields) |field| {
                    try visitHandles(Error, context, &@field(value.*, field.name), component_name, cb);
                },
                .Union => |u| if (u.tag_type) |Tag| {
                    inline for (u.fields) |field| {
                        if (@field(Tag, field.name) == @as(Tag, value.*)) {
                            try visitHandles(Error, context, &@field(value.*, field.name), component_name, cb);
                        }
                    }
                } else {
                    unsupportedType(component_name, @TypeOf(value.*), "untagged unions");
                },

                // Give up
                .AnyFrame,
                .Frame,
                .Fn,
                .Opaque,
                .Pointer,
                => unsupportedType(component_name, @TypeOf(value.*), "pointers"),

                // We only support numerical vectors
                .Vector => |vector| switch (vector.child) {
                    .Int, .Float => {},
                    _ => unsupportedType(component_name, @TypeOf(value.*), "pointers"),
                },
            }
        }
    };
}

test "basic instantiate" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .a = u8,
        .b = u8,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);
    const Span = prefabs.Span;

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    prefabs.instantiate(
        allocator,
        &entities,
        true,
        &[_]PrefabEntity{
            .{ .a = 10 },
            .{ .a = 20 },
            .{ .a = 30 },
        },
    );

    prefabs.instantiate(
        allocator,
        &entities,
        false,
        &[_]PrefabEntity{
            .{ .a = 40 },
            .{ .a = 50 },
            .{ .a = 60 },
        },
    );

    prefabs.instantiateSpans(
        allocator,
        &entities,
        &[_]PrefabEntity{
            .{ .a = 70 },
            .{ .a = 80 },
            .{ .a = 90 },
            .{ .a = 100 },
            .{ .a = 110 },
            .{ .a = 120 },
        },
        &[_]Span{
            .{
                .len = 3,
                .self_contained = true,
            },
            .{
                .len = 3,
                .self_contained = false,
            },
        },
    );

    var iter = entities.iterator(.{ .a = .{} });
    var i: u8 = 1;
    while (iter.next()) |next| {
        try expectEqual(next.a.*, i * 10);
        i += 1;
    }
    try expectEqual(iter.next(), null);
}

test "patch all handles" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Handles = struct {
        handle: EntityHandle,
        optional: ?EntityHandle,
        array: [1]EntityHandle,
        @"struct": struct { field: EntityHandle },
        @"union": union(enum) { variant: EntityHandle },
    };

    const Entities = ecs.entities.Entities(.{
        .handles = Handles,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    prefabs.instantiate(
        allocator,
        &entities,
        true,
        &[_]PrefabEntity{
            .{
                .handles = .{
                    .handle = .{ .index = 0, .generation = .invalid },
                    .optional = .{ .index = 0, .generation = .invalid },
                    .array = [1]EntityHandle{
                        .{ .index = 0, .generation = .invalid },
                    },
                    .@"struct" = .{
                        .field = .{ .index = 0, .generation = .invalid },
                    },
                    .@"union" = .{
                        .variant = .{ .index = 0, .generation = .invalid },
                    },
                },
            },
        },
    );

    var iter = entities.iterator(.{ .handles = .{} });
    var handles = iter.next().?.handles.*;
    try expectEqual(iter.next(), null);

    var expected = EntityHandle{ .index = 0, .generation = @enumFromInt(EntityHandle.Generation, 0) };
    try expectEqual(handles.handle, expected);
    try expectEqual(handles.optional.?, expected);
    try expectEqual(handles.array[0], expected);
    try expectEqual(handles.@"struct".field, expected);
    try expectEqual(handles.@"union".variant, expected);
}

test "basic patch" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);
    const PrefabHandle = prefabs.Handle;
    const Span = prefabs.Span;

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    // Test self contained
    {
        // Create some entities so the patch actually has to adjust the index
        _ = entities.create(.{});
        _ = entities.create(.{});
        _ = entities.create(.{});

        prefabs.instantiate(
            allocator,
            &entities,
            true,
            &[_]PrefabEntity{
                .{
                    .other = PrefabHandle.init(1).relative,
                },
                .{
                    .other = PrefabHandle.init(0).relative,
                },
            },
        );

        var iter = entities.iterator(.{ .other = .{} });
        var entity_0_other = iter.next().?.other.*;
        var entity_0 = iter.handle();
        var entity_1_other = iter.next().?.other.*;
        var entity_1 = iter.handle();
        try expectEqual(iter.next(), null);

        try expectEqual(entity_0_other, entity_1);
        try expectEqual(entity_1_other, entity_0);

        entities.clearRetainingCapacity();
    }

    // Test not self contained
    {
        // Create some entities so the patch actually has to adjust the index
        _ = entities.create(.{});
        _ = entities.create(.{});
        _ = entities.create(.{});

        prefabs.instantiate(
            allocator,
            &entities,
            true,
            &[_]PrefabEntity{
                .{
                    .other = PrefabHandle.init(1).relative,
                },
                .{
                    .other = PrefabHandle.init(0).relative,
                },
            },
        );

        var iter = entities.iterator(.{ .other = .{} });
        var entity_0_other = iter.next().?.other.*;
        var entity_0 = iter.handle();
        var entity_1_other = iter.next().?.other.*;
        var entity_1 = iter.handle();
        try expectEqual(iter.next(), null);

        try expectEqual(entity_0_other, entity_1);
        try expectEqual(entity_1_other, entity_0);

        entities.clearRetainingCapacity();
    }

    // Test mixed
    {
        // Create some entities so the patch actually has to adjust the index
        _ = entities.create(.{});
        _ = entities.create(.{});
        _ = entities.create(.{});

        prefabs.instantiateSpans(
            allocator,
            &entities,
            &[_]PrefabEntity{
                // Not self contained
                .{
                    .other = PrefabHandle.init(1).relative,
                },
                .{
                    .other = PrefabHandle.init(2).relative,
                },

                // Self contained
                .{
                    .other = PrefabHandle.init(1).relative,
                },
                .{
                    .other = PrefabHandle.init(0).relative,
                },
            },
            &[_]Span{
                .{
                    .len = 2,
                    .self_contained = false,
                },
                .{
                    .len = 2,
                    .self_contained = true,
                },
            },
        );

        var iter = entities.iterator(.{ .other = .{} });
        var entity_0_other = iter.next().?.other.*;
        var entity_1_other = iter.next().?.other.*;
        var entity_1 = iter.handle();
        var entity_2_other = iter.next().?.other.*;
        var entity_2 = iter.handle();
        var entity_3_other = iter.next().?.other.*;
        var entity_3 = iter.handle();
        try expectEqual(iter.next(), null);

        try expectEqual(entity_0_other, entity_1);
        try expectEqual(entity_1_other, entity_2);
        try expectEqual(entity_2_other, entity_3);
        try expectEqual(entity_3_other, entity_2);

        entities.clearRetainingCapacity();
    }
}

test "out of bounds" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);
    const PrefabHandle = prefabs.Handle;
    const Span = prefabs.Span;

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    try expectEqual(prefabs.instantiateChecked(
        allocator,
        &entities,
        true,
        &[_]PrefabEntity{
            .{
                .other = PrefabHandle.init(1).relative,
            },
        },
    ), error.OutOfBounds);

    try expectEqual(prefabs.instantiateSpansChecked(
        allocator,
        &entities,
        &[_]PrefabEntity{
            .{
                .other = PrefabHandle.init(1).relative,
            },
            .{},
        },
        &[_]Span{
            .{
                .len = 1,
                .self_contained = true,
            },
            .{
                .len = 1,
                .self_contained = true,
            },
        },
    ), error.OutOfBounds);
}

test "not self contained" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    // So we're not pointing at index 0
    _ = entities.create(.{});
    _ = entities.create(.{});
    _ = entities.create(.{});

    const entity = entities.create(.{});

    prefabs.instantiate(
        allocator,
        &entities,
        false,
        &[_]PrefabEntity{
            .{
                .other = entity,
            },
        },
    );

    var iter = entities.iterator(.{ .other = .{} });
    try expectEqual(iter.next().?.other.*, entity);
    try expectEqual(iter.next(), null);

    try expectEqual(prefabs.instantiateChecked(
        allocator,
        &entities,
        true,
        &[_]PrefabEntity{
            .{
                .other = entity,
            },
        },
    ), error.ExpectedSelfContained);
}

test "none handles" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;

    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    prefabs.instantiate(
        allocator,
        &entities,
        true,
        &[_]PrefabEntity{
            .{
                .other = EntityHandle.none,
            },
        },
    );

    prefabs.instantiate(
        allocator,
        &entities,
        false,
        &[_]PrefabEntity{
            .{
                .other = .{ .index = 20, .generation = .none },
            },
        },
    );

    var iter = entities.iterator(.{ .other = .{} });
    try expectEqual(iter.next().?.other.*, EntityHandle.none);
    try expectEqual(iter.next().?.other.*, .{ .index = 20, .generation = .none });
    try expectEqual(iter.next(), null);
}

test "fixed alloc" {
    const expectEqual = std.testing.expectEqual;
    var allocator = std.testing.allocator;
    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
    });
    const PrefabEntity = Entities.PrefabEntity;
    const prefabs = ecs.prefabs.init(Entities);
    const PrefabHandle = prefabs.Handle;
    const Span = prefabs.Span;

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    var buffer: [6 * @sizeOf(EntityHandle)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    prefabs.instantiateSpans(
        fba.allocator(),
        &entities,
        &[_]PrefabEntity{
            .{
                .other = EntityHandle.none,
            },
            .{
                .other = PrefabHandle.init(0).relative,
            },
            .{},
            .{
                .other = EntityHandle.none,
            },
            .{
                .other = PrefabHandle.init(1).relative,
            },
            .{},
        },
        &[_]Span{
            .{
                .len = 2,
                .self_contained = true,
            },
            .{
                .len = 1,
                .self_contained = false,
            },
            .{
                .len = 3,
                .self_contained = true,
            },
        },
    );

    // Make sure that when using a fixed buffer allocator, we don't go over the documented limit, and are
    // succesfully freed before returning! (Remember that order of frees matters for a fixed buffer allocator.)
    try expectEqual(fba.end_index, 0);
}

test "serialize" {
    const expectEqual = std.testing.expectEqual;
    const expect = std.testing.expect;
    var allocator = std.testing.allocator;
    const Entities = ecs.entities.Entities(.{
        .other = EntityHandle,
        .c = u8,
    });
    const prefabs = ecs.prefabs.init(Entities);

    var entities = try Entities.init(allocator);
    defer entities.deinit();

    var temp = entities.create(.{});
    entities.swapRemove(temp);
    const e5 = entities.create(.{
        .c = 4,
        .other = temp,
    });
    const e0 = entities.create(.{});
    const e1 = entities.create(.{
        .c = 123,
    });
    const e2 = entities.create(.{
        .other = e1,
        .c = 2,
    });
    const e3 = entities.create(.{
        .other = e2,
    });
    const e4 = entities.create(.{
        .c = 3,
    });

    _ = e0;
    _ = e3;
    _ = e4;
    _ = e5;

    var serialized = prefabs.serialize(allocator, &entities);
    defer allocator.free(serialized);

    try expectEqual(serialized.len, 6);
    var found = [_]bool{false} ** 6;
    for (serialized) |e| {
        if (e.other == null and e.c == null) {
            found[0] = true;
            continue;
        }

        if (e.c != null and e.c.? == 123 and e.other == null) {
            found[1] = true;
            continue;
        }

        if (e.c != null and e.c.? == 2 and e.other != null) {
            try expectEqual(e.other.?.generation, .invalid);
            try expectEqual(serialized[e.other.?.index].c.?, 123);
            try expectEqual(serialized[e.other.?.index].other, null);
            found[2] = true;
            continue;
        }

        if (e.c == null and e.other != null) {
            try expectEqual(e.other.?.generation, .invalid);
            try expectEqual(serialized[e.other.?.index].c.?, 2);
            try expect(serialized[e.other.?.index].other != null);
            found[3] = true;
            continue;
        }

        if (e.c != null and e.c.? == 3 and e.other == null) {
            found[4] = true;
            continue;
        }

        if (e.c != null and e.c.? == 4 and e.other != null) {
            try expectEqual(e.other.?.index, temp.index);
            try expectEqual(e.other.?.generation, .none);
            found[5] = true;
            continue;
        }

        unreachable;
    }
    for (found) |b| try expect(b);
}
