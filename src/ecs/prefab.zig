const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

const Allocator = std.mem.Allocator;
const Handle = ecs.entities.Handle;

// XXX: better to use 0 and initialize them to 1, so that changing the generation size doesn't mess with save data..?
pub const dummy_generation = std.math.maxInt(ecs.entities.Generation);

pub fn createHandle(index: ecs.entities.Index) Handle {
    return Handle{
        .index = index,
        .generation = dummy_generation,
    };
}

// XXX: make possible with command buffer!! can store a list of all the individual items, and a separate list
// - command buffer only kind of needs to know about parenting now? We could apply from game logic instead
// of prefab sizes (or store in a multiarray) and then should be able to just slice it and pass into here!
// and simplify a lot!
// See `instantiate`.
pub fn instantiateChecked(temporary: Allocator, entities: anytype, prefabs: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) Allocator.Error!void {
    const Entities = @TypeOf(entities.*);
    // Instantiate the prefabs
    var live_handles = try temporary.alloc(Handle, prefabs.len);
    defer temporary.free(live_handles);
    for (prefabs, 0..) |prefab, i| {
        live_handles[i] = try entities.createChecked(prefab);
    }

    // Patch the handles
    for (live_handles) |live_handle| {
        inline for (Entities.component_names, 0..) |component_name, i| {
            const componentTag = @intToEnum(Entities.ComponentTag, i);
            if (entities.getComponent(live_handle, componentTag)) |component| {
                visitHandles(live_handles, component, component_name, patchHandle);
            }
        }
    }
}

// Instantiates a list of prefabs. If the component data contains handles, the generations must be
// set to `dummy_generation`, and the indices are assumed to be indexes into the prefabs slice.
pub fn instantiate(temporary: Allocator, entities: anytype, prefabs: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) void {
    instantiateChecked(temporary, entities, prefabs) catch |err|
        std.debug.panic("failed to instantiate prefab: {}", .{err});
}

// XXX: make an easy way to generate the handles to fill this in with, can just be a struct called
// PrefabHandles or something that keeps returning new handles
fn visitHandles(context: anytype, value: anytype, comptime componentName: []const u8, visitHandle: fn (@TypeOf(context), *Handle) void) void {
    if (@TypeOf(value.*) == Handle) {
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

// XXX: support entities that are live via a reserved generation? kinda weird coupling between prefabs
// and this system though. e.g. if we reserve a none value whose to say the game logic doesn't actually
// want a none value sometimes? we could use invalid or something but like, how to document when it's appropriate
// to use it? i guess just like, never in game only for out of game data then there's no conflicts..sort of?
// we do want some way to do this--it'll be an annoying restriction if we can't!
fn patchHandle(live_handles: []const Handle, handle: *Handle) void {
    if (handle.generation != dummy_generation) std.debug.panic("bad generation", .{});
    if (handle.index > live_handles.len) std.debug.panic("bad index", .{});
    // XXX: we're doing the bounds checking above becuase doing it here would only happen in debug mode, right?
    handle.* = live_handles.ptr[handle.index];
}
