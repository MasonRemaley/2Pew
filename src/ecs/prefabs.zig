const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const EntityHandle = ecs.entities.Handle;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// XXX: add tests? what about for command buffer?
// XXX: reference notes, clean up diffs before merging
// XXX: consider supporting an escape hatch for components with unsupported types
// - could this work easily if we had both parent and child and sibling pointers to do a fix up where
// all you need in the data is parent since that's easiest? that'd work I think!!
// - consider that this changes the type of prefab since some types would be substituted out or removed
// etc
// - we could either allow subbing out components, or individual types. we also might wanna do this
// logic in a separate serialization namespace that allows us to input a serialized prefab and get
// out a live one. i think we should sub out whole components, at least for now--that's simplest,
// and types doesn't necessarily handle this since a component may not have a unique type and we
// might wanna do logic e.g. adding the sibling pointers and such?
// XXX: also could just init the entire ecs namespace instead of individual parts? doesn't even
// necessarily require changing other code since we can alias stuff etc...then again does that add
// coupling or no?
pub fn init(comptime Entities: type) type {
    const PrefabEntity = ecs.entities.PrefabEntity(Entities);

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
        /// patched. Asserts that spans covers all entities.
        pub fn instantiateSpans(temporary: Allocator, entities: *Entities, prefab: []PrefabEntity, spans: []Span) void {
            instantiateSpansChecked(temporary, entities, prefab, spans) catch |err|
                std.debug.panic("failed to instantiate prefab: {}", .{err});
        }

        pub fn instantiateSpansChecked(temporary: Allocator, entities: *Entities, prefab: []PrefabEntity, spans: []Span) Allocator.Error!void {
            // Instantiate the entities
            var live_handles = try temporary.alloc(EntityHandle, prefab.len);
            defer temporary.free(live_handles);
            for (prefab, 0..) |prefab_entity, i| {
                // XXX: why does skipping deserialzie result in type that's double escaped..?
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

        // XXX: do we also need a temporary allocator? or can we like allocate both and then free the
        // last one and have that work if it's a fixed buffer allocator? But we might wanna reserve
        // that space up front, etc. We'll figure it out once we get the basics working!
        // XXX: checked and unchecked variants?
        // XXX: make this take a const pointer to entiteis (iterator doesn't allow it yet, but should
        // if mutable is always false!)
        pub fn serialize(allocator: Allocator, entities: *Entities) Allocator.Error![]PrefabEntity {
            var serialized = try ArrayListUnmanaged(PrefabEntity).initCapacity(allocator, entities.len());
            errdefer serialized.deinit(allocator);

            var index_map = try allocator.alloc(EntityHandle.Index, entities.handles.slots.items.len);
            defer allocator.free(index_map);

            // Serialize each entity
            {
                comptime var descriptor = ecs.entities.IteratorDescriptor(Entities){};
                inline for (Entities.component_names) |comp_name| {
                    @field(descriptor, comp_name) = .{ .optional = true };
                }
                var iter = entities.iterator(descriptor);
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
            for (serialized.items) |*serialized_entity| {
                // XXX: use this instead of component_names? Or is there a less weird way that
                // doesn't support types we don't need it to?
                inline for (comptime std.meta.tags(Entities.ComponentTag)) |component_tag| {
                    if (@field(serialized_entity, @tagName(component_tag))) |*component| {
                        visitHandles(
                            index_map,
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

        fn serializeHandle(index_map: []const EntityHandle.Index, handle: *EntityHandle) void {
            handle.index = index_map[handle.index];
            handle.generation = .invalid;
        }

        fn deserializeHandle(live_handles: []const EntityHandle, handle: *EntityHandle) void {
            // XXX: this should be an error if we're in self contained mode!
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
