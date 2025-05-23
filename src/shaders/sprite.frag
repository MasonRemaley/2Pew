#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_shading_language_include : require

#include "sprite.glsl"
#include "convert.glsl"

layout(scalar, binding = 1) readonly buffer InstanceUbo {
    Instance instances[];
};

layout(binding = 2) uniform sampler2D textures[];

layout(location = 0) in vec2 texcoord;
layout(location = 1) in flat Instance instance;

layout(location = 0) out vec4 out_color;

void main() {
    switch (instance.mat) {
        case MatTex: {
            out_color = texture(textures[nonuniformEXT(instance.mat_ex)], texcoord);
        } break;
        case MatSolid: {
            out_color = unormToVec4(instance.mat_ex);
        } break;
        default: {
            // Error color
            out_color = vec4(1, 0, 1, 1);
        } break;
    }
}
