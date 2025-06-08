#include "entity.glsl"
#include "scene.glsl"

layout(scalar, binding = 0) readonly buffer SceneUbo {
    Scene scene;
};
layout(scalar, binding = 1) readonly buffer InstanceUbo {
    Instance instances[];
};

layout(location = 0) out vec2 out_texcoord;
layout(location = 1) out flat Instance out_instance;

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
    Instance instance = instances[gl_InstanceIndex];
    vec2 model = vertices[gl_VertexIndex];
    vec2 world = vec3(model, 1.0) * instance.model_to_world;
    vec2 view = vec3(world, 1.0) * scene.world_to_view;

    gl_Position = vec4(view, 0.0, 1.0);
    out_texcoord = texcoords[gl_VertexIndex];
    out_instance = instance;
}
