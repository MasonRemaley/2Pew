const std = @import("std");
const ecs = @import("index.zig");

// XXX: maybe move the renumbering code here too but allow streaming it? does that make any sense? do
// we need to renumber when saving from inside of the ecs? I guess so? how does that work?
// XXX: we probably SHOULD actually implement serialization here to make sure we understand the problem
// space (even if that just means feeding to the builtin json serializer or whatever for now! it should
// be decoupled for that so tbh that's a better test than writing out own where we could make it special
// or something.)
pub fn Serializer(comptime Entities: type, comptime Substitutions: anytype) type {
    const ComponentTag = Entities.ComponentTag;
    const PrefabEntity = ecs.entities.PrefabEntity(Entities); // XXX: ... naming?

    // Make sure the component mapper does not have any unused maps
    inline for (@typeInfo(@TypeOf(Substitutions)).Struct.fields) |field| {
        inline for (Entities.component_names) |component_name| {
            if (std.mem.eql(u8, field.name, component_name)) {
                break;
            }
        } else {
            @compileError("`Substitutions` contains field for non-existent component `" ++ field.name ++ "`");
        }
    }

    // Create the serializer
    return struct {
        pub const Entity = ecs.entities.ComponentMap(Entities, .Auto, struct {
            pub fn FieldType(comptime tag: ComponentTag, comptime Type: type) type {
                if (findMap(tag)) |map| {
                    return ?@typeInfo(@TypeOf(map.serialize)).Fn.return_type.?;
                } else {
                    return ?Type;
                }
            }

            pub fn default_value(comptime _: ComponentTag, comptime _: type) ?*const anyopaque {
                return &null;
            }

            pub fn skip(comptime _: ComponentTag) bool {
                return false;
            }
        });

        // XXX: naming, if we allow doing multiple then it makes sense I think, otherwise just name deserialize
        // XXX: make the reverse, and allow doing for ALL entities and renumbering or whatever? individual
        // ones do no renumbering? should they visit handles and set valid or anything? or always done
        // seprately in loop etc? document too!
        // XXX: right now we call this on instantation. alternatively, we could call it when queuing up the
        // prefab. think about the tradeoffs at some point.
        pub fn deserializeEntity(entity: Entity) PrefabEntity {
            var result: PrefabEntity = undefined;
            inline for (Entities.component_names, 0..) |component_name, i| {
                const component_tag = @intToEnum(ComponentTag, i);
                const component = @field(entity, component_name);
                @field(result, component_name) = if (component) |comp|
                    serializeComponent(component_tag, comp)
                else
                    null;
            }
            return result;
        }

        fn serializeComponent(
            comptime componentTag: ComponentTag,
            component: ComponentType(componentTag),
        ) SerializedComponentType(componentTag) {
            if (findMap(componentTag)) |map| {
                return map.serialize(component);
            } else {
                return component;
            }
        }

        fn deserializeComponent(
            comptime componentTag: ComponentTag,
            serializedComponent: SerializedComponentType(componentTag),
        ) ComponentType(componentTag) {
            if (findMap(componentTag)) |map| {
                return map.deserialize(serializedComponent);
            } else {
                return serializedComponent;
            }
        }

        fn ComponentType(comptime componentTag: ComponentTag) type {
            return @typeInfo(@TypeOf(@field(PrefabEntity{}, @tagName(componentTag)))).Optional.child;
        }

        fn SerializedComponentType(comptime componentTag: ComponentTag) type {
            return @typeInfo(@TypeOf(@field(Entity{}, @tagName(componentTag)))).Optional.child;
        }

        fn findMap(comptime componentTag: ComponentTag) ?type {
            inline for (@typeInfo(@TypeOf(Substitutions)).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(componentTag))) {
                    return @field(Substitutions, @tagName(componentTag));
                }
            }
            return null;
        }
    };
}
