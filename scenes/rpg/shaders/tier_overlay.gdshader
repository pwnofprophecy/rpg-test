// tier_overlay.gdshader
// A full-screen post-processing shader that "re-skins" whatever the RPG
// scene drew underneath it. Runs on a ColorRect that covers the entire
// viewport and sits above the game content on its own CanvasLayer.
//
// What it does, in order:
//   1. Pixelate the screen by snapping UV coords to a grid of size
//      `pixel_scale` pixels. Higher scale = chunkier, more Gameboy-feeling
//      output.
//   2. Sample the game's rendered backbuffer at that snapped coord.
//   3. Walk the tier's palette and find the nearest color to that sample,
//      using simple squared-distance in RGB. Replace the sampled color
//      with that palette entry. This is what gives the Gameboy / NES /
//      SNES their distinct palette looks.
//   4. Modulate the result with a horizontal scanline pattern for a faint
//      CRT shimmer.
//
// How the tier script feeds data in:
//   rpg_overworld.gd pushes uniforms whenever the Aesthetic.tier_changed
//   signal fires: palette[], palette_size, pixel_scale, scanline_strength,
//   scanline_frequency. All of those are read from the active AestheticTier
//   Resource (res://resources/tiers/*.tres).
//
// Limits:
//   The palette array is fixed at 16 entries (GLSL requires compile-time
//   sizes for uniform arrays). If a tier defines fewer, the unused slots
//   are ignored via `palette_size`. If a tier defines more, only the first
//   16 are passed in.
shader_type canvas_item;

// Godot-provided handle to the screen as it was rendered UNDER this overlay.
// hint_screen_texture wires this up automatically; filter_nearest keeps the
// pixelation crisp instead of blurring it.
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

// The active tier's color palette. Up to 16 entries used; extras ignored.
uniform vec4 palette[16];
// How many entries in `palette` are actually valid. Keeps the color-match
// loop from considering unused slots (which would all be (0,0,0,0) and
// unfairly win the nearest-color contest).
uniform int palette_size : hint_range(1, 16) = 4;

// Pixelation grid size in screen pixels. 1.0 = native, 6.0 = Gameboy-ish.
uniform float pixel_scale : hint_range(1.0, 16.0) = 1.0;

// Scanline intensity (0 = off, 1 = heavy dark stripes).
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.2;

// Scanline density. Higher = more, finer lines.
uniform float scanline_frequency : hint_range(50.0, 600.0) = 300.0;


// Returns the palette entry closest to `color` in RGB space.
// Distance is squared (we skip the sqrt — it doesn't change which entry
// wins, and we save a square root per pixel).
vec3 nearest_palette_color(vec3 color) {
	vec3 best = palette[0].rgb;
	float best_dist = dot(color - best, color - best);
	// Fixed upper bound (16) because GLSL needs constant loop bounds. The
	// `i < palette_size` check inside breaks out early for shorter palettes.
	for (int i = 1; i < 16; i++) {
		if (i >= palette_size) {
			break;
		}
		vec3 p = palette[i].rgb;
		float d = dot(color - p, color - p);
		if (d < best_dist) {
			best = p;
			best_dist = d;
		}
	}
	return best;
}


void fragment() {
	// 1. Pixelate: snap SCREEN_UV to a grid of `pixel_scale`-sized cells.
	//    SCREEN_PIXEL_SIZE is the size of one screen pixel in UV space, so
	//    multiplying by `pixel_scale` gives us the target cell size.
	vec2 cell_size = SCREEN_PIXEL_SIZE * pixel_scale;
	vec2 snapped_uv = floor(SCREEN_UV / cell_size) * cell_size;

	// 2. Sample the backbuffer at the snapped coord. This produces the
	//    "chunky pixels" look.
	vec3 sampled = texture(screen_texture, snapped_uv).rgb;

	// 3. Force the sample onto the tier's palette.
	vec3 quantized = nearest_palette_color(sampled);

	// 4. Overlay a horizontal scanline shimmer. We use sin() of the Y UV
	//    coord scaled by the frequency — the result oscillates between
	//    -1 and 1, and we remap to 0..1 so darker stripes show up.
	float scanline = sin(SCREEN_UV.y * scanline_frequency) * 0.5 + 0.5;
	vec3 final_color = quantized * (1.0 - (scanline_strength * (1.0 - scanline)));

	COLOR = vec4(final_color, 1.0);
}
