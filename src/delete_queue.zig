//! See `DeleteQueue`.

const std = @import("std");
const gpu = @import("gpu");

const assert = std.debug.assert;

const Gx = gpu.Gx;

/// In modern graphics APIs, you often have to wait until a resource is no longer in use by the GPU
/// to free it. Often this requires waiting until the frame in flight counter loops. This structure
/// makes this a bit easier.
///
/// Your renderer will typically store one delete queue per frame in flight, and reset it at the
/// beginning of every frame. If you want to destroy a resource once the frame in flight loops,
/// you can just enqueue it to this queue.
pub fn DeleteQueue(capacity: usize) type {
    return struct {
        /// Represents a handle queued for destruction.
        pub const Handle = struct {
            /// The integer value of the handle.
            value: u64,
            /// A pointer to the handle's delete function.
            deinit: *const fn(value: u64, gx: *Gx) void,
        };

        /// The list of handles queued for deletion.
        handles: std.BoundedArray(Handle, capacity) = .{},

        /// Appends the given resource to the delete queue.
        ///
        /// If the resource is a 64 bit enum with a `deinit(*@This(), *Gx)` field, appends it as is.
        /// If it's a struct, it looks for a `handle` field that satisfies the above requirement,
        /// and optionally for a `memory` field of type `Memory` and a `dedicated_memory` field of
        /// type `Memory.Optional`.
        pub fn append(self: *@This(), resource: anytype) void {
            switch (@typeInfo(@TypeOf(resource))) {
                .@"enum" => {
                    comptime assert(@sizeOf(@TypeOf(resource)) == @sizeOf(u64));
                    const Deinit = struct {
                        fn deinit(value: u64, gx: *Gx) void {
                            const handle: @TypeOf(resource) = @enumFromInt(value);
                            handle.deinit(gx);
                        }
                    };
                    self.handles.append(.{
                        .value = @intFromEnum(resource),
                        .deinit = &Deinit.deinit,
                    }) catch |err| @panic(@errorName(err));
                },
                .@"struct" => {
                    self.append(resource.handle);
                    if (@hasField(@TypeOf(resource), "memory")) {
                        self.append(resource.memory);
                    }
                    if (@hasField(@TypeOf(resource), "dedicated_memory")) {
                        if (resource.memory.unwrap()) |memory| {
                            self.append(memory);
                        }
                    }
                },
                else => comptime unreachable,
            }
        }

        /// Frees all queues resources and resets the queue.
        pub fn reset(self: *@This(), gx: *Gx) void {
            for (self.handles.constSlice()) |handle| {
                handle.deinit(handle.value, gx);
            }
            self.handles.clear();
        }
    };
}
