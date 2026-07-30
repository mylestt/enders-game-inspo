shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// UV-free, world-space triplanar blockout material. GreyGrid.png spans four metres so its
// four cells read as 1 m each; the brighter overlay repeats every 10 metres.
uniform sampler2D blockout_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 major_grid_color : source_color = vec4(0.82, 0.9, 1.0, 1.0);
uniform float texture_world_size = 4.0;
uniform float major_grid_size = 10.0;
uniform float roughness = 0.82;

varying vec3 world_position;
varying vec3 world_normal;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}


float grid_line(vec2 coordinate) {
	vec2 derivative = max(fwidth(coordinate), vec2(0.0001));
	vec2 distance_to_line = abs(fract(coordinate - 0.5) - 0.5) / derivative;
	return 1.0 - min(min(distance_to_line.x, distance_to_line.y), 1.0);
}


void fragment() {
	vec3 weights = pow(abs(normalize(world_normal)), vec3(8.0));
	weights /= max(weights.x + weights.y + weights.z, 0.0001);

	vec3 x_projection = texture(blockout_texture, world_position.yz / texture_world_size).rgb;
	vec3 y_projection = texture(blockout_texture, world_position.xz / texture_world_size).rgb;
	vec3 z_projection = texture(blockout_texture, world_position.xy / texture_world_size).rgb;
	vec3 major = vec3(
		grid_line(world_position.yz / major_grid_size),
		grid_line(world_position.xz / major_grid_size),
		grid_line(world_position.xy / major_grid_size)
	);

	float major_line = dot(major, weights);
	vec3 color = (
		x_projection * weights.x
		+ y_projection * weights.y
		+ z_projection * weights.z
	) * tint.rgb;
	color = mix(color, major_grid_color.rgb, major_line * 0.85);

	ALBEDO = color;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
