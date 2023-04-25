const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const EntityHandle = ecs.entities.Handle;

// XXX: better to use 0 and initialize them to 1, so that changing the generation size doesn't mess with save data..?
pub const dummy_generation = std.math.maxInt(ecs.entities.Generation);

/// A handle whose generation is `dummy_generation` and whose index is relative to the start of the
/// prefab.
pub const Handle = struct {
    relative: EntityHandle,

    pub fn init(index: ecs.entities.Index) Handle {
        return .{
            .relative = .{
                .index = index,
                .generation = dummy_generation,
            },
        };
    }
};

/// A piece of a prefab.
pub const Span = struct {
    /// The number of prefab entities in this span.
    len: usize,

    /// True if handles are relative to the start of this span, false if they're relative to the
    /// start of this prefab.
    self_contained: bool,
};

pub fn instantiate(temporary: Allocator, entities: anytype, self_contained: bool, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) void {
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

pub fn instantiateChecked(temporary: Allocator, entities: anytype, self_contained: bool, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) Allocator.Error!void {
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
pub fn instantiateSpans(temporary: Allocator, entities: anytype, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*)), spans: []Span) void {
    instantiateSpansChecked(temporary, entities, prefab, spans) catch |err|
        std.debug.panic("failed to instantiate prefab: {}", .{err});
}

// XXX: actually assert spans end at the right place...
// XXX: support entities that are live via a reserved generation? kinda weird coupling between prefabs
// and this system though. e.g. if we reserve a none value whose to say the game logic doesn't actually
// want a none value sometimes? we could use invalid or something but like, how to document when it's appropriate
// to use it? i guess just like, never in game only for out of game data then there's no conflicts..sort of?
// we do want some way to do this--it'll be an annoying restriction if we can't!
// XXX: do we need component_names when we can just use @tagName?
pub fn instantiateSpansChecked(temporary: Allocator, entities: anytype, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*)), spans: []Span) Allocator.Error!void {
    const Entities = @TypeOf(entities.*);

    // Instantiate the entities
    var live_handles = try temporary.alloc(EntityHandle, prefab.len);
    defer temporary.free(live_handles);
    for (prefab, 0..) |prefab_entity, i| {
        live_handles[i] = try entities.createChecked(prefab_entity);
    }

    // Patch the handles
    var i: ecs.entities.Index = 0; // XXX: type?
    for (spans) |span| {
        const span_live_handles = live_handles[i .. i + span.len]; // XXX: make sure this arithmetic can't out of bounds or overflow in release mode here either!
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
        i += @intCast(u20, span.len); // XXX: cast...
    }
    assert(i == prefab.len);
}

fn patchHandle(live_handles: []const EntityHandle, handle: *EntityHandle) void {
    if (handle.generation != dummy_generation) {
        std.debug.panic("bad generation", .{});
    }
    // XXX: this is bounds checked even in release mode right?
    handle.* = live_handles[handle.index];
}

// XXX: having this be a module that takes entities and returns a struct would be nice here...
// XXX: make an easy way to generate the handles to fill this in with, can just be a struct called
// PrefabHandles or something that keeps returning new handles
fn visitHandles(context: anytype, value: anytype, comptime componentName: []const u8, visitHandle: fn (@TypeOf(context), *EntityHandle) void) void {
    if (@TypeOf(value.*) == EntityHandle) {
        visitHandle(context, value);
        return;
    }

    // XXX: handled by the above right?
    // if (@typeInfo(@TypeOf(value)) != .Pointer) {
    //     @compileError("expected pointer to value");
    // }

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
        .Optional => if (value.*) |*inner| visitHandles(context, inner, componentName, visitHandle),
        .Array => for (value) |*item| visitHandles(context, item, componentName, visitHandle),
        .Struct => |s| inline for (s.fields) |field| {
            visitHandles(context, &@field(value.*, field.name), componentName, visitHandle);
        },

        // Give up
        // XXX: better message?
        .AnyFrame, .Frame, .Fn, .Opaque => @compileError("component " ++ componentName ++ " contains unsupported type " ++ @typeName(@TypeOf(value.*))),
        // XXX: ...
        .Pointer => {},
        // XXX: ...implement, make sure to check all variants comptime
        .Union => {},
        .Vector => |vector| switch (vector.child) {
            .Int, .Float => {},
            _ => @compileError("component " ++ componentName ++ " contains unsupported type " ++ @typeName(@TypeOf(value.*))),
        },
    }
}
