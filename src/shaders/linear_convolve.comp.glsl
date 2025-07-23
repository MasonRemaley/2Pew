#include "interface.glsl"

#define MAX_RADIUS 14

#define INPUT i_rt_texture[i_push_args[0]]
#define OUTPUT i_rt_storage_image_any_w[i_push_args[1]]
#define HORIZONTAL bool(i_push_args[2] == 1)
#define RADIUS int(i_push_args[3])
#define WEIGHT(i) uintBitsToFloat(i_push_args[4 + i])
#define OFFSET(i) uintBitsToFloat(i_push_args[4 + MAX_RADIUS + i]);

#define SAMPLER(tex) sampler2D(tex, i_linear_sampler)

const uvec2 local_size = uvec2(16);

layout(local_size_x = local_size.x, local_size_y = local_size.y, local_size_z = 1) in;

vec3 load(vec2 coord, vec2 size) {
    return texture(SAMPLER(INPUT), (coord + vec2(0.5)) / size).rgb;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    uvec2 size = imageSize(OUTPUT);
     #if RUNTIME_SAFETY
        if (textureSize(SAMPLER(INPUT), 0) != size) {
            imageStore(OUTPUT, coord, vec4(1, 0, 1, 1));
            return;
        }
    #endif
    if (coord.x >= size.x || coord.y >= size.y) return;

    vec2 dir = HORIZONTAL ? vec2(1, 0) : vec2(0, 1);
    vec3 color = load(coord, size) * WEIGHT(0);
    for (int i = 1; i < MAX_RADIUS; ++i) {
        float offset = OFFSET(i);
        color += load(coord + offset * dir, size) * WEIGHT(i);
        color += load(coord - offset * dir, size) * WEIGHT(i);
        if (i >= RADIUS) break;
    }

    imageStore(OUTPUT, coord, vec4(color, 1));
}
