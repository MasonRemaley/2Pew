//! A color image upload queue.
//!
//! Operates on a fixed size staging buffer, writes to whatever memory the caller provides.
//!
//! To use, first call `beginWrite`, and then write your data to the provided writer. When all of
//! your uploads have been queued, call `submit`. This must be done within a frame.
//!
//! # Uploading Synchronously
//!
//! If you only need to upload a small amount of data, you can probably load your images
//! synchronously to a single `ImageUploadQueue`.
//!
//! Attempting to calculate the exact size of the staging buffer or image memory isn't recommended
//! as it limits your flexibility. When working with a small amount of data, this shouldn't be a
//! concern, and when working with a large amount of data you typically upload asynchronously which
//! means you're reusing staging buffers anyway.
//!
//! # Uploading Asynchronously
//!
//! If you're uploading a large amount of data, you probably should do it asynchronously.
//!
//! Eventually `gpu` will get support for multiple queues
//! (https://github.com/Games-by-Mason/gpu/issues/1), but even still you likely want to
//! support hardware that only provides a single queue. This means that you need to divide up your
//! work into frame sized chunks.
//!
//! The recommended approach is to create one `ImageUploadQueue` per frame in flight. Assets should
//! be loaded from disk on a background thread or threads. The main thread polls to see if the
//! background threads have completed any work, and if they have, checks if there's space in the
//! current upload queue. If there is, it writes them.
//!
//! At the end of each frame, the current upload queue is submitted.
//!
//! By tuning the size of the staging buffer, you can limit how much work is done one any single
//! frame and provide a smooth experience. Keep in mind that the bottleneck is likely the read from
//! disk, not the GPU upload, and you can set your values accordingly. Setting the buffer too small
//! is unlikely to affect performance much, but it needs to be at least as large as the largest
//! image.

const gpu = @import("gpu");

const Gx = gpu.Gx;
const CmdBuf = gpu.CmdBuf;
const VolatileWriter = gpu.VolatileWriter;
const UploadBuf = gpu.UploadBuf;
const DebugName = gpu.DebugName;
const Image = gpu.Image;

cb: CmdBuf.Optional,
staging: gpu.UploadBuf(.{ .transfer_src = true }),
writer: VolatileWriter,

pub const Options = struct {
    name: gpu.DebugName,
    bytes: u64,
};

pub fn init(gx: *Gx, options: Options) @This() {
    const staging: gpu.UploadBuf(.{ .transfer_src = true }) = .init(gx, .{
        .name = options.name,
        .size = options.bytes,
        .prefer_device_local = false,
    });

    const writer = staging.writer(.{});

    return .{
        .cb = .none,
        .staging = staging,
        .writer = writer,
    };
}

pub fn deinit(self: *@This(), gx: *Gx) void {
    self.staging.deinit(gx);
    self.* = undefined;
}

pub fn beginWrite(
    self: *@This(),
    gx: *Gx,
    options: Image(.color).InitOptions,
) gpu.Image(.color) {
    const cb = self.cb.unwrap() orelse b: {
        const cb: CmdBuf = .init(gx, .{
            .name = "Color Image Upload",
            .src = @src(),
        });
        self.cb = cb.asOptional();
        break :b cb;
    };

    const image: gpu.Image(.color) = .init(gx, options);

    cb.barriers(gx, .{ .image = &.{
        .undefinedToTransferDst(.{
            .handle = image.handle,
            .range = .first,
            .aspect = .{ .color = true },
        }),
    } });

    cb.uploadImage(gx, .{
        .dst = image.handle,
        .src = self.staging.handle,
        .base_mip_level = 0,
        .mip_levels = 1,
        .regions = &.{
            .init(.{
                .aspect = .{ .color = true },
                .image_extent = options.image.extent,
                .buffer_offset = self.writer.pos,
            }),
        },
    });

    cb.barriers(gx, .{ .image = &.{.transferDstToReadOnly(.{
        .handle = image.handle,
        .range = .first,
        .dst_stage = .{ .fragment_shader = true },
        .aspect = .{ .color = true },
    })} });

    return image;
}

pub fn submit(self: *@This(), gx: *Gx) void {
    if (self.cb.unwrap()) |cb| {
        cb.submit(gx);
        self.cb = .none;
        self.writer.pos = 0;
    }
}
