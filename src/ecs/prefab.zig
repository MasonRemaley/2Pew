const std = @import("std");
const ecs = @import("index.zig");

const Allocator = std.mem.Allocator;
const AutoArrayHashMap = std.AutoArrayHashMap;
const Handle = ecs.entities.Handle;

pub fn Item(comptime Entities: type) type {
    return struct {
        handle: Handle,
        entity: ecs.entities.PrefabEntity(Entities),
    };
}

// XXX: make an easy way to generate the handles to fill this in with, can just be a struct called
// PrefabHandles or something that keeps returning new handles
pub fn Prefab(comptime Entities: type) type {
    return []Item(Entities);
}

pub fn visitHandles(context: anytype, value: anytype, comptime componentName: []const u8, visitHandle: fn (@TypeOf(context), *Handle) void) void {
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

fn patchHandle(handle_map: *const AutoArrayHashMap(Handle, Handle), handle: *Handle) void {
    if (handle_map.get(handle.*)) |live| {
        handle.* = live;
    }
}

// XXX: consider again making this whole module a function that returns the sepcialized module
// XXX: make possible with command buffer!! can store a list of all the individual items, and a separate list
// of prefab sizes (or store in a multiarray) and then should be able to just slice it and pass into here!
// XXX: return errors or no?
// XXX: make the fact that we ALLOW missing handles (missing from prefab AND from entities potentially)
// more robust by making a specific generation for prefab handles?
// XXX: assert that entities is a pointer?
// XXX: flip this around to only put the stuff that's needed into the hashmap? then again
// we need the list of instnatiated entities to iterate over at the end right?? but if so like can we skip
// anything that doesn't hae a handle there? or can we skip if none do? etc, don't wanna pay for this unless
// using it...
// XXX: OMG we don't need a hashmap lol, it's contiguous numbers, just store them that way. When making a save file
// that does require renumbering then..or going through and finding the max so we can leave holes. We can figure that out
// when we get there. Honestly if loading a save file can just load everything into the exact same handles or something
// and skip all the patching etc. Problem is building the free list but like we could build or just save that lol.
// that is more fragile of course cause it requires everything stay the same but yeah. We could make a mode that
// uses a hashmap if needed for that. We could also just renumber it's probably not a big deal? Can check perf of various
// options then--it's not as if the hashmap is free, even just renumbering during load is probably equiavlent to hashmap but can
// be done on save OR load depending on preference.
pub fn instantiate(temporary: Allocator, entities: anytype, prefabs: Prefab(@TypeOf(entities.*))) !void {
    const Entities = @TypeOf(entities.*);

    // XXX: array hashmap vs just hashmap?
    // XXX: also consider a simpler hashing function or no? Or use arrays, prealloc somehow?
    // XXX: prealloc to be big enough
    // Create the scratch data
    var handle_map = AutoArrayHashMap(Handle, Handle).init(temporary);
    defer handle_map.deinit();
    try handle_map.ensureTotalCapacity(prefabs.len);

    // Create the entities
    for (prefabs) |prefab_item| {
        var live_handle = entities.create(prefab_item.entity);
        handle_map.putAssumeCapacity(prefab_item.handle, live_handle);
    }

    // Patch the handles
    for (handle_map.values()) |live_handle| {
        inline for (Entities.component_names, 0..) |component_name, i| {
            const componentTag = @intToEnum(Entities.ComponentTag, i);
            if (entities.getComponent(live_handle, componentTag)) |component| {
                visitHandles(&handle_map, component, component_name, patchHandle);
            }
        }
    }
}
