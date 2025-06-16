#ifndef INCLUDE_SCENE
#define INCLUDE_SCENE

#include <gbms/mod_timer.glsl>

struct Scene {
    mat2x3 world_to_view;
    mat2x3 view_to_projection;
    ModTimer timer;
    vec2 mouse;
};

#endif
