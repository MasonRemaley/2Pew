#ifdef GL_VERTEX_SHADER
    void main() {
        gl_Position = vec4(0);
    }
#endif

#ifdef GL_FRAGMENT_SHADER 
    layout(location = 0) out vec4 l_color_buffer;

    void main() {
        #if RUNTIME_SAFETY
        	l_color_buffer = vec4(0);
    	#else
    		l_color_buffer = vec4(1);
    	#endif
    }
#endif
