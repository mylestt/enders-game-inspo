shader_type spatial;

// Fullbright UNLIT skybox-face shader for the SpinSpaceBall — a UV-unwrapped inverted
// cube-sphere with one mesh surface per cube face. Put one instance of this on each of the
// six surface material slots, each with that face's image in `albedo_texture`. The mesh's
// own per-face UVs (each spanning 0..1) place the image, so this just samples straight by
// UV — the six faces together read as a 6-sided cube map. No lighting, no shadows.
//
// render_mode breakdown:
//   unshaded          — no lighting at all; the texel is drawn exactly as authored (fullbright).
//   shadows_disabled  — casts no shadows.
//   fog_disabled      — the sky is never fogged.
//   cull_disabled     — visible from inside the inverted sphere no matter the winding.
//   depth_draw_never  — Z-WRITE OFF: never writes depth, so it can never occlude the station;
//                       being drawn without writing depth, the arena (closer to the camera)
//                       always draws over it and it reads as the backdrop behind everything.
//
// To instead force it ON TOP of everything (a true foreground overlay), add
// `depth_test_disabled` to the render_mode line — but note that with the SpinningSkybox rig
// centring it on the camera, that fills the whole view with sky and hides the station.
render_mode unshaded, shadows_disabled, fog_disabled, cull_disabled, depth_draw_never;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
// Multiplies the face — RGB tints/brightens, A fades the whole sky in/out.
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = tex.rgb * tint.rgb;
	ALPHA = tex.a * tint.a;
}
