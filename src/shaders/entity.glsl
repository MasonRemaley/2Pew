#ifndef INCLUDE_ENTITY
#define INCLUDE_ENTITY

const uint MatTex = 0;
const uint MatSolid = 1;

const uint TexNone = 0xFFFF;

struct Instance {
    mat2x3 model_to_world;
    uint diffuse_recolor;
    uint color;
};

struct Scene {
    mat2x3 world_to_view;
    float time;
};

#endif
