const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const EntityHandle = ecs.entities.Handle;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// XXX: add tests? what about for command buffer?
// XXX: reference notes, clean up diffs before merging
// XXX: also could just init the entire ecs namespace instead of individual parts? doesn't even
// necessarily require changing other code since we can alias stuff etc...then again does that add
// coupling or no?
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

        pub fn instantiate(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []PrefabEntity) void {
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

        pub fn instantiateChecked(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []PrefabEntity) Allocator.Error!void {
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
        /// patched. Asserts that spans covers all entities. Temporarily allocates an array of `EntityHandles`
        /// the length of the prefabs.
        pub fn instantiateSpans(temporary: Allocator, entities: *Entities, prefab: []PrefabEntity, spans: []Span) void {
            instantiateSpansChecked(temporary, entities, prefab, spans) catch |err|
                std.debug.panic("failed to instantiate prefab: {}", .{err});
        }

        pub fn instantiateSpansChecked(temporary: Allocator, entities: *Entities, prefab: []PrefabEntity, spans: []Span) Allocator.Error!void {
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
                            visitHandles(
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
                        visitHandles(
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

        fn serializeHandle(context: SerializeContext, handle: *EntityHandle) void {
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

        fn deserializeHandle(context: DeserializeContext, handle: *EntityHandle) void {
            switch (handle.generation) {
                // We don't need to patch it if it's empty
                .none => {},
                // If it's currently invalid, patch it
                .invalid => {
                    // Panic if we're out of bounds
                    if (handle.index >= context.live_handles.len) {
                        std.debug.panic("bad index", .{});
                    }

                    // Apply the patch
                    handle.* = context.live_handles.ptr[handle.index];
                },
                // We don't need to patch it if it's pointing to a live entity, but this should
                // fail in self contained mode
                _ => if (context.self_contained) {
                    std.debug.panic("self contained prefab not self contained", .{});
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
            context: anytype,
            value: anytype,
            comptime component_name: []const u8,
            cb: fn (@TypeOf(context), *EntityHandle) void,
        ) void {
            if (@TypeOf(value.*) == EntityHandle) {
                cb(context, value);
                return;
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
                .Optional => if (value.*) |*inner| visitHandles(context, inner, component_name, cb),
                .Array => for (value) |*item| visitHandles(context, item, component_name, cb),
                .Struct => |s| inline for (s.fields) |field| {
                    visitHandles(context, &@field(value.*, field.name), component_name, cb);
                },
                .Union => |u| if (u.tag_type) |Tag| {
                    inline for (u.fields) |field| {
                        if (@field(Tag, field.name) == @as(Tag, value.*)) {
                            visitHandles(context, &@field(value.*, field.name), component_name, cb);
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

// XXX: tests:
// * [ ] look over all functions
// * [ ] test patching, including in nested types, maybe of multiple types
// * [ ] only test patching that's specific to command buffer though, if possible do it in that module instead!
// * [ ] maybe just the limits around prefabs vs prefab entities and whether self contained works right, minimally?
