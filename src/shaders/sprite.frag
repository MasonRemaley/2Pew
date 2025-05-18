#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 2) uniform sampler2D textures[];
layout(location = 0) out vec4 out_color;

layout(location = 0) in flat uint instance_index;
layout(location = 1) in vec2 texcoord;

void main() {
    // %10 since we're just kinda picking random ones right now
    out_color = texture(textures[nonuniformEXT(instance_index % 10)], texcoord);
}
