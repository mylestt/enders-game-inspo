shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded, depth_draw_opaque;

uniform vec4 disk_color_hot : source_color = vec4(1.0, 0.95, 0.7, 1.0);
uniform vec4 disk_color_cool : source_color = vec4(0.9, 0.25, 0.05, 1.0);
// Both radii are in LOCAL mesh units — tune relative to your PlaneMesh's Size.
uniform float inner_radius : hint_range(0.0, 5.0) = 0.6;
uniform float outer_radius : hint_range(0.1, 10.0) = 3.0;
uniform float swirl_strength : hint_range(0.0, 40.0) = 12.0;
uniform float swirl_speed : hint_range(0.0, 5.0) = 1.2;
uniform float band_count : hint_range(1.0, 40.0) = 14.0;
uniform float brightness : hint_range(0.0, 5.0) = 1.6;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	// Polar coordinates directly from the plane's own local space (XZ, since PlaneMesh
	// lies flat there) — no UV pinching issues like wrapping this onto a sphere would have.
	float radius = length(local_pos.xz);
	float angle = atan(local_pos.z, local_pos.x);

	// Tighter swirl closer to the core (differential rotation), rotating continuously.
	float swirl = swirl_strength / (radius + 0.15) - TIME * swirl_speed;
	angle += swirl;

	float bands = sin(angle * band_count) * 0.5 + 0.5;

	// Fade in from outer_radius inward, fade out again approaching inner_radius (the
	// disk doesn't extend all the way to the core — real accretion disks have a gap).
	float outer_mask = smoothstep(outer_radius, outer_radius * 0.7, radius);
	float inner_mask = smoothstep(inner_radius, inner_radius * 1.6, radius);
	float visible = outer_mask * inner_mask;

	float heat = 1.0 - clamp((radius - inner_radius) / max(outer_radius - inner_radius, 0.001), 0.0, 1.0);
	vec3 color = mix(disk_color_cool.rgb, disk_color_hot.rgb, bands * heat);
	color = mix(color, disk_color_hot.rgb, heat * heat * 0.5);

	ALBEDO = color * brightness;
	ALPHA = visible;
}