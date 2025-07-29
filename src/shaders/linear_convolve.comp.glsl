#include "interface.glsl"

const uvec3 pp_lc_local_size = uvec3(16, 16, 1);
#define PP_LC_DSIZE(image_size) (uvec3){ \
    divCeil(image_size.x, pp_lc_local_size.x), \
    divCeil(image_size.y, pp_lc_local_size.y), \
    1 \
}

struct pp_lc_Pass {
    u32 input_rt_texture_index;
    u32 output_rt_storage_image_any_w_index;
    u32 horizontal;
};

TYPEDEF_STRUCT(pp_lc_Pass);

struct pp_lc_PushConstants {
    pp_lc_Pass pass;
    u32 radius;
    f32 weights[14];
    f32 offsets[14];
};

#if defined(GL_COMPUTE_SHADER)
    #include <gbms/unpack.glsl>

    layout(
        local_size_x = pp_lc_local_size.x,
        local_size_y = pp_lc_local_size.y,
        local_size_z = pp_lc_local_size.z
    ) in;

    #define MAX_RADIUS 14

    layout(scalar, push_constant) uniform PushConstants {
        pp_lc_PushConstants push_constants;
    };

    #define INPUT i_rt_texture[push_constants.pass.input_rt_texture_index]
    #define OUTPUT i_rt_storage_image_any_w[push_constants.pass.output_rt_storage_image_any_w_index]
    #define WEIGHT(i) u32BitsToF32(i_push_args[4 + i])
    #define OFFSET(i) u32BitsToF32(i_push_args[4 + MAX_RADIUS + i]);
    #define HORIZONTAL (push_constants.pass.horizontal != 0)

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
        vec3 color = load(coord, size) * push_constants.weights[0];
        for (u32 i = 1; i < MAX_RADIUS; ++i) {
            f32 offset = push_constants.offsets[i];
            color += load(coord + offset * dir, size) * push_constants.weights[i];
            color += load(coord - offset * dir, size) * push_constants.weights[i];
            if (i >= push_constants.radius) break;
        }

        imageStore(OUTPUT, coord, vec4(color, 1));
    }
#endif
