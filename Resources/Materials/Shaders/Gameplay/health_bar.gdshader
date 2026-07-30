// Overhead player health bar: a camera-facing quad whose left-to-right fill tracks the
// player's health. One shared ShaderMaterial for every player; the fill fraction and team
// color come in as per-instance uniforms (player.gd sets them with
// set_instance_shader_parameter), so no per-player materials are ever created.
// Depth-tested on purpose: enemy bars must not act as a wallhack.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

instance uniform vec4 bar_color : source_color = vec4(0.2, 0.95, 0.35, 1.0);
instance uniform float health_ratio : hint_range(0.0, 1.0) = 1.0;

void vertex() {
	// Billboard: face the camera while keeping the node's world position and scale.
	mat4 mv = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	mv = mv * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
	MODELVIEW_MATRIX = mv;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float filled = step(UV.x, health_ratio);
	vec3 empty_color = vec3(0.06, 0.06, 0.07);
	ALBEDO = mix(empty_color, bar_color.rgb, filled);
	ALPHA = mix(0.45, 0.92, filled);
}
