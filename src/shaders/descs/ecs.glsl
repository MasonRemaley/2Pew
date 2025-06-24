#include "types/entity.glsl"
#include "types/scene.glsl"

#ifdef GL_VERTEX_SHADER
	layout(scalar, binding = 0) readonly buffer SceneUbo { Scene scene; };
	layout(scalar, binding = 1) readonly buffer EntitiesUbo { Entity entities[]; };
#endif

#ifdef GL_FRAGMENT_SHADER
	layout(binding = 2) uniform texture2D textures[];
	layout(binding = 3) uniform sampler texture_sampler;
#endif
