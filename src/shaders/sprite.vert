#version 460
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_shading_language_include : require

#include "sprite.glsl"


layout(scalar, binding = 0) readonly buffer SceneUbo {
    Scene scene;
};
layout(scalar, binding = 1) readonly buffer InstanceUbo {
    Instance instances[];
};

layout(location = 0) out flat uint instance_index;
layout(location = 1) out vec2 texcoord;

const vec2 vertices[4] = vec2[](
    vec2(-0.5, -0.5),
    vec2(-0.5, 0.5),
    vec2(0.5, -0.5),
    vec2(0.5, 0.5)
);

const vec2 texcoords[4] = vec2[](
    vec2(0, 0),
    vec2(0, 1),
    vec2(1, 0),
    vec2(1, 1)
);

void main() {
    Instance instance = instances[gl_InstanceIndex];
    vec2 model = vertices[gl_VertexIndex];
    vec2 world = vec3(model, 1.0) * instance.model_to_world;
    vec2 view = vec3(world, 1.0) * scene.world_to_view;
    gl_Position = vec4(view, 0.0, 1.0);
    instance_index = gl_InstanceIndex;
    texcoord = texcoords[gl_VertexIndex];
}
