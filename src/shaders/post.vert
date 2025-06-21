layout(location = 0) out vec2 out_texcoord;

const vec2 vertices[3] = vec2[](
    vec2(-1, -1),
    vec2(3, -1),
    vec2(-1, 3)
);

const vec2 texcoords[3] = vec2[](
    vec2(0, 0),
    vec2(2, 0),
    vec2(0, 2)
);

void main() {
    gl_Position = vec4(vertices[gl_VertexIndex], 0, 1);
    out_texcoord = texcoords[gl_VertexIndex];
}
