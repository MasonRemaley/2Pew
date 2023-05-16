pub usingnamespace @cImport({
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
});
pub usingnamespace @import("engine").c;
