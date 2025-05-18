#version 460
#extension GL_EXT_scalar_block_layout : require

layout(scalar, binding = 0) readonly buffer Global {
    mat2x3 world_to_view;
};

const vec2 vertices[4] = vec2[](
    vec2(0, 0),
    vec2(1, 0),
    vec2(0, 1),
    vec2(1, 1)
);

void main() {
    vec2 world = vertices[gl_VertexIndex];
    vec2 view = vec3(world, 1.0) * world_to_view;
    gl_Position = vec4(view, 0.0, 1.0);
}
