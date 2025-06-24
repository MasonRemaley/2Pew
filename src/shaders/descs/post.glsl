#include "types/scene.glsl"

#ifdef GL_FRAGMENT_SHADER
	layout(scalar, binding = 0) readonly buffer SceneUbo { Scene scene; };

	// Render targets aliased under different types. It's up to the shader to choose the correct alias.
	//
	// Alias names are `rt_[$ACCESS][?_$FORMAT]` where access is `r` for readonly, `rw` for read write,
	// or `w` for writeonly.
	//
	// Format is elided for writeonly.
	layout(binding = 1, rgba8) readonly uniform image2D rt_r_rgba8[];
	layout(binding = 1, rgba8) uniform image2D rt_rw_rgba8[];
	layout(binding = 1) writeonly uniform image2D rt_w[];
#endif
