#include <gbms/unpack.glsl>
#include <gbms/srgb.glsl>
#include <gbms/sd.glsl>

#include "types/entity.glsl"

#include "descs/textures.glsl"
#include "descs/texture_sampler.glsl"

layout(location = 0) in vec2 texcoord;
layout(location = 1) in flat Entity entity;

layout(location = 0) out vec4 out_color;

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
    out_color = mix(diffuse, diffuse * color, recolor);
    out_color.rgb = linearToSrgb(out_color.rgb);
}
