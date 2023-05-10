const std = @import("std");
const c = @import("c.zig");

const EnumArray = std.EnumArray;

pub fn init(comptime ActionT: type) type {
    return struct {
        pub const Action = ActionT;

        pub const Direction = enum {
            positive,
            negative,
        };

        pub const Phase = enum {
            activated,
            active,
            deactivated,
            inactive,
        };

        pub const InputState = struct {
            pub const ActionState = EnumArray(Direction, Phase);
            pub const ActionStates = EnumArray(Action, ActionState);

            action_states: ActionStates,

            pub fn init() @This() {
                return .{
                    .action_states = ActionStates.initFill(ActionState.initFill(.inactive)),
                };
            }

            pub fn update(self: *@This()) void {
                for (&self.action_states.values) |*action_state| {
                    inline for (@typeInfo(Direction).Enum.fields) |field| {
                        const direction = @intToEnum(Direction, field.value);
                        const phase = action_state.getPtr(direction);
                        switch (phase.*) {
                            .activated => phase.* = .active,
                            .deactivated => phase.* = .inactive,
                            .active, .inactive => {},
                        }
                    }
                }
            }

            pub fn applyControlScheme(self: *@This(), control_scheme: *const ControlScheme, controllers: []?*c.SDL_GameController) void {
                inline for (comptime std.meta.tags(Action)) |action| {
                    inline for (@typeInfo(Direction).Enum.fields) |field| {
                        const direction = @intToEnum(Direction, field.value);

                        // Check if the keyboard or controller control is activated
                        const keyboard_action = @field(control_scheme.keyboard_scheme, @tagName(action));
                        const key = if (@field(keyboard_action, @tagName(direction))) |key|
                            c.SDL_GetKeyboardState(null)[key] == 1
                        else
                            false;

                        var button = false;
                        var axis = false;
                        if (control_scheme.controller_index) |controller_index| {
                            const controller_action = @field(control_scheme.controller_scheme, @tagName(action));

                            if (@field(controller_action.buttons, @tagName(direction))) |button_control| {
                                button = c.SDL_GameControllerGetButton(controllers[controller_index], button_control) != 0;
                            }

                            if (controller_action.axis) |axis_control| {
                                const value = c.SDL_GameControllerGetAxis(controllers[controller_index], axis_control.axis);
                                switch (direction) {
                                    .positive => axis = value > axis_control.dead_zone,
                                    .negative => axis = value < -axis_control.dead_zone,
                                }
                            }
                        }

                        // Update the current state
                        if (key or button or axis) {
                            self.startAction(action, direction);
                        } else {
                            self.finishAction(action, direction);
                        }
                    }
                }
            }

            pub fn isAction(
                self: *const @This(),
                action: Action,
                direction: Direction,
                compatible_phase: Phase,
            ) bool {
                const current_state = switch (direction) {
                    .positive => self.action_states.get(action).get(.positive),
                    .negative => self.action_states.get(action).get(.negative),
                };
                return switch (compatible_phase) {
                    .active => current_state == .active or current_state == .activated,
                    .activated => current_state == .activated,
                    .inactive => current_state == .inactive or current_state == .deactivated,
                    .deactivated => current_state == .deactivated,
                };
            }

            pub fn getAxis(self: *const @This(), action: Action) f32 {
                // TODO(mason): make most recent input take precedence on keyboard?
                return @intToFloat(f32, @boolToInt(self.isAction(action, .positive, .active))) -
                    @intToFloat(f32, @boolToInt(self.isAction(action, .negative, .active)));
            }

            pub fn setAction(self: *@This(), action: Action, direction: Direction, phase: Phase) void {
                self.action_states.getPtr(action).getPtr(direction).* = phase;
            }

            pub fn startAction(self: *@This(), action: Action, direction: Direction) void {
                const current_state = self.action_states.getPtr(action).getPtr(direction);
                switch (current_state.*) {
                    .active, .activated => current_state.* = .active,
                    .inactive, .deactivated => current_state.* = .activated,
                }
            }

            pub fn finishAction(self: *@This(), action: Action, direction: Direction) void {
                const current_state = self.action_states.getPtr(action).getPtr(direction);
                switch (current_state.*) {
                    .active, .activated => current_state.* = .deactivated,
                    .inactive, .deactivated => current_state.* = .inactive,
                }
            }
        };

        pub const ControlScheme = struct {
            // We generate structs instead of using `EnumArray` here for two reasons:
            // 1) Easy forward compatible serialization
            // 2) Easy initialization as struct literals
            fn ActionMap(comptime T: type) type {
                return struct {
                    turn: T,
                    thrust_forward: T,
                    thrust_x: T,
                    thrust_y: T,
                    fire: T,

                    fn init(default: T) @This() {
                        var map: @This() = undefined;
                        inline for (@typeInfo(@This()).Struct.fields) |field| {
                            @field(map, field.name) = default;
                        }
                        return map;
                    }
                };
            }

            pub const SdlScancode = u16;

            pub const Keyboard = ActionMap(struct {
                positive: ?SdlScancode = null,
                negative: ?SdlScancode = null,
            });

            pub const Axis = struct {
                axis: c.SDL_GameControllerAxis,
                dead_zone: i16 = 10000,
            };

            pub const Controller = ActionMap(struct {
                axis: ?Axis = null,
                buttons: struct {
                    positive: ?c.SDL_GameControllerButton = null,
                    negative: ?c.SDL_GameControllerButton = null,
                } = .{},
            });

            // We don't store the controller here directly so that this struct can be serialized.
            controller_index: ?usize,
            controller_scheme: Controller,
            keyboard_scheme: Keyboard,
        };
    };
}
