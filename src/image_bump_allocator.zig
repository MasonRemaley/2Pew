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

pub fn ImageBumpAllocator(kind: ImageKind) type {
    return struct {
        const Memory = gpu.Memory(kind.asMemoryKind());
        const Image = gpu.Image(kind);

        name: [:0]const u8,
        page_size: u64,
        available: std.ArrayListUnmanaged(Memory),
        full: std.ArrayListUnmanaged(Memory),
        offset: u64,

        pub const Options = struct {
            name: [:0]const u8,
            page_size: u64,
            max_pages: usize,
            initial_pages: usize,
        };

        pub fn init(gpa: Allocator, gx: *Gx, options: Options) Allocator.Error!@This() {
            var available: ArrayListUnmanaged(Memory) = try .initCapacity(gpa, options.max_pages);
            errdefer available.deinit(gpa);
            var full: ArrayListUnmanaged(Memory) = try .initCapacity(gpa, options.max_pages);
            errdefer full.deinit(gpa);
            var result: @This() = .{
                .name = options.name,
                .page_size = options.page_size,
                .available = available,
                .full = full,
                .offset = 0,
            };
            for (0..options.initial_pages) |_| {
                result.available.appendAssumeCapacity(.init(gx, .{
                    .name = .{ .str = options.name, .index = result.count() },
                    .size = options.page_size,
                }));
            }
            return result;
        }

        pub fn deinit(self: *@This(), gpa: Allocator, gx: *Gx) void {
            for (self.available.items) |page| page.deinit(gx);
            self.available.deinit(gpa);
            for (self.full.items) |page| page.deinit(gx);
            self.full.deinit(gpa);
            self.* = undefined;
        }

        pub const AllocOptions = struct {
            name: DebugName,
            image: Image.Options,
        };

        pub fn count(self: @This()) usize {
            return self.available.items.len + self.full.items.len;
        }

        fn peekPage(self: *@This(), gx: *Gx, name: DebugName) Memory {
            if (self.available.items.len == 0) {
                log.warn("{}: out of color page memory, making dynamic allocation", .{name});
                if (self.count() >= self.available.capacity) @panic("OOB");
                self.available.appendAssumeCapacity(.init(gx, .{
                    .name = .{ .str = self.name, .index = self.count() },
                    .size = self.page_size,
                }));
                self.offset = 0;
            }
            return self.available.items[self.available.items.len - 1];
        }

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
                self.full.appendAssumeCapacity(result.memory);
                return result.image;
            }

            // Otherwise get the next available page with enough space, and allocate it there
            var page = self.peekPage(gx, options.name);
            self.offset = std.mem.alignForwardAnyAlign(u64, self.offset, reqs.alignment);
            if (self.offset + reqs.size >= page.size) {
                self.full.appendAssumeCapacity(self.available.pop().?);
                page = self.peekPage(gx, options.name);
            }
            const image: Image = .initPlaced(gx, .{
                .name = options.name,
                .memory = page,
                .offset = self.offset,
                .image = options.image,
            });
            self.offset += reqs.size;
            return image;
        }
    };
}
