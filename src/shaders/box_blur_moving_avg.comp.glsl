#include "interface.glsl"

#define INPUT i_rt_storage_image_rba8_r[i_push_args[0]]
#define OUTPUT i_rt_storage_image_any_w[i_push_args[1]]

#define RADIUS i32(i_push_args[2])
#define HORIZONTAL bool(i_push_args[3])

const u32 block_width = 256;

layout(local_size_x = 1, local_size_y = 256, local_size_z = 1) in;

vec3 load(ivec2 p, i32 size) {
    p.x = clamp(p.x, 0, size);
    if (!HORIZONTAL) p = p.yx;
    return imageLoad(INPUT, p).rgb;
}

void store(ivec2 p, vec4 color) {
    if (!HORIZONTAL) p = p.yx;
    imageStore(OUTPUT, p, color);
}

void main() {
    ivec2 left = ivec2(gl_GlobalInvocationID.xy) * ivec2(block_width, 1);
    i32 size = HORIZONTAL ? imageSize(OUTPUT).x : imageSize(OUTPUT).y;
    if (left.x > size) return;

    vec3 sum = vec3(0);
    for (i32 x = -RADIUS; x < RADIUS; ++x) {
        sum += load(left + ivec2(x, 0), size).rgb;
    }

    f32 divisor = 1.0f / (f32(RADIUS * 2) + 1.0);
    for (i32 x = 0; x < block_width; ++x) {
        if (left.x + x >= size) return;
        sum += load(left + ivec2(x + RADIUS, 0), size);
        store(left + ivec2(x, 0), vec4(sum * divisor, 1));
        sum -= load(left + ivec2(x - RADIUS, 0), size);
    }
}
