vec4 unormToVec4(uint unorm) {
	// Multiplying by the reciprocal is faster than dividing by 255.0, but does not produce exact
	// results. By multiplying both the numerator and denominator by three, we get exact results for
	// the full possible range of inputs. This has been verified by looping over all inputs and
	// comparing the results to the exact form.
	return vec4(
	    (unorm & 0xFF000000) >> 24,
	    (unorm & 0x00FF0000) >> 16,
	    (unorm & 0x0000FF00) >> 8,
	    unorm & 0x000000FF
	) * 3.0 * 1.0 / (3.0 * 255.0);
}
