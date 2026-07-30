shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// Shared by every tracer effect instance (streak, muzzle flash, AND impact sparks); all
// animation state is per-instance, so one material serves every live tracer with no
// per-frame mesh rebuilds or material mutation.
//
// The streak bakes its distance along the shot (metres) into UV.x and its tint into the
// vertex COLOR. The visible "window" [tail_distance, head_distance] slides along the shot
// each frame purely via these instance uniforms — geometry is built once per shot.
// Flash/spark meshes leave the window at its defaults (always visible) and animate with
// fade_alpha + node scale instead.

instance uniform float head_distance = 1e12;
instance uniform float tail_distance = -1e12;
instance uniform float fade_alpha : hint_range(0.0, 1.0) = 1.0;
instance uniform float emission_energy = 8.0;
// Hot leading edge: fragments within head_glow_length of the head get up to
// head_glow_boost extra emission. 0 disables (flash/sparks leave it 0).
instance uniform float head_glow_length = 0.0;
instance uniform float head_glow_boost = 0.0;

varying float along_shot;

void vertex() {
	along_shot = UV.x;
}

void fragment() {
	// 1 inside [tail, head], 0 outside — this replaces re-meshing the visible span.
	float inside = step(along_shot, head_distance) * step(tail_distance, along_shot);

	// Soften the trailing edge so the tail dissolves instead of ending in a hard cut.
	float span = max(head_distance - tail_distance, 0.001);
	float tail_soften = clamp((along_shot - tail_distance) / (span * 0.35), 0.0, 1.0);

	float head_hot = 0.0;

	if (head_glow_length > 0.001) {
		head_hot = head_glow_boost * clamp(1.0 - (head_distance - along_shot) / head_glow_length, 0.0, 1.0);
	}

	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emission_energy * (1.0 + head_hot) * fade_alpha;
	ALPHA = COLOR.a * fade_alpha * inside * tail_soften;
}
