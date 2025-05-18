#version 460
#extension GL_EXT_scalar_block_layout : require

layout(scalar, binding = 0) readonly buffer Global {
    mat2x3 world_to_view;
};

layout(scalar, binding = 1) readonly buffer ModelToWorlds {
    mat2x3 model_to_worlds[];
};

const vec2 vertices[4] = vec2[](
    vec2(-0.5, -0.5),
    vec2(-0.5, 0.5),
    vec2(0.5, -0.5),
    vec2(0.5, 0.5)
);

void main() {
    vec2 model = vertices[gl_VertexIndex];
    vec2 world = vec3(model, 1.0) * model_to_worlds[gl_InstanceIndex];
    vec2 view = vec3(world, 1.0) * world_to_view;
    gl_Position = vec4(view, 0.0, 1.0);
}
