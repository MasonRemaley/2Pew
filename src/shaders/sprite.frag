#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_shading_language_include : require

#include "sprite.glsl"


layout(scalar, binding = 1) readonly buffer InstanceData {
    Instance instances[];
};

layout(binding = 2) uniform sampler2D textures[];

layout(location = 0) out vec4 out_color;

layout(location = 0) in flat uint instance_index;
layout(location = 1) in vec2 texcoord;

void main() {
    Instance instance = instances[instance_index];
    out_color = texture(textures[nonuniformEXT(instance.texture_index)], texcoord);
}
