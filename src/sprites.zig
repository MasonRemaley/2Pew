// XXX: okay! so...this all works. I think we wanna add it for animations too to make sure it works well
// in game before we start automating it?
// - make an animations file
// - it specifies paths to animation configs, which could just be zig files that reference sprite ids?? making modding harder
//   again but eh?
// - okay yeah so I'm just gonna inline the data right now, later we can import zig files if we want!
// XXX: allow groups to be there own sort of asset, for picking randomly from a set? e.g. rocks, shrapnel
// XXX: we could generate an intermediat representation, json or something, that represents this
// in a more concise and editable way, and then generate this from that if we want.
// XXX: next step is to use this in game (and just auto load everything for now?)
// XXX: rename to images/image id? or are these explicitly sprites..?
// XXX: again consider that assets could all be in one enum if we wanted, if we're gonna chagne id type anyway, but
// exporting is different for different ones?
// XXX: consider things like animations where the number of frames change. i think it makes sense for aniamtions
// and maybe even sprites to reference images or something. and then maybe to differentiate between loaded and unloaded ones.
// but all config should be done bake time!
// XXX: all in one file, or new file for each asset type?
// XXX: consider whether to make non exhaustive with some marker to allow for non compiled in stuff?
// XXX: also consider some concept of like asset packs where we define ids for things that are loaded all together
// or such
// XXX: allow speicfying the same input asset with different bake settings multiple times?
// XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
const std = @import("std");

pub const SpriteId = enum {
    @"img/particle.png",
    @"img/planet-red.png",
    @"img/ring.png",
    @"img/rock-a.png",
    @"img/rock-b.png",
    @"img/rock-c.png",
    @"img/team0.png",
    @"img/team1.png",
    @"img/team2.png",
    @"img/team3.png",
    @"img/bullet/shiny.png",
    @"img/bullet/small.png",
    @"img/explosion/01.png",
    @"img/explosion/02.png",
    @"img/explosion/03.png",
    @"img/explosion/04.png",
    @"img/explosion/05.png",
    @"img/explosion/06.png",
    @"img/explosion/07.png",
    @"img/explosion/08.png",
    @"img/explosion/09.png",
    @"img/explosion/10.png",
    @"img/explosion/11.png",
    @"img/explosion/12.png",
    @"img/ship/kevin/thrusters/0.png",
    @"img/ship/kevin/thrusters/1.png",
    @"img/ship/kevin/thrusters/2.png",
    @"img/ship/kevin/diffuse.png",
    @"img/ship/kevin/recolor.png",
    @"img/ship/militia/thrusters/0.png",
    @"img/ship/militia/thrusters/1.png",
    @"img/ship/militia/thrusters/2.png",
    @"img/ship/militia/diffuse.png",
    @"img/ship/militia/recolor.png",
    @"img/ship/ranger/thrusters/0.png",
    @"img/ship/ranger/thrusters/1.png",
    @"img/ship/ranger/thrusters/2.png",
    @"img/ship/ranger/diffuse.png",
    @"img/ship/ranger/recolor.png",
    @"img/ship/triangle/thrusters/0.png",
    @"img/ship/triangle/thrusters/1.png",
    @"img/ship/triangle/thrusters/2.png",
    @"img/ship/triangle/diffuse.png",
    @"img/ship/triangle/recolor.png",
    @"img/ship/wendy/thrusters/bottom/0.png",
    @"img/ship/wendy/thrusters/bottom/1.png",
    @"img/ship/wendy/thrusters/bottom/2.png",
    @"img/ship/wendy/thrusters/left/0.png",
    @"img/ship/wendy/thrusters/left/1.png",
    @"img/ship/wendy/thrusters/left/2.png",
    @"img/ship/wendy/thrusters/right/0.png",
    @"img/ship/wendy/thrusters/right/1.png",
    @"img/ship/wendy/thrusters/right/2.png",
    @"img/ship/wendy/thrusters/top/0.png",
    @"img/ship/wendy/thrusters/top/1.png",
    @"img/ship/wendy/thrusters/top/2.png",
    @"img/ship/wendy/diffuse.png",
    @"img/ship/wendy/recolor.png",
    @"img/shrapnel/01.png",
    @"img/shrapnel/02.png",
    @"img/shrapnel/03.png",
    @"img/star/large.png",
    @"img/star/small.png",
};

