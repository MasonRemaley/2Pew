#include "interface.glsl"

#define INPUT i_rt_texture[i_push_args[0]]
#define OUTPUT i_rt_storage_image_any_w[i_push_args[1]]
#define DIST i_push_args[2]

#define SAMPLER(tex) sampler2D(tex, i_linear_sampler)

const uvec2 local_size = uvec2(16);

layout(local_size_x = local_size.x, local_size_y = local_size.y, local_size_z = 1) in;

vec3 load(ivec2 coord, vec2 size) {
    return texture(SAMPLER(INPUT), vec2(coord)/size).rgb;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    uvec2 size = imageSize(OUTPUT);
    if (coord.x >= size.x || coord.y >= size.y) return;

    vec3 color = vec3(0);
    color += load(coord + ivec2(-int(DIST) + 0, +int(DIST) + 1), size) * 0.25;
    color += load(coord + ivec2(+int(DIST) + 1, +int(DIST) + 1), size) * 0.25;
    color += load(coord + ivec2(-int(DIST) + 0, -int(DIST) + 0), size) * 0.25;
    color += load(coord + ivec2(+int(DIST) + 1, -int(DIST) + 0), size) * 0.25;

    imageStore(OUTPUT, coord, vec4(color, 1));
}
