#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_shading_language_include : require

#include "sprite.glsl"
#include "unpack.glsl"

layout(scalar, binding = 1) readonly buffer InstanceUbo {
    Instance instances[];
};

layout(binding = 2) uniform sampler2D textures[];

layout(location = 0) in vec2 texcoord;
layout(location = 1) in flat Instance instance;

layout(location = 0) out vec4 out_color;

void main() {
    ivec2 diffuse_recolor = unpackUintToIVec2(instance.diffuse_recolor);
    uint diffuse_idx = diffuse_recolor.x;
    uint recolor_idx = diffuse_recolor.y;

    vec4 diffuse = vec4(1.0);
    if (diffuse_idx != TexNone) {
        diffuse = texture(textures[nonuniformEXT(diffuse_idx)], texcoord);
    }

    float recolor = diffuse.a;
    if (recolor_idx != TexNone) {
        recolor *= texture(textures[nonuniformEXT(recolor_idx)], texcoord).r;
    }

    // Rough SRGB approximation, should just do the exact math on the CPU instead
    vec4 color = pow(unpackUnormToVec4(instance.color), vec4(vec3(2.2), 1.0));
    out_color = mix(diffuse, diffuse * color, recolor);
}
