struct Instance {
    mat2x3 model_to_world;
    uint texture_index;
};

struct Scene {
    mat2x3 world_to_view;
};
