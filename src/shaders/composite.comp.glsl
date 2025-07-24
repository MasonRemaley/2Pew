#include "interface.glsl"

const uvec3 pp_c_local_size = uvec3(16, 16, 1);
#define PP_C_DSIZE(image_size) (uvec3){ \
    divCeil(image_size.x, pp_c_local_size.x), \
    divCeil(image_size.y, pp_c_local_size.y), \
    1 \
}

#ifdef GL_COMPUTE_SHADER
    #include <gbms/noise.glsl>
    #include <gbms/sd.glsl>

    #define COLOR_BUFFER i_rt_storage_image_rba8_r[i_push_args[0]]
    #define BLURRED sampler2D(i_rt_texture[i_push_args[1]], i_linear_sampler)
    #define COMPOSITE i_rt_storage_image_any_w[i_push_args[2]]

    layout(
        local_size_x = pp_c_local_size.x,
        local_size_y = pp_c_local_size.y,
        local_size_z = pp_c_local_size.z
    ) in;

    void main() {
        // Get the sample coordinate
        ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
        uvec2 image_size = imageSize(COMPOSITE);
        #if RUNTIME_SAFETY
            if (imageSize(COMPOSITE) != imageSize(COLOR_BUFFER)) {
                imageStore(COMPOSITE, coord, vec4(1, 0, 1, 1));
                return;
            }
        #endif
        if (coord.x >= image_size.x || coord.y >= image_size.y) return;

        // Render target info
        f32 ar = f32(image_size.x) / f32(image_size.y);

        // Sample the center of the image
        vec3 center = imageLoad(COLOR_BUFFER, coord).rgb;

        // Load the blurred color buffer for bloom
        vec3 bloom = texture(BLURRED, vec2(coord) / vec2(image_size)).rgb;

        // Vignette effect
        f32 vignette = sdSample(sdCircle(coord - vec2(image_size) * 0.5, 0.3 * max(image_size.x, image_size.y)), max(image_size.x, image_size.y));

        // Noise effect
        f32 noise_scalar = 1920 / 4;
        noise_scalar = min(noise_scalar, image_size.x);
        noise_scalar = min(noise_scalar, image_size.y);
        vec2 noise_scale = vec2(noise_scalar);
        if (image_size.x > image_size.y) {
            noise_scale.x *= ar;
        } else {
            noise_scale.y /= ar;
        }
        noise_scale /= image_size;
        f32 noise_hz = 60;
        f32 noise_amp = rand(vec3(floor(noise_scale * coord), round(noise_hz * i_scene.timer.seconds)));
        vec3 noise = vec3(0.01 * mix(-1, 1, noise_amp));
        noise.r *= 0.8;

        // CRT effect
        f32 crt = mix(1.0, 0.8, step(mod(floor(remap(0, image_size.y, 0, 540/2, coord.y)), 2), 0));

        // Final composite
        imageStore(COMPOSITE, coord, vec4(((center + noise) * crt + bloom * 0.15) * vignette, 1));
    }
#endif
