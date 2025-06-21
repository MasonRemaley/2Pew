#include <gbms/srgb.glsl>
#include <gbms/noise.glsl>
#include <gbms/rand.glsl>
#include <gbms/sd.glsl>

#include "types/scene.glsl"

#include "descs/scene.glsl"
#include "descs/render_targets.glsl"

layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

void main() {
    // Render target info
    ivec2 rt_size = imageSize(render_targets[0]);
    float rt_ar = float(rt_size.x) / float(rt_size.y);

    // Take a sample at the center of the pixel
    vec3 center = srgbToLinear(imageLoad(render_targets[0], ivec2(texcoord * rt_size)).rgb);

    // Terrible bloom implementation, just using it to test out post processing
    vec3 bloom = center;
    const int size = 3;
    for (int x = -size; x <= size; ++x) {
        for (int y = -size; y <= size; ++y) {
            if (x != 0 || y != 0) {
                ivec2 coord = ivec2(ivec2(texcoord * rt_size) + ivec2(x, y));
                coord = clamp(coord, ivec2(0, 0), rt_size);
                bloom += srgbToLinear(imageLoad(render_targets[0], coord).rgb) * mix(1, 0, length(vec2(x, y)) / length(vec2(size)));
            }
        }
    }
    bloom *= 1.0 / float(size);

    // Quick vignette effect
    float vignette = sdSample(sdCircle(texcoord - vec2(0.5), 0.3), 0.8);
    vignette = remap(0, 1, 0.5, 1, vignette);

    // Quick noise effect
    vec2 noise_scale = vec2(rt_ar, 1.0) * 1080;
    float noise_hz = 60;
    float value_noise = valueNoise(
        vec3(noise_scale * texcoord, scene.timer.seconds * noise_hz),
        vec3(FLT_MAX_CONSEC, FLT_MAX_CONSEC, scene.timer.period * noise_hz)
    );
    vec3 noise = vec3(0.005 * mix(-1, 1, value_noise));
    noise.r *= 0.8;

    // Quick CRT effect
    float crt = mix(1.0, 0.8, step(mod(floor(texcoord.y * 540), 2), 0));

    // Final compositing
    out_color = vec4(linearToSrgb(((center + noise) * crt + bloom * 0.05) * vignette), 1);
}
