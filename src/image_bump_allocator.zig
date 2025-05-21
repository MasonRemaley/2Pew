//! See `ImageBumpAllocator`.

const std = @import("std");
const gpu = @import("gpu");
const build = @import("build.zig.zon");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Gx = gpu.Gx;
const ImageKind = gpu.ImageKind;
const MemoryRequirements = gpu.MemoryRequirements;
const DebugName = gpu.DebugName;

const log = std.log.scoped(build.name);
const assert = std.debug.assert;

/// A bump allocator for images. For managing buffer allocations, see `BufferLayout`.
///
/// Modern graphics APIs provide what is essentially a page allocator, and expect you to suballocate
/// from it. However, different resources may require different memory types, and some resources may
/// require dedicated allocations.
///
/// Furthermore, padding requirements may vary from device to device unless you want to adopt DX12's
/// conservative padding (https://microsoft.github.io/DirectX-Specs/d3d/D3D12TightPlacedResourceAlignment.html)
/// so it's difficult to estimate the correct fixed buffer size to allocate up front unless you
/// statically know which resources you'll load in what order, which is highly restrictive.
///
/// A simple solution to this for many cases is a page based bump allocator. The intended usage is
/// to statically allocate the required number of pages up front, but leave room for additional
/// dynamic allocations (which will emit warnings) if you run out of space due to alignment or
/// differing dedicated allocation affinities between devices.
///
/// Dedicated allocations are handled for you automatically. No interface is exposed for reusing
/// individual pieces of memory, but you can reset the entire allocator if all resources have been
/// destroyed. You may want to create a separate allocator for things like per-level vs global data
/// to allow freeing some data while keeping other data around.
pub fn ImageBumpAllocator(kind: ImageKind) type {
    return struct {
        const Memory = gpu.Memory(kind.asMemoryKind());
        const Image = gpu.Image(kind);

        const Page = struct {
            name: DebugName,
            memory: Memory,
            dedicated: bool,

            fn reset(self: *@This(), gx: *Gx) void {
                if (gx.validate) {
                    // Normally reset is a noop. However, if we have validation layers on, destroy
                    // and recreate the memory so that they complain if any resources still bound to
                    // it get reused.
                    const new: Memory = .init(gx, .{
                        .name = self.name,
                        .size = self.memory.size,
                    });
                    self.memory.deinit(gx);
                    self.memory = new;
                }
            }
        };

        name: [:0]const u8,
        page_size: u64,
        available: std.ArrayListUnmanaged(Page),
        full: std.ArrayListUnmanaged(Page),
        offset: u64,

        pub const Options = struct {
            name: [:0]const u8,
            page_size: u64,
            max_pages: usize,
            initial_pages: usize,
        };

        /// Creates a new allocator.
        pub fn init(gpa: Allocator, gx: *Gx, options: Options) Allocator.Error!@This() {
            var available: ArrayListUnmanaged(Page) = try .initCapacity(gpa, options.max_pages);
            errdefer available.deinit(gpa);
            var full: ArrayListUnmanaged(Page) = try .initCapacity(gpa, options.max_pages);
            errdefer full.deinit(gpa);
            var result: @This() = .{
                .name = options.name,
                .page_size = options.page_size,
                .available = available,
                .full = full,
                .offset = 0,
            };
            for (0..options.initial_pages) |_| {
                const name: DebugName = .{ .str = options.name, .index = result.count() };
                result.available.appendAssumeCapacity(.{
                    .name = name,
                    .memory = .init(gx, .{
                        .name = name,
                        .size = options.page_size,
                    }),
                    .dedicated = false,
                });
            }
            return result;
        }

        pub fn deinit(self: *@This(), gpa: Allocator, gx: *Gx) void {
            for (self.available.items) |page| page.memory.deinit(gx);
            self.available.deinit(gpa);
            for (self.full.items) |page| page.memory.deinit(gx);
            self.full.deinit(gpa);
            self.* = undefined;
        }

        pub const AllocOptions = struct {
            name: DebugName,
            image: Image.Options,
        };

        /// Returns the number of reserved pages.
        pub fn count(self: @This()) usize {
            return self.available.items.len + self.full.items.len;
        }

        fn peekPage(self: *@This(), gx: *Gx, image_name: DebugName) Page {
            if (self.available.items.len == 0) {
                log.warn("{}: out of color page memory, making dynamic allocation", .{image_name});
                if (self.count() >= self.available.capacity) @panic("OOB");
                const name: DebugName = .{ .str = self.name, .index = self.count() };
                self.available.appendAssumeCapacity(.{
                    .name = name,
                    .memory = .init(gx, .{
                        .name = name,
                        .size = self.page_size,
                    }),
                    .dedicated = false,
                });
                self.offset = 0;
            }
            return self.available.items[self.available.items.len - 1];
        }

        /// Allocates an image. This will attempt to place the image in an existing page, or
        /// allocate a new one if needed. If the image is too big or the driver prefers a dedicated
        /// allocation, it will be given a dedicated page.
        pub fn alloc(self: *@This(), gx: *Gx, options: AllocOptions) Image {
            // Decide on an allocation strategy
            const reqs = options.image.memoryRequirements(gx);
            const dedicated = switch (reqs.dedicated) {
                .preferred => b: {
                    log.debug("{}: prefers dedicated allocation", .{options.name});
                    break :b true;
                },
                .required => b: {
                    log.debug("{}: requires dedicated allocation", .{options.name});
                    break :b true;
                },
                .discouraged => if (reqs.size > self.page_size) b: {
                    log.warn(
                        "{}: dedicated allocation discouraged, but image larger than page size",
                        .{options.name},
                    );
                    break :b true;
                } else false,
            };

            // If we decided on making a dedicated allocation for this image, create it and early
            // out
            if (dedicated) {
                if (self.count() >= self.full.capacity) @panic("OOB");
                const result = Image.initDedicated(gx, .{
                    .name = options.name,
                    .image = options.image,
                });
                self.full.appendAssumeCapacity(.{
                    .name = options.name,
                    .memory = result.memory,
                    .dedicated = true,
                });
                return result.image;
            }

            // Otherwise get the next available page with enough space, and allocate it there
            var page = self.peekPage(gx, options.name);
            self.offset = std.mem.alignForwardAnyAlign(u64, self.offset, reqs.alignment);
            if (self.offset + reqs.size >= page.memory.size) {
                self.full.appendAssumeCapacity(self.available.pop().?);
                page = self.peekPage(gx, options.name);
            }
            const image: Image = .initPlaced(gx, .{
                .name = options.name,
                .memory = page.memory,
                .offset = self.offset,
                .image = options.image,
            });
            self.offset += reqs.size;
            return image;
        }

        /// Makes all non dedicated pages available for reuse, frees all dedicated memory. All
        /// resources must be freed first.
        pub fn reset(self: *@This(), gx: *Gx) void {
            for (self.available.items) |*page| page.reset(gx);

            for (self.full.items) |*page| {
                if (page.dedicated) {
                    // This is slightly conservative. I haven't found documentation that reusing
                    // dedicated memory is disallowed, but it's unclear to me that it is allowed
                    // either.
                    page.memory.deinit(gx);
                } else {
                    page.reset(gx);
                    self.available.appendAssumeCapacity(page.*);
                }
            }
            self.full.clearRetainingCapacity();
        }
    };
}
