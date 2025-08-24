#ifndef INCLUDE_2P_INTERFACE
#define INCLUDE_2P_INTERFACE

#include <gbms/c.glsl>
#include <gbms/mod_timer.glsl>

const u32 i_tex_none = 0xFFFF;
const u32 i_max_render_targets = 16;

struct Mouse {
    vec2 position;
    u32 buttons;
};
TYPEDEF_STRUCT(Mouse);

struct Scene {
    mat2x3 world_to_view;
    mat2x3 view_to_projection;
    ModTimer timer;
    Mouse mouse;
};

struct Entity {
    mat2x3 model_to_world;
    u32 diffuse_recolor;
    u32 color;
};

#if defined(GL_VERTEX_SHADER) || defined(GL_COMPUTE_SHADER) || defined(GL_FRAGMENT_SHADER)
    layout(scalar, binding = 0) readonly buffer SceneUbo { Scene i_scene; };
#endif

#if defined(GL_VERTEX_SHADER)
    layout(scalar, binding = 1) readonly buffer EntitiesUbo { Entity i_entities[]; };
    layout(scalar, binding = 2) readonly buffer EntitiesLenUbo { u32 i_entities_len; };
#endif

#if defined(GL_FRAGMENT_SHADER)
    layout(binding = 3) uniform texture2D i_textures[];
#endif

#if defined(GL_FRAGMENT_SHADER) || defined(GL_COMPUTE_SHADER)
    layout(binding = 4) uniform sampler i_sprite_sampler;
#endif

#if defined(GL_FRAGMENT_SHADER) || defined(GL_COMPUTE_SHADER)
    layout(binding = 5) uniform sampler i_rt_sampler;
#endif

#if defined(GL_COMPUTE_SHADER)
    layout(binding = 6, rgba8) uniform image2D i_rt_storage_image_rgba8_rw[i_max_render_targets];
    layout(binding = 6, rgba8) uniform readonly image2D i_rt_storage_image_rba8_r[i_max_render_targets];
    layout(binding = 6) uniform writeonly image2D i_rt_storage_image_any_w[i_max_render_targets];
#endif

#if defined(GL_COMPUTE_SHADER)
    layout(binding = 7) uniform texture2D i_rt_texture[i_max_render_targets];
#endif

#endif
