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
const assets = @import("assets.zig");

const Sprite = struct {
    path: []const u8,
    // XXX: eventually pull this out and do it at bake time!
    tint: ?struct {
        mask_path: ?[]const u8 = null,
    } = null,
};

pub const generated = assets.generate(Sprite, &.{
    .{
        .id = "img/particle.png",
        .asset = .{
            .path = "img/particle.png",
            .tint = .{},
        },
    },
    .{
        .id = "img/planet-red.png",
        .asset = .{
            .path = "img/planet-red.png",
        },
    },
    .{
        .id = "img/ring.png",
        .asset = .{
            .path = "img/ring.png",
        },
    },
    .{
        .id = "img/rock-a.png",
        .asset = .{
            .path = "img/rock-a.png",
        },
    },
    .{
        .id = "img/rock-b.png",
        .asset = .{
            .path = "img/rock-b.png",
        },
    },
    .{
        .id = "img/rock-c.png",
        .asset = .{
            .path = "img/rock-c.png",
        },
    },
    .{
        .id = "img/team0.png",
        .asset = .{
            .path = "img/team0.png",
        },
    },
    .{
        .id = "img/team1.png",
        .asset = .{
            .path = "img/team1.png",
        },
    },
    .{
        .id = "img/team2.png",
        .asset = .{
            .path = "img/team2.png",
        },
    },
    .{
        .id = "img/team3.png",
        .asset = .{
            .path = "img/team3.png",
        },
    },
    .{
        .id = "img/bullet/shiny.png",
        .asset = .{
            .path = "img/bullet/shiny.png",
        },
    },
    .{
        .id = "img/bullet/small.png",
        .asset = .{
            .path = "img/bullet/small.png",
        },
    },
    .{
        .id = "img/explosion/01.png",
        .asset = .{
            .path = "img/explosion/01.png",
        },
    },
    .{
        .id = "img/explosion/02.png",
        .asset = .{
            .path = "img/explosion/02.png",
        },
    },
    .{
        .id = "img/explosion/03.png",
        .asset = .{
            .path = "img/explosion/03.png",
        },
    },
    .{
        .id = "img/explosion/04.png",
        .asset = .{
            .path = "img/explosion/04.png",
        },
    },
    .{
        .id = "img/explosion/05.png",
        .asset = .{
            .path = "img/explosion/05.png",
        },
    },
    .{
        .id = "img/explosion/06.png",
        .asset = .{
            .path = "img/explosion/06.png",
        },
    },
    .{
        .id = "img/explosion/07.png",
        .asset = .{
            .path = "img/explosion/07.png",
        },
    },
    .{
        .id = "img/explosion/08.png",
        .asset = .{
            .path = "img/explosion/08.png",
        },
    },
    .{
        .id = "img/explosion/09.png",
        .asset = .{
            .path = "img/explosion/09.png",
        },
    },
    .{
        .id = "img/explosion/10.png",
        .asset = .{
            .path = "img/explosion/10.png",
        },
    },
    .{
        .id = "img/explosion/11.png",
        .asset = .{
            .path = "img/explosion/11.png",
        },
    },
    .{
        .id = "img/explosion/12.png",
        .asset = .{
            .path = "img/explosion/12.png",
        },
    },
    .{
        .id = "img/ship/kevin/thrusters/0.png",
        .asset = .{
            .path = "img/ship/kevin/thrusters/0.png",
        },
    },
    .{
        .id = "img/ship/kevin/thrusters/1.png",
        .asset = .{
            .path = "img/ship/kevin/thrusters/1.png",
        },
    },
    .{
        .id = "img/ship/kevin/thrusters/2.png",
        .asset = .{
            .path = "img/ship/kevin/thrusters/2.png",
        },
    },
    .{
        .id = "img/ship/kevin/diffuse.png",
        .asset = .{
            .path = "img/ship/kevin/diffuse.png",
            .tint = .{
                .mask_path = "img/ship/kevin/recolor.png",
            },
        },
    },
    .{
        .id = "img/ship/militia/thrusters/0.png",
        .asset = .{
            .path = "img/ship/militia/thrusters/0.png",
        },
    },
    .{
        .id = "img/ship/militia/thrusters/1.png",
        .asset = .{
            .path = "img/ship/militia/thrusters/1.png",
        },
    },
    .{
        .id = "img/ship/militia/thrusters/2.png",
        .asset = .{
            .path = "img/ship/militia/thrusters/2.png",
        },
    },
    .{
        .id = "img/ship/militia/diffuse.png",
        .asset = .{
            .path = "img/ship/militia/diffuse.png",
            .tint = .{
                .mask_path = "img/ship/militia/recolor.png",
            },
        },
    },
    .{
        .id = "img/ship/ranger/thrusters/0.png",
        .asset = .{
            .path = "img/ship/ranger/thrusters/0.png",
        },
    },
    .{
        .id = "img/ship/ranger/thrusters/1.png",
        .asset = .{
            .path = "img/ship/ranger/thrusters/1.png",
        },
    },
    .{
        .id = "img/ship/ranger/thrusters/2.png",
        .asset = .{
            .path = "img/ship/ranger/thrusters/2.png",
        },
    },
    .{
        .id = "img/ship/ranger/diffuse.png",
        .asset = .{
            .path = "img/ship/ranger/diffuse.png",
            .tint = .{
                .mask_path = "img/ship/ranger/recolor.png",
            },
        },
    },
    .{
        .id = "img/ship/triangle/thrusters/0.png",
        .asset = .{
            .path = "img/ship/triangle/thrusters/0.png",
        },
    },
    .{
        .id = "img/ship/triangle/thrusters/1.png",
        .asset = .{
            .path = "img/ship/triangle/thrusters/1.png",
        },
    },
    .{
        .id = "img/ship/triangle/thrusters/2.png",
        .asset = .{
            .path = "img/ship/triangle/thrusters/2.png",
        },
    },
    .{
        .id = "img/ship/triangle/diffuse.png",
        .asset = .{
            .path = "img/ship/triangle/diffuse.png",
            .tint = .{
                .mask_path = "img/ship/triangle/recolor.png",
            },
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/bottom/0.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/bottom/0.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/bottom/1.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/bottom/1.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/bottom/2.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/bottom/2.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/left/0.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/left/0.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/left/1.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/left/1.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/left/2.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/left/2.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/right/0.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/right/0.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/right/1.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/right/1.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/right/2.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/right/2.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/top/0.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/top/0.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/top/1.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/top/1.png",
        },
    },
    .{
        .id = "img/ship/wendy/thrusters/top/2.png",
        .asset = .{
            .path = "img/ship/wendy/thrusters/top/2.png",
        },
    },
    .{
        .id = "img/ship/wendy/diffuse.png",
        .asset = .{
            .path = "img/ship/wendy/diffuse.png",
            .tint = .{
                .mask_path = "img/ship/wendy/recolor.png",
            },
        },
    },
    .{
        .id = "img/shrapnel/01.png",
        .asset = .{
            .path = "img/shrapnel/01.png",
        },
    },
    .{
        .id = "img/shrapnel/02.png",
        .asset = .{
            .path = "img/shrapnel/02.png",
        },
    },
    .{
        .id = "img/shrapnel/03.png",
        .asset = .{
            .path = "img/shrapnel/03.png",
        },
    },
    .{
        .id = "img/star/large.png",
        .asset = .{
            .path = "img/star/large.png",
        },
    },
    .{
        .id = "img/star/small.png",
        .asset = .{
            .path = "img/star/small.png",
        },
    },
});

pub const SpriteId = generated.Id;
// XXX: naming...? or just expose getter?
pub const data = generated.assets;
