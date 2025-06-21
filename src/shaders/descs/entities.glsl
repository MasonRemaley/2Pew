#include "types/entity.glsl"
layout(scalar, binding = BENTITIES) readonly buffer EntitiesUbo { Entity entities[]; };
