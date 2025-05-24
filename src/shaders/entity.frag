#include "entity.glsl"
#include "unpack.glsl"
#include "color.glsl"

layout(scalar, binding = 1) readonly buffer InstanceUbo {
    Instance instances[];
};

layout(binding = 2) uniform sampler2D textures[];

layout(location = 0) in vec2 texcoord;
layout(location = 1) in flat Instance instance;

layout(location = 0) out vec4 out_color;

void main() {
    uvec2 diffuse_recolor = unpackUintToUvec2(instance.diffuse_recolor);
    uint diffuse_idx = diffuse_recolor.x;
    uint recolor_idx = diffuse_recolor.y;

    vec4 diffuse = vec4(1.0);
    if (diffuse_idx != TexNone) {
        diffuse = texture(textures[nonuniform(diffuse_idx)], texcoord);
    }

    float recolor = diffuse.a;
    if (recolor_idx != TexNone) {
        recolor *= texture(textures[nonuniform(recolor_idx)], texcoord).r;
    }

    vec4 color = colorUnormToFloat(unpackUintToUvec4(instance.color));
    out_color = mix(diffuse, diffuse * color, recolor);
}
