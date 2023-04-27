const std = @import("std");
const ecs = @import("index.zig");

// XXX: maybe move the renumbering code here too but allow streaming it? does that make any sense? do
// we need to renumber when saving from inside of the ecs? I guess so? how does that work?
// XXX: we probably SHOULD actually implement serialization here to make sure we understand the problem
// space (even if that just means feeding to the builtin json serializer or whatever for now! it should
// be decoupled for that so tbh that's a better test than writing out own where we could make it special
// or something.)
pub fn Serializer(comptime Entities: type, comptime Substitutions: anytype) type {
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
            pub fn FieldType(comptime tag: Entities.ComponentTag, comptime Type: type) type {
                if (findMap(tag)) |map| {
                    return ?@typeInfo(@TypeOf(map.serialize)).Fn.return_type.?;
                } else {
                    return ?Type;
                }
            }

            pub fn default_value(comptime _: Entities.ComponentTag, comptime _: type) ?*const anyopaque {
                return &null;
            }

            pub fn skip(comptime _: Entities.ComponentTag) bool {
                return false;
            }
        });

        pub fn serializeComponent(
            comptime componentTag: Entities.ComponentTag,
            component: ComponentType(componentTag),
        ) SerializedComponentType(componentTag) {
            if (findMap(componentTag)) |map| {
                return map.serialize(component);
            } else {
                return component;
            }
        }

        pub fn deserializeComponent(
            comptime componentTag: Entities.ComponentTag,
            serializedComponent: SerializedComponentType(componentTag),
        ) ComponentType(componentTag) {
            if (findMap(componentTag)) |map| {
                return map.deserialize(serializedComponent);
            } else {
                return serializedComponent;
            }
        }

        fn ComponentType(componentTag: Entities.ComponentTag) type {
            return @typeInfo(@field(ecs.entities.PrefabEntity, @tagName(componentTag))).Optional.child;
        }

        fn SerializedComponentType(componentTag: Entities.ComponentTag) type {
            return @typeInfo(@field(Entity, @tagName(componentTag))).Optional.child;
        }

        fn findMap(comptime componentTag: Entities.ComponentTag) ?type {
            inline for (@typeInfo(@TypeOf(Substitutions)).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(componentTag))) {
                    return @field(Substitutions, @tagName(componentTag));
                }
            }
            return null;
        }
    };
}
