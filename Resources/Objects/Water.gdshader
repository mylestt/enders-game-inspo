shader_type spatial;
// Godot 4.x
// "Retro Mirror Water" — chrome-y, hard-specular water like old HL2/UT99 quality mods.
// Key trick vs. modern PBR water: metallic is cranked way up, roughness is near zero,
// and the specular highlight is a hard non-physical blob instead of a soft GGX lobe.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_toon;

// ---------- Waves / Normals ----------
uniform sampler2D normal_map_1 : hint_normal, repeat_enable;
uniform sampler2D normal_map_2 : hint_normal, repeat_enable;
uniform float normal_tiling_1 : hint_range(0.1, 20.0) = 4.0;
uniform float normal_tiling_2 : hint_range(0.1, 20.0) = 6.0;
uniform vec2 scroll_speed_1 = vec2(0.03, 0.02);
uniform vec2 scroll_speed_2 = vec2(-0.02, 0.035);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.6;

// ---------- Color ----------
uniform vec4 shallow_color : source_color = vec4(0.15, 0.55, 0.55, 1.0);
uniform vec4 deep_color : source_color = vec4(0.01, 0.08, 0.12, 1.0);
uniform float depth_fade_distance : hint_range(0.1, 20.0) = 4.0;

// ---------- Reflectivity (the "chrome" part) ----------
uniform float metallic_value : hint_range(0.0, 1.0) = 0.95;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.03;
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.0;
uniform float fresnel_min : hint_range(0.0, 1.0) = 0.05;

// ---------- Hard old-school specular sun glint ----------
uniform float spec_hardness : hint_range(1.0, 256.0) = 120.0;
uniform float spec_intensity : hint_range(0.0, 8.0) = 3.0;
uniform vec4 spec_color : source_color = vec4(1.0, 0.98, 0.9, 1.0);

// ---------- Refraction / screen distortion ----------
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.04;

// ---------- Shore foam ----------
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float foam_distance : hint_range(0.0, 5.0) = 0.6;
uniform float foam_noise_scale : hint_range(0.5, 20.0) = 6.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// cheap hash-based noise for foam breakup, avoids needing an extra texture
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	float t = TIME;

	// --- blended scrolling normals ---
	vec2 uv1 = world_pos.xz * (1.0 / normal_tiling_1) + scroll_speed_1 * t;
	vec2 uv2 = world_pos.xz * (1.0 / normal_tiling_2) + scroll_speed_2 * t;
	vec3 n1 = texture(normal_map_1, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = texture(normal_map_2, uv2).rgb * 2.0 - 1.0;
	vec3 blended_normal = normalize(vec3(n1.xy + n2.xy, n1.z * n2.z));
	blended_normal.xy *= normal_strength;
	blended_normal = normalize(blended_normal);

	NORMAL_MAP = blended_normal * 0.5 + 0.5;

	// --- fresnel term (rim gets near-total reflection, like the old mods) ---
	float fresnel = fresnel_min + (1.0 - fresnel_min) * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);

	// --- depth-based refraction & color blend ---
	vec2 screen_uv = SCREEN_UV + blended_normal.xy * refraction_strength;
	float raw_depth = texture(depth_tex, screen_uv).r;
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= view_pos.w;
	float scene_depth = -view_pos.z;
	float pixel_depth = -VERTEX.z;
	float depth_diff = max(scene_depth - pixel_depth, 0.0);

	float depth_fade = clamp(depth_diff / depth_fade_distance, 0.0, 1.0);
	vec3 water_color = mix(shallow_color.rgb, deep_color.rgb, depth_fade);

	vec3 refracted = textureLod(screen_tex, screen_uv, 0.0).rgb;
	vec3 base_color = mix(refracted * water_color * 1.5, water_color, depth_fade * 0.6);

	// --- shore foam where geometry is close to the surface ---
	float foam_edge = 1.0 - clamp(depth_diff / max(foam_distance, 0.001), 0.0, 1.0);
	float foam_break = hash(floor(world_pos.xz * foam_noise_scale) + floor(t * 2.0));
	float foam_mask = smoothstep(0.55, 1.0, foam_edge) * step(0.25, foam_break);

	vec3 final_albedo = mix(base_color, foam_color.rgb, foam_mask);

	ALBEDO = final_albedo;
	METALLIC = metallic_value;
	ROUGHNESS = roughness_value;
	SPECULAR = 1.0;

	// stronger alpha near shore/foam, glassy elsewhere
	ALPHA = mix(mix(0.85, 1.0, depth_fade), 1.0, foam_mask);
	// boost apparent reflectivity at grazing angles via emission-free fresnel push
	ALBEDO = mix(final_albedo, final_albedo * 0.4, fresnel * 0.5);
}

// Custom hard specular highlight — this is the "old mod" signature look:
// a tight, bright, non-physical blob instead of a soft PBR lobe.
void light() {
	vec3 H = normalize(VIEW + LIGHT);
	float NdotH = clamp(dot(NORMAL, H), 0.0, 1.0);
	float spec = pow(NdotH, spec_hardness) * spec_intensity;

	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	SPECULAR_LIGHT += spec_color.rgb * spec * LIGHT_COLOR * ATTENUATION;
}