pub const paths = b: {
    var result = std.EnumArray(SpriteId, []const u8).initFill(undefined);
    result.set(.@"img/particle.png", "img/particle.png");
    result.set(.@"img/planet-red.png", "img/planet-red.png");
    result.set(.@"img/ring.png", "img/ring.png");
    result.set(.@"img/rock-a.png", "img/rock-a.png");
    result.set(.@"img/rock-b.png", "img/rock-b.png");
    result.set(.@"img/rock-c.png", "img/rock-c.png");
    result.set(.@"img/team0.png", "img/team0.png");
    result.set(.@"img/team1.png", "img/team1.png");
    result.set(.@"img/team2.png", "img/team2.png");
    result.set(.@"img/team3.png", "img/team3.png");
    result.set(.@"img/bullet/shiny.png", "img/bullet/shiny.png");
    result.set(.@"img/bullet/small.png", "img/bullet/small.png");
    result.set(.@"img/explosion/01.png", "img/explosion/01.png");
    result.set(.@"img/explosion/02.png", "img/explosion/02.png");
    result.set(.@"img/explosion/03.png", "img/explosion/03.png");
    result.set(.@"img/explosion/04.png", "img/explosion/04.png");
    result.set(.@"img/explosion/05.png", "img/explosion/05.png");
    result.set(.@"img/explosion/06.png", "img/explosion/06.png");
    result.set(.@"img/explosion/07.png", "img/explosion/07.png");
    result.set(.@"img/explosion/08.png", "img/explosion/08.png");
    result.set(.@"img/explosion/09.png", "img/explosion/09.png");
    result.set(.@"img/explosion/10.png", "img/explosion/10.png");
    result.set(.@"img/explosion/11.png", "img/explosion/11.png");
    result.set(.@"img/explosion/12.png", "img/explosion/12.png");
    result.set(.@"img/ship/kevin/thrusters/0.png", "img/ship/kevin/thrusters/0.png");
    result.set(.@"img/ship/kevin/thrusters/1.png", "img/ship/kevin/thrusters/1.png");
    result.set(.@"img/ship/kevin/thrusters/2.png", "img/ship/kevin/thrusters/2.png");
    result.set(.@"img/ship/kevin/diffuse.png", "img/ship/kevin/diffuse.png");
    result.set(.@"img/ship/kevin/recolor.png", "img/ship/kevin/recolor.png");
    result.set(.@"img/ship/militia/thrusters/0.png", "img/ship/militia/thrusters/0.png");
    result.set(.@"img/ship/militia/thrusters/1.png", "img/ship/militia/thrusters/1.png");
    result.set(.@"img/ship/militia/thrusters/2.png", "img/ship/militia/thrusters/2.png");
    result.set(.@"img/ship/militia/diffuse.png", "img/ship/militia/diffuse.png");
    result.set(.@"img/ship/militia/recolor.png", "img/ship/militia/recolor.png");
    result.set(.@"img/ship/ranger/thrusters/0.png", "img/ship/ranger/thrusters/0.png");
    result.set(.@"img/ship/ranger/thrusters/1.png", "img/ship/ranger/thrusters/1.png");
    result.set(.@"img/ship/ranger/thrusters/2.png", "img/ship/ranger/thrusters/2.png");
    result.set(.@"img/ship/ranger/diffuse.png", "img/ship/ranger/diffuse.png");
    result.set(.@"img/ship/ranger/recolor.png", "img/ship/ranger/recolor.png");
    result.set(.@"img/ship/triangle/thrusters/0.png", "img/ship/triangle/thrusters/0.png");
    result.set(.@"img/ship/triangle/thrusters/1.png", "img/ship/triangle/thrusters/1.png");
    result.set(.@"img/ship/triangle/thrusters/2.png", "img/ship/triangle/thrusters/2.png");
    result.set(.@"img/ship/triangle/diffuse.png", "img/ship/triangle/diffuse.png");
    result.set(.@"img/ship/triangle/recolor.png", "img/ship/triangle/recolor.png");
    result.set(.@"img/ship/wendy/thrusters/bottom/0.png", "img/ship/wendy/thrusters/bottom/0.png");
    result.set(.@"img/ship/wendy/thrusters/bottom/1.png", "img/ship/wendy/thrusters/bottom/1.png");
    result.set(.@"img/ship/wendy/thrusters/bottom/2.png", "img/ship/wendy/thrusters/bottom/2.png");
    result.set(.@"img/ship/wendy/thrusters/left/0.png", "img/ship/wendy/thrusters/left/0.png");
    result.set(.@"img/ship/wendy/thrusters/left/1.png", "img/ship/wendy/thrusters/left/1.png");
    result.set(.@"img/ship/wendy/thrusters/left/2.png", "img/ship/wendy/thrusters/left/2.png");
    result.set(.@"img/ship/wendy/thrusters/right/0.png", "img/ship/wendy/thrusters/right/0.png");
    result.set(.@"img/ship/wendy/thrusters/right/1.png", "img/ship/wendy/thrusters/right/1.png");
    result.set(.@"img/ship/wendy/thrusters/right/2.png", "img/ship/wendy/thrusters/right/2.png");
    result.set(.@"img/ship/wendy/thrusters/top/0.png", "img/ship/wendy/thrusters/top/0.png");
    result.set(.@"img/ship/wendy/thrusters/top/1.png", "img/ship/wendy/thrusters/top/1.png");
    result.set(.@"img/ship/wendy/thrusters/top/2.png", "img/ship/wendy/thrusters/top/2.png");
    result.set(.@"img/ship/wendy/diffuse.png", "img/ship/wendy/diffuse.png");
    result.set(.@"img/ship/wendy/recolor.png", "img/ship/wendy/recolor.png");
    result.set(.@"img/shrapnel/01.png", "img/shrapnel/01.png");
    result.set(.@"img/shrapnel/02.png", "img/shrapnel/02.png");
    result.set(.@"img/shrapnel/03.png", "img/shrapnel/03.png");
    result.set(.@"img/star/large.png", "img/star/large.png");
    result.set(.@"img/star/small.png", "img/star/small.png");
    break :b result;
};

