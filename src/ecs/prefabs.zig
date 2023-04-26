const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const EntityHandle = ecs.entities.Handle;

// XXX: add tests? what about for command buffer?
// XXX: reference notes, clean up diffs before merging
// XXX: consider supporting an escape hatch for components with unsupported types
pub fn init(comptime Entities: type) type {
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

        pub fn instantiate(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) void {
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

        pub fn instantiateChecked(temporary: Allocator, entities: *Entities, self_contained: bool, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) Allocator.Error!void {
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
        /// patched. Asserts that spans covers all entities.
        pub fn instantiateSpans(temporary: Allocator, entities: *Entities, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*)), spans: []Span) void {
            instantiateSpansChecked(temporary, entities, prefab, spans) catch |err|
                std.debug.panic("failed to instantiate prefab: {}", .{err});
        }

        pub fn instantiateSpansChecked(temporary: Allocator, entities: *Entities, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*)), spans: []Span) Allocator.Error!void {
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
                            const context = if (span.self_contained)
                                span_live_handles
                            else
                                live_handles;
                            visitHandles(context, component, @tagName(component_tag), patchHandle);
                        }
                    }
                }
                i += span.len;
            }
            assert(i == prefab.len);
        }

        fn patchHandle(live_handles: []const EntityHandle, handle: *EntityHandle) void {
            // Early out if we have a valid handle
            if (handle.generation != .invalid) return;

            // Panic if we're out of bounds
            if (handle.index >= live_handles.len) {
                std.debug.panic("bad index", .{});
            }

            // Apply the patch
            handle.* = live_handles.ptr[handle.index];
        }

        fn unsupportedType(
            comptime componentName: []const u8,
            comptime ty: type,
            comptime desc: []const u8,
        ) noreturn {
            @compileError("prefabs do not support " ++ desc ++ ", but component `" ++ componentName ++ "` contains `" ++ @typeName(ty) ++ "`");
        }

        fn visitHandles(
            context: anytype,
            value: anytype,
            comptime componentName: []const u8,
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
                .Optional => if (value.*) |*inner| visitHandles(context, inner, componentName, cb),
                .Array => for (value) |*item| visitHandles(context, item, componentName, cb),
                .Struct => |s| inline for (s.fields) |field| {
                    visitHandles(context, &@field(value.*, field.name), componentName, cb);
                },
                .Union => |u| if (u.tag_type) |Tag| {
                    inline for (u.fields) |field| {
                        if (@field(Tag, field.name) == @as(Tag, value.*)) {
                            visitHandles(context, &@field(value.*, field.name), componentName, cb);
                        }
                    }
                } else {
                    unsupportedType(componentName, @TypeOf(value.*), "untagged unions");
                },

                // Give up
                .AnyFrame,
                .Frame,
                .Fn,
                .Opaque,
                .Pointer,
                => unsupportedType(componentName, @TypeOf(value.*), "pointers"),

                // We only support numerical vectors
                .Vector => |vector| switch (vector.child) {
                    .Int, .Float => {},
                    _ => unsupportedType(componentName, @TypeOf(value.*), "pointers"),
                },
            }
        }
    };
}
