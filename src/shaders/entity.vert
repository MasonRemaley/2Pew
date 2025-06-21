#include "types/scene.glsl"

#include "descs/scene.glsl"
#include "descs/entities.glsl"

layout(location = 0) out vec2 out_texcoord;
layout(location = 1) out flat Entity out_entity;

const vec2 vertices[4] = vec2[](
    vec2(0, 0),
    vec2(0, 1),
    vec2(1, 0),
    vec2(1, 1)
);

const vec2 texcoords[4] = vec2[](
    vec2(0, 1),
    vec2(0, 0),
    vec2(1, 1),
    vec2(1, 0)
);

void main() {
    Entity instance = entities[gl_InstanceIndex];
    vec2 model = vertices[gl_VertexIndex];
    vec2 world = vec3(model, 1.0) * instance.model_to_world;
    vec2 view = vec3(world, 1.0) * scene.world_to_view;
    vec2 projection = vec3(view, 1.0) * scene.view_to_projection;

    gl_Position = vec4(projection, 0.0, 1.0);
    out_texcoord = texcoords[gl_VertexIndex];
    out_entity = instance;
}
