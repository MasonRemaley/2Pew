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
        return pow((srgb + 0.055) / (1.055), 2.4);
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
