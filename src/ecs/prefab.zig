const std = @import("std");
const ecs = @import("index.zig");
const slot_map = @import("../slot_map.zig");

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

/// Instantiate a prefab. Handles are assumed to be relative to the start of the prefab, and will be
/// patched.
pub fn instantiate(temporary: Allocator, entities: anytype, prefabs: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) void {
    instantiateChecked(temporary, entities, prefabs) catch |err|
        std.debug.panic("failed to instantiate prefab: {}", .{err});
}

pub fn instantiateChecked(temporary: Allocator, entities: anytype, prefab: []ecs.entities.PrefabEntity(@TypeOf(entities.*))) Allocator.Error!void {
    const Entities = @TypeOf(entities.*);
    // Instantiate the prefabs
    var live_handles = try temporary.alloc(EntityHandle, prefab.len);
    defer temporary.free(live_handles);
    for (prefab, 0..) |prefab_entity, i| {
        live_handles[i] = try entities.createChecked(prefab_entity);
    }

    // Patch the handles
    for (live_handles) |live_handle| {
        inline for (Entities.component_names, 0..) |component_name, i| {
            const componentTag = @intToEnum(Entities.ComponentTag, i);
            if (entities.getComponent(live_handle, componentTag)) |component| {
                visitHandles(
                    live_handles,
                    component,
                    component_name,
                    struct {
                        // XXX: support entities that are live via a reserved generation? kinda weird coupling between prefabs
                        // and this system though. e.g. if we reserve a none value whose to say the game logic doesn't actually
                        // want a none value sometimes? we could use invalid or something but like, how to document when it's appropriate
                        // to use it? i guess just like, never in game only for out of game data then there's no conflicts..sort of?
                        // we do want some way to do this--it'll be an annoying restriction if we can't!
                        fn patchHandle(live: []const EntityHandle, handle: *EntityHandle) void {
                            if (handle.generation != dummy_generation) std.debug.panic("bad generation", .{});
                            if (handle.index > live.len) std.debug.panic("bad index", .{});
                            // XXX: we're doing the bounds checking above becuase doing it here would only happen in debug mode, right?
                            // Also see the one other place we do this!
                            handle.* = live.ptr[handle.index];
                        }
                    }.patchHandle,
                );
            }
        }
    }
}

// XXX: having this be a module that takes entities and returns a struct would be nice here...
// XXX: we could do this while instantiating them, but, I'd need to find a way to store the list of
// ranges to sandbox etc. this IS annoying though, because it means that we need the data to be
// mutable. At the very least just have an optional sandbox flag to instntiate or an
// instantiateSandboxed or such that does this streaming?
// Offsets all handles in the prefab by the given amount, and asserts that none point outside of
// the prefab. This allows composing prefabs stored as constants or in files.
pub fn sandbox(prefab: anytype, offset: ecs.entities.Index) void {
    const Sandbox = struct {
        offset: ecs.entities.Index,
        len: usize,
    };

    for (prefab) |*prefab_entity| {
        inline for (@typeInfo(@TypeOf(prefab_entity.*)).Struct.fields) |field| {
            if (@field(prefab_entity, field.name)) |*component| {
                visitHandles(
                    .{ .offset = offset, .len = prefab.len },
                    component,
                    field.name,
                    struct {
                        fn sandboxHandle(sb: Sandbox, handle: *EntityHandle) void {
                            if (handle.generation != dummy_generation) std.debug.panic("bad generation", .{});
                            // XXX: is this the right way to check for out of bounds including in release mode?
                            handle.index +|= sb.offset;
                            if (handle.index >= sb.len) std.debug.panic("bad index", .{});
                        }
                    }.sandboxHandle,
                );
            }
        }
    }
}

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
