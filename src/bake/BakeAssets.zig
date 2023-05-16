const std = @import("std");
const BakeAssets = @This();
const Step = std.Build.Step;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

step: *Step,
// XXX: naming index vs asset_descriptors?
index: std.Build.FileSource,

// XXX: naming of file vs of other stuff that will be here?
// XXX: pull this code out into its own step or something that we can put in library code
// XXX: organize other code into modules?
// XXX: eventually do baking of things like tints here
// XXX: allow asset groups for purposes of choosing random versions of things? e.g. an artist can
// add a file to a group via a config file or folder structure, and it shows up in game without the
// game needing to modify internal arrays of things. may also be useful for things like animations?
// XXX: asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
// this dynamic instead of static we may want the missing asset fallbacks again?
// XXX: allow speicfying the same input asset with different bake settings multiple times?
// XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
// XXX: may eventually do something like foo.anim.zig and foo.bake.json? or just use those extensions? but can be
// dups if same name different types still for bake file so like foo.anim and foo.anim.bake I think is most readable! but
// is annoying that doesn't say json/zig for easier syntax highlighting, that'd be foo.anim.zig and foo.anim.bake.json
// can just config editors that way it's not a big deal...and will visually recognize/work with the formats etc don't need to specify.
// XXX: make sure we can do e.g. zig build bake to just bake, add stdout so we can see what's happening even if clear after each line
pub fn create(owner: *std.Build, data_path: []const u8) !BakeAssets {
    var copy_assets = owner.addWriteFiles();
    var index_bytes = ArrayListUnmanaged(u8){};
    defer index_bytes.deinit(owner.allocator);

    try index_bytes.appendSlice(owner.allocator, "pub const descriptors = &.{\n");

    const BakeConfig = struct { id: []const u8 };

    // XXX: look into how the build runner parses build.zon, maybe do that instead of json here!
    // XXX: cache the index in source control as well in something readable (.zon or .json) and use
    // it as input when available to verify that assets weren't missing and such?
    const extension = ".json";
    // XXX: don't use cwd here, is place build was run from!
    var assets_iterable = try std.fs.cwd().makeOpenPathIterable(data_path, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(owner.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.path, extension)) {
                var asset_path = try std.fmt.allocPrint(owner.allocator, "{s}.zig", .{entry.path[0 .. entry.path.len - extension.len]});
                std.mem.replaceScalar(u8, asset_path, '\\', '/');
                var zig_in_path = try std.fmt.allocPrint(owner.allocator, "{s}/{s}", .{ data_path, asset_path });
                var zig_out_path = try std.fmt.allocPrint(owner.allocator, "data/{s}", .{asset_path});

                _ = copy_assets.addCopyFile(.{ .path = zig_in_path }, zig_out_path);

                var file = try assets_iterable.dir.openFile(entry.path, .{});
                defer file.close();
                var source = try file.readToEndAlloc(owner.allocator, 1000000);
                defer owner.allocator.free(source);
                var config = try std.json.parseFromSlice(BakeConfig, owner.allocator, source, .{});
                defer config.deinit();

                // XXX: can look into how build.zig.zon is loaded?
                try index_bytes.appendSlice(owner.allocator,
                    \\    .{
                    \\        .id = "
                );
                try index_bytes.appendSlice(owner.allocator, config.value.id);
                try index_bytes.appendSlice(owner.allocator,
                    \\",
                    \\        .asset = @import("data/
                );
                try index_bytes.appendSlice(owner.allocator, asset_path);
                try index_bytes.appendSlice(owner.allocator,
                    \\").asset,
                    \\    },
                    \\
                );
            }
        }
    }
    try index_bytes.appendSlice(owner.allocator, "};\n");

    const index = copy_assets.add("index.zig", index_bytes.items);

    return .{
        .step = &copy_assets.step,
        .index = index,
    };
}

// const std = @import("std");
// // XXX: these deps okay..?
// // const asset_index = @import("asset_index.zig");
// // const asset_indexer = @import("asset_indexer.zig");
// // const Animation = asset_index.Animation;
// // const Descriptor = asset_indexer.Descriptor;

// const BakeConfig = struct { id: []const u8 };

// // XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
// // XXX: never free memory here it's a short lived process, just use a fixed buffer allocator from some pages or something
// // XXX: this reader is buffered right?
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();

//     const args = try std.process.argsAlloc(allocator);
//     defer std.process.argsFree(allocator, args);

//     if (args.len != 4) {
//         std.debug.panic("expected three arguments", .{});
//     }

//     const json_path = args[1];
//     const zig_path = args[2];
//     const out_path = args[3];

//     var file = try std.fs.openFileAbsolute(json_path, .{});
//     defer file.close();
//     var source = try file.readToEndAlloc(allocator, 1000000);
//     var tokens = std.json.TokenStream.init(source);
//     const parse_options = .{ .allocator = allocator };
//     var config = try std.json.parse(BakeConfig, &tokens, parse_options);
//     defer std.json.parseFree(BakeConfig, config, parse_options);

//     // XXX: rename to persistent_id so it's clear you shouldn't change it?
//     std.debug.print("bake id {s}\n", .{config.id});
//     std.debug.print("zig {s}\n", .{zig_path});
//     std.debug.print("output! {s}\n", .{out_path});

//     // XXX: options?
//     try std.fs.copyFileAbsolute(zig_path, out_path, .{});
// }
