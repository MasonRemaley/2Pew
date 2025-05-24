#ifndef INCLUDE_COLOR
#define INCLUDE_COLOR

float colorLinearToSrgb(float linear) {
    // The color component transfer function from the SRGB specification:
    // https://www.w3.org/Graphics/Color/srgb
    if (linear <= 0.031308) {
        return 12.92 * linear;
    } else {
        return 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
    }
}

vec3 colorLinearToSrgb(vec3 linear) {
    return vec3(
        colorLinearToSrgb(linear.r),
        colorLinearToSrgb(linear.g),
        colorLinearToSrgb(linear.b)
    );
}

vec4 colorLinearToSrgb(vec4 linear) {
    return vec4(
        colorLinearToSrgb(linear.r),
        colorLinearToSrgb(linear.g),
        colorLinearToSrgb(linear.b),
        linear.a
    );
}


float colorSrgbToLinear(float srgb) {
    // The inverse of the color component transfer function from the SRGB specification:
    // https://www.w3.org/Graphics/Color/srgb
    if (srgb <= 0.04045) {
        return srgb / 12.92;
    } else {
        return pow((srgb + 0.055) / 1.055, 2.4);
    }
}

vec3 colorSrgbToLinear(vec3 srgb) {
    return vec3(
        colorSrgbToLinear(srgb.r),
        colorSrgbToLinear(srgb.g),
        colorSrgbToLinear(srgb.b)
    );
}

vec4 colorSrgbToLinear(vec4 srgb) {
    return vec4(
        colorSrgbToLinear(srgb.r),
        colorSrgbToLinear(srgb.g),
        colorSrgbToLinear(srgb.b),
        srgb.a
    );
}

float colorUnormToFloat(float unorm) {
    // Multiplying by the reciprocal is faster than dividing by 255.0, but does not produce exact
    // results. By multiplying both the numerator and denominator by three, we get exact results for
    // the full possible range of inputs. This has been verified by looping over all inputs and
    // comparing the results to the exact form.
    return unorm * 3.0 * 1.0 / (3.0 * 255.0);
}

vec3 colorUnormToFloat(uvec3 unorm) {
    return vec3(
        colorUnormToFloat(unorm.r),
        colorUnormToFloat(unorm.g),
        colorUnormToFloat(unorm.b)
    );
}

vec4 colorUnormToFloat(uvec4 unorm) {
    return vec4(
        colorUnormToFloat(unorm.r),
        colorUnormToFloat(unorm.g),
        colorUnormToFloat(unorm.b),
        colorUnormToFloat(unorm.a)
    );
}

uint colorFloatToUnorm(float f) {
    return uint(f * 255.0 + 0.5);
}

uvec3 colorFloatToUnorm(vec3 f) {
    return uvec3(
        colorFloatToUnorm(f.r),
        colorFloatToUnorm(f.g),
        colorFloatToUnorm(f.b)
    );
}

uvec4 colorFloatToUnorm(vec4 f) {
    return uvec4(
        colorFloatToUnorm(f.r),
        colorFloatToUnorm(f.g),
        colorFloatToUnorm(f.b),
        colorFloatToUnorm(f.a)
    );
}

#endif
