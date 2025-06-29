#include "types/scene.glsl"

#ifdef GL_COMPUTE_SHADER
	layout(scalar, binding = 0) readonly buffer SceneUbo { Scene scene; };
	layout(binding = 1, rgba8) readonly uniform image2D color_buffer_r;
	layout(binding = 2, rgba8) uniform image2D composite_rw;
#endif
