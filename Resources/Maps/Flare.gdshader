shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, cull_disabled;

uniform sampler2D texture_albedo : source_color;
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_luminance_alpha = true;

void vertex() {
	// Extract the object's scale from MODEL_MATRIX before we overwrite rotation
	vec3 obj_scale = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);

	mat4 billboard_matrix = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);

	// Reapply scale to the billboard's rotation columns
	billboard_matrix[0].xyz *= obj_scale.x;
	billboard_matrix[1].xyz *= obj_scale.y;
	billboard_matrix[2].xyz *= obj_scale.z;

	MODELVIEW_MATRIX = billboard_matrix;
}

void fragment() {
	vec4 tex = texture(texture_albedo, UV);

	float alpha;
	if (use_luminance_alpha) {
		alpha = max(tex.r, max(tex.g, tex.b));
	} else {
		alpha = tex.a;
	}

	ALBEDO = tex.rgb * tint_color.rgb;
	ALPHA = alpha * tint_color.a;
}