shader_type canvas_item;

uniform float blur_strength : hint_range(0.0, 3.0) = 1.0;

void fragment() {
    vec2 texel = blur_strength * TEXTURE_PIXEL_SIZE;

    // 3x3 Gaussian-ish blur
    vec3 sum =
        texture(TEXTURE, UV + texel * vec2(-1.0, -1.0)).rgb * 1.0 +
        texture(TEXTURE, UV + texel * vec2( 0.0, -1.0)).rgb * 2.0 +
        texture(TEXTURE, UV + texel * vec2( 1.0, -1.0)).rgb * 1.0 +

        texture(TEXTURE, UV + texel * vec2(-1.0,  0.0)).rgb * 2.0 +
        texture(TEXTURE, UV).rgb                                 * 4.0 +
        texture(TEXTURE, UV + texel * vec2( 1.0,  0.0)).rgb * 2.0 +

        texture(TEXTURE, UV + texel * vec2(-1.0,  1.0)).rgb * 1.0 +
        texture(TEXTURE, UV + texel * vec2( 0.0,  1.0)).rgb * 2.0 +
        texture(TEXTURE, UV + texel * vec2( 1.0,  1.0)).rgb * 1.0;

    vec3 blurred = sum / 16.0;

    // Use red channel as gradient value
    float t = clamp(blurred.r, 0.0, 1.0);
	vec3 final_color;

	vec3 color_a = vec3(0.0, 0.0, 0.0);
	vec3 color_b = vec3(0.0, 0.1, 0.3);
	vec3 color_c = vec3(0.1, 0.4, 0.3);
	vec3 color_d = vec3(0.8, 0.7, 0.1);
	vec3 color_e = vec3(1.0, 1.0, 1.0);

	t = clamp(t, 0.0, 1.0);

	if (t < 0.25) {
		float local_t = t * 4.0;
		final_color = mix(color_a, color_b, local_t);
	}
	else if (t < 0.5) {
		float local_t = (t - 0.25) * 4.0;
		final_color = mix(color_b, color_c, local_t);
	}
	else if (t < 0.75) {
		float local_t = (t - 0.5) * 4.0;
		final_color = mix(color_c, color_d, local_t);
	}
	else {
		float local_t = (t - 0.75) * 4.0;
		final_color = mix(color_d, color_e, local_t);
	}

    //COLOR = vec4(final_color, 1.0);
	COLOR = vec4(blurred.r, blurred.g, blurred.b, 1.0);
}