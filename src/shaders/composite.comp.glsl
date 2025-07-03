#include <gbms/srgb.glsl>
#include <gbms/noise.glsl>
#include <gbms/sd.glsl>

#include "interface.glsl"

#define COLOR_BUFFER i_rt_storage_image_rba8_r[i_push_args[0]]
#define BLURRED i_rt_storage_image_rba8_r[i_push_args[1]]
#define COMPOSITE i_rt_storage_image_any_w[i_push_args[2]]

const uvec2 local_size = uvec2(16);

layout(local_size_x = local_size.x, local_size_y = local_size.y, local_size_z = 1) in;

// XXX: wait how does shared workgroup memory work? okay I think I get it
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
    float ar = float(image_size.x) / float(image_size.y);

    // Sample the center of the image
    vec3 center = srgbToLinear(imageLoad(COLOR_BUFFER, coord).rgb);

    // Terrible bloom implementation, just using it to test out post processing
    // vec3 bloom = center;
    // const int bloom_size = 3;
    // for (int x = -bloom_size; x <= bloom_size; ++x) {
    //     for (int y = -bloom_size; y <= bloom_size; ++y) {
    //         if (x != 0 || y != 0) {
    //             ivec2 bc = coord + ivec2(x, y);
    //             bc = clamp(bc, ivec2(0, 0), ivec2(image_size));
    //             bloom += srgbToLinear(imageLoad(COLOR_BUFFER, bc).rgb) * mix(1, 0, length(vec2(x, y)) / length(vec2(bloom_size)));
    //         }
    //     }
    // }
    // bloom *= 1.0 / float(bloom_size);
    vec3 bloom = imageLoad(BLURRED, coord).rgb;

    // Vignette effect
    float vignette = sdSample(sdCircle(coord - vec2(image_size) * 0.5, 0.3 * max(image_size.x, image_size.y)), max(image_size.x, image_size.y));

    // Noise effect
    float noise_scalar = 1920 / 4;
    noise_scalar = min(noise_scalar, image_size.x);
    noise_scalar = min(noise_scalar, image_size.y);
    vec2 noise_scale = vec2(noise_scalar);
    if (image_size.x > image_size.y) {
        noise_scale.x *= ar;
    } else {
        noise_scale.y /= ar;
    }
    noise_scale /= image_size;
    float noise_hz = 60;
    float value_noise = valueNoise(
        vec3(noise_scale * coord, i_scene.timer.seconds * noise_hz),
        vec3(FLT_MAX_CONSEC, FLT_MAX_CONSEC, i_scene.timer.period * noise_hz)
    );
    vec3 noise = vec3(0.01 * mix(-1, 1, value_noise));
    noise.r *= 0.8;

    // CRT effect
    float crt = mix(1.0, 0.8, step(mod(floor(remap(0, image_size.y, 0, 540/2, coord.y)), 2), 0));

    // Final composite
    // XXX: ...
    imageStore(COMPOSITE, coord, vec4(linearToSrgb(((center + noise) * crt + bloom * 0.1) * vignette), 1));
    // imageStore(COMPOSITE, coord, vec4(linearToSrgb(center), 1));

    // XXX: blur test, probably also assert size correct once doing for real? or give up on that? could make a helper that
    // just asserts two images are the same but the issue is the "failure" is kinda implementation dependent also needs to be macro
    // to return etc though maybe there's a exit() or something idk
    // if (coord.x > image_size.x / 2) {
    //     imageStore(COMPOSITE, coord, imageLoad(BLURRED, coord));
    // } else {
    //     imageStore(COMPOSITE, coord, imageLoad(COLOR_BUFFER, coord));
    // }
}
