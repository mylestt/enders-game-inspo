shader_type spatial;
render_mode blend_mix, cull_back, unshaded;

uniform vec4 glow_color : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float glow_power : hint_range(0.5, 8.0) = 2.5;
uniform float glow_intensity : hint_range(0.0, 5.0) = 1.8;
uniform float swirl_speed : hint_range(0.0, 5.0) = 0.6;

void fragment() {
	vec3 normal = normalize(NORMAL);
	vec3 view = normalize(VIEW);
	float fresnel = pow(1.0 - clamp(dot(normal, view), 0.0, 1.0), glow_power);

	float angle = TIME * swirl_speed;
	vec2 centered = UV - vec2(0.5);
	float s = sin(angle);
	float c = cos(angle);
	vec2 swirled = vec2(
		centered.x * c - centered.y * s,
		centered.x * s + centered.y * c
	);
	float swirl_pattern = sin((swirled.x + swirled.y) * 20.0) * 0.5 + 0.5;

	vec3 glow = glow_color.rgb * fresnel * glow_intensity * (0.7 + 0.3 * swirl_pattern);

	ALBEDO = glow;
}