#ifndef INCLUDE_UNPACK
#define INCLUDE_UNPACK

uvec4 unpackUintToUvec4(uint u) {
	return uvec4(
	    (u & 0xFF000000) >> 24,
	    (u & 0x00FF0000) >> 16,
	    (u & 0x0000FF00) >> 8,
	    (u & 0x000000FF)
	);
}

ivec2 unpackUintToUvec2(uint n) {
	return ivec2(
		n & 0x0000FFFF,
		n >> 16
	);
}

#endif
