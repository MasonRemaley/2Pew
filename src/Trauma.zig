//! Tracks trauma values. Typically expressed to players as screen shake and controller rumble.
//!
//! Typical usage involves a single instance of `Trauma`, however, if different effects need
//! different configuration (e.g. different max or attack times) you may want to create multiple
//! instances and take the max of each intensity before applying.

const std = @import("std");
const zcs = @import("zcs");
const tween = zcs.ext.geom.tween;
const smootherstep = tween.ease.smootherstep;

/// How many seconds a max intensity impulse lasts.
max_s: f32 = 1.3,
/// Seconds to reach max intensity trauma. Valid values range from 0 to infinity, longer attacks
/// will prevent the intensity from catching up to the max level before it falls off.
attack_s: f32 = 0.02,
/// Human interpretation of effects like screen shake tends to be nonlinear, this exponent corrects
/// for this. Good values tend to range between 2 and 3, you should tune this so that major medium
/// and minor trauma are easily distinguishable.
exp: f32 = 2.0,

/// Seconds until current trauma is resolved. You generally don't want to use this value directly
/// as it's not scaled for max time and doesn't have the attack or perceptual curve applied.
current_s: f32 = 0,
/// Current linear intensity. Prefer `intensity` for most uses which applies a perceptual curve.
intensity_linear: f32 = 0,

/// Adds major trauma. See `add`.
pub fn addMajor(self: @This()) void {
    self.add(3.0 / 3.0);
}

/// Adds medium trauma. See `add`.
pub fn addMedium(self: @This()) void {
    self.add(2.0 / 3.0);
}

/// Adds minor trauma. See `add`.
pub fn addMinor(self: @This()) void {
    self.add(1.0 / 3.0);
}

/// Sets major trauma. See `set`.
pub fn setMajor(self: @This()) void {
    self.set(3.0 / 3.0);
}

/// Sets medium trauma. See `set`.
pub fn setMedium(self: @This()) void {
    self.set(2.0 / 3.0);
}

/// Sets minor trauma. See `set`.
pub fn setMinor(self: @This()) void {
    self.set(1.0 / 3.0);
}

/// Adds an impulse, intensity is clamped from 0 to 1. Larger impulses last longer, multiple
/// impulses accumulate.
pub fn add(self: *@This(), intensity_linear: f32) void {
    self.current_s = @min(
        self.current_s + self.max_s * std.math.clamp(intensity_linear, 0, 1),
        self.max_s,
    );
}

/// Similar to `add`, but without accumulation.
pub fn set(self: *@This(), intensity_linear: f32) void {
    self.current_s = @max(self.current_s, self.max_s * std.math.clamp(intensity_linear, 0, 1));
}

/// Updates internal state.
pub fn update(self: *@This(), delta_s: f32) void {
    const target_linear_intensity = self.current_s / self.max_s;
    self.intensity_linear = @min(
        self.intensity_linear + delta_s / (self.attack_s * self.max_s),
        target_linear_intensity,
    );
    self.current_s = @max(self.current_s - delta_s, 0.0);
}

/// Returns the current perceptual trauma intensity, ranges from 0 to 1.
pub fn intensity(self: *const @This()) f32 {
    return std.math.pow(f32, self.intensity_linear, self.exp);
}
