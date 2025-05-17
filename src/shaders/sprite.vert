#version 460
#extension GL_ARB_shading_language_include : require

#include "material.glsl"

struct RectMat {
    vec2 pos;
    vec2 size;
};

layout(location = 0) flat out uint instance_index;
layout(location = 1) out vec2 texcoord;

layout(binding = 0) readonly buffer CameraPosition { vec2 camera_position; };
layout(binding = 1) readonly buffer Instances { MaterialInstancePacked instances[]; };
layout(binding = 2) readonly buffer RectMats { RectMat rect_mats[]; };

const vec2 vertices[4] = vec2[](
    vec2(0, 0),
    vec2(1, 0),
    vec2(0, 1),
    vec2(1, 1)
);

void mesh(MaterialInstance instance) {
    RectMat rect = rect_mats[instance.data_u32];
    vec2 vertex = vertices[gl_VertexIndex];
    gl_Position = vec4(vertex * rect.size + rect.pos + camera_position, 0.0, 1.0);
    texcoord = vertex;
}

void error() {
    vec2 vertex = vertices[gl_VertexIndex % 4];
    gl_Position = vec4(vertices[gl_VertexIndex % 4], 0.0, 1.0);
    texcoord = vertex;
}

void main() {
    // Unpack the instance
    instance_index = gl_InstanceIndex;
    MaterialInstance instance = materialUnpack(instances[instance_index]);
    switch (instance.material) {
        case 0: {
            mesh(instance);
        } break;
        default: {
            error();
        } break;
    }
}
