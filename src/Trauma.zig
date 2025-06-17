//! Tracks trauma values. Typically expressed to players as screen shake, controller rumble, or
//! haptic feedback.
//!
//! Typical usage involves a single instance of `Trauma`, however, if different effects need
//! different configuration (e.g. different max or attack times) you may want to create multiple
//! instances and take the max of each intensity before applying.

const std = @import("std");
const zcs = @import("zcs");
const tween = zcs.ext.geom.tween;
const smootherstep = tween.ease.smootherstep;

/// Some outputs for trauma such as rumble differentiate between low and high frequency trauma.
pub const Frequency = enum {
    low,
    high,
};

/// A channel of trauma data.
pub const Channel = struct {
    /// Seconds until current trauma is resolved. You generally don't want to use this value
    /// directly as it's not scaled for max time and doesn't have the attack or perceptual curve
    /// applied.
    s: f32 = 0,
    /// Current linear intensity. Prefer `Trauma.intensity` for most uses, it applies a perceptual
    /// curve.
    linear_intensity: f32 = 0,
};

/// Trauma options.
pub const Options = struct {
    /// How many seconds a max intensity impulse lasts.
    max_s: f32 = 1.3,
    /// Seconds to reach max intensity trauma. Valid values range from 0 to infinity, longer attacks
    /// will prevent the intensity from catching up to the max level before it falls off.
    attack_s: f32 = 0.02,
    /// Human interpretation of effects like screen shake tends to be nonlinear, this exponent corrects
    /// for this. Good values tend to range between 2 and 3, you should tune this so that major medium
    /// and minor trauma are easily distinguishable.
    exp: f32 = 2.0,
};

/// The set trauma options.
options: Options,
/// Per channel state.
channels: std.EnumArray(Frequency, Channel),

/// Initializes trauma.
pub fn init(options: Options) @This() {
    return .{
        .options = options,
        .channels = .initFill(.{}),
    };
}

/// Adds major trauma. See `add`.
pub fn addMajor(self: *@This(), frequency: Frequency) void {
    self.add(frequency, 3.0 / 3.0);
}

/// Adds medium trauma. See `add`.
pub fn addMedium(self: *@This(), frequency: Frequency) void {
    self.add(frequency, 2.0 / 3.0);
}

/// Adds minor trauma. See `add`.
pub fn addMinor(self: *@This(), frequency: Frequency) void {
    self.add(frequency, 1.0 / 3.0);
}

/// Sets major trauma. See `set`.
pub fn setMajor(self: *@This(), frequency: Frequency) void {
    self.set(frequency, 3.0 / 3.0);
}

/// Sets medium trauma. See `set`.
pub fn setMedium(self: *@This(), frequency: Frequency) void {
    self.set(frequency, 2.0 / 3.0);
}

/// Sets minor trauma. See `set`.
pub fn setMinor(self: *@This(), frequency: Frequency) void {
    self.set(frequency, 1.0 / 3.0);
}

/// Adds an impulse, intensity is clamped from 0 to 1. Larger impulses last longer, multiple
/// impulses accumulate.
pub fn add(self: *@This(), frequency: Frequency, linear_intensity: f32) void {
    const channel = self.channels.getPtr(frequency);
    channel.s = @min(
        channel.s + self.options.max_s * std.math.clamp(linear_intensity, 0, 1),
        self.options.max_s,
    );
}

/// Similar to `add`, but without accumulation.
pub fn set(self: *@This(), frequency: Frequency, linear_intensity: f32) void {
    const channel = self.channels.getPtr(frequency);
    channel.s = @max(channel.s, self.options.max_s * std.math.clamp(linear_intensity, 0, 1));
}

/// Updates internal state.
pub fn update(self: *@This(), delta_s: f32) void {
    for (&self.channels.values) |*channel| {
        const target_linear_intensity = channel.s / self.options.max_s;
        channel.linear_intensity = @min(
            channel.linear_intensity + delta_s / (self.options.attack_s * self.options.max_s),
            target_linear_intensity,
        );
        channel.s = @max(channel.s - delta_s, 0.0);
    }
}

/// Returns the current perceptual trauma intensity for the given channel, output ranges from 0 to
/// 1. If no channel is specified, the max of all channels is returned.
pub fn intensity(self: *const @This(), frequency_opt: ?Frequency) f32 {
    const linear_intensity = if (frequency_opt) |frequency| b: {
        break :b self.channels.get(frequency).linear_intensity;
    } else b: {
        var max: f32 = 0.0;
        for (self.channels.values) |channel| {
            max = @max(max, channel.linear_intensity);
        }
        break :b max;
    };
    return std.math.pow(f32, linear_intensity, self.options.exp);
}
