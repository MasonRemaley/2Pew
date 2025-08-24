#include "interface.glsl"

const u32 pp_bbma_chunk_width = 256;
const uvec3 pp_bbma_ls = uvec3(1, 256, 1);
#define PP_BBMA_DSIZE(image_size) (uvec3){ \
    divCeil(image_size.x, pp_bbma_chunk_width), \
    divCeil(image_size.y, pp_bbma_ls.y), \
    1 \
}

struct pp_bbma_PushConstants {
    u32 input_rt_storage_image_rba8_r_index;
    u32 output_rt_storage_image_any_w;
    i32 radius;
    u32 horizontal;
};

#define HORIZONTAL (push_constants.horizontal != 0)

#if defined(GL_COMPUTE_SHADER)
    layout(
        local_size_x = pp_bbma_ls.x,
        local_size_y = pp_bbma_ls.y,
        local_size_z = pp_bbma_ls.z
    ) in;

    layout(scalar, push_constant) uniform PushConstants {
        pp_bbma_PushConstants push_constants;
    };

    #define INPUT i_rt_storage_image_rba8_r[push_constants.input_rt_storage_image_rba8_r_index]
    #define OUTPUT i_rt_storage_image_any_w[push_constants.output_rt_storage_image_any_w]

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
        ivec2 left = ivec2(gl_GlobalInvocationID.xy) * ivec2(pp_bbma_chunk_width, 1);
        i32 size = HORIZONTAL ? imageSize(OUTPUT).x : imageSize(OUTPUT).y;
        if (left.x > size) return;

        vec3 sum = vec3(0);
        for (i32 x = -push_constants.radius; x < push_constants.radius; ++x) {
            sum += load(left + ivec2(x, 0), size).rgb;
        }

        f32 divisor = 1.0f / (f32(push_constants.radius * 2) + 1.0);
        for (i32 x = 0; x < pp_bbma_chunk_width; ++x) {
            if (left.x + x >= size) return;
            sum += load(left + ivec2(x + push_constants.radius, 0), size);
            store(left + ivec2(x, 0), vec4(sum * divisor, 1));
            sum -= load(left + ivec2(x - push_constants.radius, 0), size);
        }
    }
#endif
