#include <gbms/unpack.glsl>
#include <gbms/srgb.glsl>
#include <gbms/sd.glsl>

#include "descs/ecs.glsl"

layout(location = 0) in vec2 texcoord;
layout(location = 1) in flat Entity entity;

layout(location = 0) out vec4 color_buffer;

void main() {
    uvec2 diffuse_recolor = unpackShort2x16(entity.diffuse_recolor);
    uint diffuse_idx = diffuse_recolor.x;
    uint recolor_idx = diffuse_recolor.y;

    vec4 diffuse = vec4(1.0);
    if (diffuse_idx != TexNone) {
        diffuse = texture(sampler2D(textures[nonuniform(diffuse_idx)], texture_sampler), texcoord);
    }

    float recolor = diffuse.a;
    if (recolor_idx != TexNone) {
        recolor *= texture(sampler2D(textures[nonuniform(recolor_idx)], texture_sampler), texcoord).r;
    }

    vec4 color = unpackUnorm4x8(entity.color);
    color_buffer = mix(diffuse, diffuse * color, recolor);
    color_buffer.rgb = linearToSrgb(color_buffer.rgb);
}
