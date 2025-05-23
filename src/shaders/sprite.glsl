const uint MatTex = 0;
const uint MatSolid = 1;

struct Instance {
    mat2x3 model_to_world;
    uint mat;
    uint mat_ex;
};

struct Scene {
    mat2x3 world_to_view;
};
