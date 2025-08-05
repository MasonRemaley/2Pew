#include <gbms/unpack.glsl>
#include <gbms/link.glsl>

#include "interface.glsl"

#define SAMPLER(id) sampler2D(i_textures[nonuniform(id)], i_linear_sampler)

LINK_VERT_FRAG(location = 0) vec2 l_texcoord;
LINK_VERT_FRAG(location = 1) flat Entity l_entity;

#ifdef GL_VERTEX_SHADER
    void main() {
        const vec2 vertices[4] = vec2[](
            vec2(0, 0),
            vec2(0, 1),
            vec2(1, 0),
            vec2(1, 1)
        );

        const vec2 texcoords[4] = vec2[](
            vec2(0, 1),
            vec2(0, 0),
            vec2(1, 1),
            vec2(1, 0)
        );

        Entity entity = i_entities[gl_InstanceIndex];
        vec2 model = vertices[gl_VertexIndex];
        vec2 world = vec3(model, 1.0) * entity.model_to_world;
        vec2 view = vec3(world, 1.0) * i_scene.world_to_view;
        vec2 projection = vec3(view, 1.0) * i_scene.view_to_projection;

        gl_Position = vec4(projection, entity.sort, 1.0);
        l_texcoord = texcoords[gl_VertexIndex];
        l_entity = entity;
    }
#endif

#ifdef GL_FRAGMENT_SHADER
    layout(location = 0) out vec4 l_color_buffer;

    void main() {
        uvec2 diffuse_recolor = unpackU16x2(l_entity.diffuse_recolor);
        u32 diffuse_id = diffuse_recolor.x;
        u32 recolor_id = diffuse_recolor.y;

        vec4 diffuse = vec4(1.0);
        if (diffuse_id != i_tex_none) {
            diffuse = texture(SAMPLER(diffuse_id), l_texcoord);
        }

        f32 recolor = 1.0;
        if (recolor_id != i_tex_none) {
            recolor *= texture(SAMPLER(recolor_id), l_texcoord).r;
        }

        vec4 color = unpackUnorm4x8(l_entity.color);
        l_color_buffer = mix(diffuse, diffuse * color, recolor);
    }
#endif
