//! Wrapper around SDL's rumble API.
//!
//! SDL's rumble API expects rumble events with fixed intensities and finite lengths. Using these
//! directly feels bad, a good rumble should fall off over time. Instead, you're better off breaking
//! up your rumbles into small events with varying intensities.
//!
//! You could just send a new rumble event every frame, but this is a bad idea for the same reason
//! that you wouldn't play audio without a buffer. In theory new events cancel old ones so you could
//! just extend the length, but sending this many events is a bit goofy and in practice the
//! cancelling doesn't work well on some Linux drivers if you're sending them out at a high rate
//! (e.g. 120hz if the player has a high refresh rate monitor.)
//!
//! Instead, we opt to synchronize the rumble state at a fixed frequency likely much lower than the
//! rate at which the game is rendering.

const c = @import("c.zig");

/// The size of a packet of rumble data in seconds.
///
/// I've tested 60hz and it appears to work fine, but I've set the default to a much more reasonable
/// 10hz. It's unlikely you'll feel the latency or notice the quantization in the rumble curve at
/// this rate since rumble is very chaotic and is a relatively "slow" effect perceptually.
packet_s: f32 = 0.1,

/// How much time elapsed since the last sync.
last_sync_s: f32 = 0.0,

const State = struct {
    /// The gamepad for this player, or null if none.
    gamepad: ?*c.SDL_Gamepad,
    /// The intensity of the current rumble, from 0 to 1.
    intensity: f32,
};

pub fn update(
    self: *@This(),
    gamepads: []?*c.SDL_Gamepad,
    intensities: []const f32,
    delta_s: f32,
) void {
    if (self.last_sync_s > self.packet_s) {
        for (gamepads, intensities) |maybe_gamepad, intensity| {
            if (maybe_gamepad) |gamepad| {
                // We opt to always emit the high frequency at 1/8th the magnitude of the low
                // frequency. This feels good on a recent Xbox controller, but we could opt to
                // expose both fields separately if desired.
                const low_freq: u16 = @intFromFloat(intensity * @as(f32, @floatFromInt(0xFFFF)));
                const high_freq: u16 = low_freq / 8;

                // We make the packet twice as long as it needs to be to give us extra buffer. Our
                // next packet will cancel this one if it's received in time.
                const length_s = self.packet_s * 2;

                // Emit the rumble packet.
                _ = c.SDL_RumbleGamepad(
                    gamepad,
                    low_freq,
                    high_freq,
                    @intFromFloat(length_s * 1000),
                );
            }
        }
        self.last_sync_s = 0.0;
    } else {
        self.last_sync_s += delta_s;
    }
}
