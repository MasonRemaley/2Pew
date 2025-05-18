#version 460
#extension GL_EXT_scalar_block_layout : require

layout(scalar, binding = 0) readonly buffer Global { vec2 camera; };

const vec2 vertices[4] = vec2[](
    vec2(0, 0),
    vec2(1, 0),
    vec2(0, 1),
    vec2(1, 1)
);

void main() {
    gl_Position = vec4(vertices[gl_VertexIndex] + camera, 0.0, 1.0);
}