// XXX: separate array since we're gonna actually move this out of this file to bake time eventually!
pub const Config = struct {
    // XXX: remove recolor from above list once we can? and fromt his one actually, rename with _?
    tint: ?struct {
        mask_path: ?[]const u8 = null,
    } = null,
};
pub const config = b: {
    var result = std.EnumArray(SpriteId, Config).initFill(undefined);
    result.set(.@"img/particle.png", .{ .tint = .{} });
    result.set(.@"img/planet-red.png", .{});
    result.set(.@"img/ring.png", .{});
    result.set(.@"img/rock-a.png", .{});
    result.set(.@"img/rock-b.png", .{});
    result.set(.@"img/rock-c.png", .{});
    result.set(.@"img/team0.png", .{});
    result.set(.@"img/team1.png", .{});
    result.set(.@"img/team2.png", .{});
    result.set(.@"img/team3.png", .{});
    result.set(.@"img/bullet/shiny.png", .{});
    result.set(.@"img/bullet/small.png", .{});
    result.set(.@"img/explosion/01.png", .{});
    result.set(.@"img/explosion/02.png", .{});
    result.set(.@"img/explosion/03.png", .{});
    result.set(.@"img/explosion/04.png", .{});
    result.set(.@"img/explosion/05.png", .{});
    result.set(.@"img/explosion/06.png", .{});
    result.set(.@"img/explosion/07.png", .{});
    result.set(.@"img/explosion/08.png", .{});
    result.set(.@"img/explosion/09.png", .{});
    result.set(.@"img/explosion/10.png", .{});
    result.set(.@"img/explosion/11.png", .{});
    result.set(.@"img/explosion/12.png", .{});
    result.set(.@"img/ship/kevin/thrusters/0.png", .{});
    result.set(.@"img/ship/kevin/thrusters/1.png", .{});
    result.set(.@"img/ship/kevin/thrusters/2.png", .{});
    result.set(.@"img/ship/kevin/diffuse.png", .{
        .tint = .{
            .mask_path = "img/ship/kevin/diffuse.png",
        },
    });
    result.set(.@"img/ship/kevin/recolor.png", .{});
    result.set(.@"img/ship/militia/thrusters/0.png", .{});
    result.set(.@"img/ship/militia/thrusters/1.png", .{});
    result.set(.@"img/ship/militia/thrusters/2.png", .{});
    result.set(.@"img/ship/militia/diffuse.png", .{
        .tint = .{
            .mask_path = "img/ship/militia/diffuse.png",
        },
    });
    result.set(.@"img/ship/militia/recolor.png", .{});
    result.set(.@"img/ship/ranger/thrusters/0.png", .{});
    result.set(.@"img/ship/ranger/thrusters/1.png", .{});
    result.set(.@"img/ship/ranger/thrusters/2.png", .{});
    result.set(.@"img/ship/ranger/diffuse.png", .{
        .tint = .{
            .mask_path = "img/ship/ranger/diffuse.png",
        },
    });
    result.set(.@"img/ship/ranger/recolor.png", .{});
    result.set(.@"img/ship/triangle/thrusters/0.png", .{});
    result.set(.@"img/ship/triangle/thrusters/1.png", .{});
    result.set(.@"img/ship/triangle/thrusters/2.png", .{});
    result.set(.@"img/ship/triangle/diffuse.png", .{
        .tint = .{
            .mask_path = "img/ship/triangle/diffuse.png",
        },
    });
    result.set(.@"img/ship/triangle/recolor.png", .{});
    result.set(.@"img/ship/wendy/thrusters/bottom/0.png", .{});
    result.set(.@"img/ship/wendy/thrusters/bottom/1.png", .{});
    result.set(.@"img/ship/wendy/thrusters/bottom/2.png", .{});
    result.set(.@"img/ship/wendy/thrusters/left/0.png", .{});
    result.set(.@"img/ship/wendy/thrusters/left/1.png", .{});
    result.set(.@"img/ship/wendy/thrusters/left/2.png", .{});
    result.set(.@"img/ship/wendy/thrusters/right/0.png", .{});
    result.set(.@"img/ship/wendy/thrusters/right/1.png", .{});
    result.set(.@"img/ship/wendy/thrusters/right/2.png", .{});
    result.set(.@"img/ship/wendy/thrusters/top/0.png", .{});
    result.set(.@"img/ship/wendy/thrusters/top/1.png", .{});
    result.set(.@"img/ship/wendy/thrusters/top/2.png", .{});
    result.set(.@"img/ship/wendy/diffuse.png", .{
        .tint = .{
            .mask_path = "img/ship/wendy/diffuse.png",
        },
    });
    result.set(.@"img/ship/wendy/recolor.png", .{});
    result.set(.@"img/shrapnel/01.png", .{});
    result.set(.@"img/shrapnel/02.png", .{});
    result.set(.@"img/shrapnel/03.png", .{});
    result.set(.@"img/star/large.png", .{});
    result.set(.@"img/star/small.png", .{});
    break :b result;
};
