#include "interface.glsl"

const uvec3 pp_lc_local_size = uvec3(16, 16, 1);
#define PP_LC_DSIZE(image_size) (uvec3){ \
    divCeil(image_size.x, pp_lc_local_size.x), \
    divCeil(image_size.y, pp_lc_local_size.y), \
    1 \
}

#if defined(GL_COMPUTE_SHADER)
    #include <gbms/unpack.glsl>

    layout(
        local_size_x = pp_lc_local_size.x,
        local_size_y = pp_lc_local_size.y,
        local_size_z = pp_lc_local_size.z
    ) in;

    #define MAX_RADIUS 14

    #define INPUT i_rt_texture[i_push_args[0]]
    #define OUTPUT i_rt_storage_image_any_w[i_push_args[1]]
    #define HORIZONTAL bool(i_push_args[2] == 1)
    #define RADIUS u32(i_push_args[3])
    #define WEIGHT(i) u32BitsToF32(i_push_args[4 + i])
    #define OFFSET(i) u32BitsToF32(i_push_args[4 + MAX_RADIUS + i]);

    #define SAMPLER(tex) sampler2D(tex, i_linear_sampler)

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
        for (u32 i = 1; i < MAX_RADIUS; ++i) {
            f32 offset = OFFSET(i);
            color += load(coord + offset * dir, size) * WEIGHT(i);
            color += load(coord - offset * dir, size) * WEIGHT(i);
            if (i >= RADIUS) break;
        }

        imageStore(OUTPUT, coord, vec4(color, 1));
    }
#endif
