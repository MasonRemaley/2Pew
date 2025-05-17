#version 450
#extension GL_ARB_shading_language_include : require

#include "material.glsl"

layout(location = 0) flat in uint instance_index;
layout(location = 1) in vec2 texcoord;

layout(location = 0) out vec4 out_color;

layout(binding = 3) readonly buffer Instances { MaterialInstancePacked instances[]; };
layout(binding = 4) readonly buffer ColorMaterial { vec3 color_material[]; };
layout(binding = 5) uniform sampler2D tex;

void blue() {
    out_color = vec4(0.0, 0.0, 1.0, 1.0);
}

void solid(MaterialInstance instance) {
    out_color = vec4(color_material[instance.data_u32], 1.0);
}

void textured(MaterialInstance instance) {
    out_color = texture(tex, texcoord);
}

void error() {
    out_color = vec4(1.0, 0.0, 1.0, 1.0);
}

void main() {
    MaterialInstance instance = materialUnpack(instances[instance_index]);
    switch (instance.material) {
        case 0: {
            blue();
        } break;
        case 1: {
            solid(instance);
        } break;
        case 2: {
            textured(instance);
        } break;
        default: {
            error();
        } break;
    }
}
