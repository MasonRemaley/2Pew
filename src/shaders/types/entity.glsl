#ifndef INCLUDE_ENTITY
#define INCLUDE_ENTITY

const uint MatTex = 0;
const uint MatSolid = 1;

const uint TexNone = 0xFFFF;

// Part of descs/entities.glsl
struct Entity {
    mat2x3 model_to_world;
    uint diffuse_recolor;
    uint color;
};

#endif
