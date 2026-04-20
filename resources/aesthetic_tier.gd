# aesthetic_tier.gd
# A Resource that describes one visual "tier" of the RPG-within-a-game:
# Gameboy, NES, SNES, or any future era we want to add. The Aesthetic
# autoload switches which tier is active; the RPG scene(s) read fields from
# the active tier and reconfigure their shader and palette accordingly.
#
# How tiers are authored:
#   - Create a .tres file (File > New Resource > AestheticTier in the editor,
#     or edit the text directly).
#   - Fill in the exported fields in the Inspector.
#   - Save under res://resources/tiers/<tier_name>.tres
#
# How tiers are consumed:
#   The `Aesthetic` autoload exposes `get_palette()` which returns the
#   currently-active AestheticTier. Any scene that wants to re-skin itself
#   listens to `Aesthetic.tier_changed(new_tier)` and pulls new values.
#
# When real assets arrive:
#   This Resource grows to also reference tileset/sprite/font resources.
#   The plumbing (signal + autoload lookup) doesn't change — each new field
#   just becomes another @export line here and another .tres entry.

class_name AestheticTier
extends Resource

# Human-readable name shown in debug output / future UI.
@export var tier_name: String = "Untitled"

# The palette used by the tier overlay shader. Every pixel of the rendered
# RPG is snapped to the nearest color in this list, which is what actually
# sells the era difference visually (4-green Gameboy vs. many-color SNES).
#
# Size note: the overlay shader is hard-coded to sample up to 16 entries
# for performance. If the palette has fewer entries, that's fine — we pass
# the real size as a separate uniform and the shader stops there. If it has
# more than 16, only the first 16 are used.
@export var palette: Array[Color] = []

# How "chunky" the image looks. The shader snaps UVs to a grid of this
# size before sampling, effectively downsampling the output.
#   1 = native (no pixelation beyond whatever the game already renders at)
#   2–4 = NES-ish feel
#   6+ = Gameboy-ish feel
# We can't truly replicate real handheld resolution without sprite art to
# match, but this at least gives a visibly different texture per tier.
@export var pixel_scale: int = 1

# How pronounced the horizontal scanline effect is. 0 = invisible, 1 = very
# strong. Gameboy real hardware didn't really have scanlines, but a faint
# CRT shimmer sells the "game inside a game" fiction so we keep some on
# every tier.
@export_range(0.0, 1.0) var scanline_strength: float = 0.25

# How many scanlines are drawn across the screen. Higher = denser stripes.
# Tuning this per tier lets NES/SNES feel distinct from Gameboy without
# needing different shaders.
@export var scanline_frequency: float = 300.0
