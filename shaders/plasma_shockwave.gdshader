shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 shell_color : source_color = vec4(0.32, 0.82, 1.0, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 64.0) = 14.0;

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - facing, 2.2);
	ALBEDO = shell_color.rgb;
	EMISSION = shell_color.rgb * emission_strength;
	ALPHA = rim * opacity * shell_color.a;
}
