# rpg_overworld.gd
# The root script for the RPG overworld scene. Two responsibilities:
#
#   1. Drive the tier overlay shader. Whenever the Aesthetic autoload's
#      active tier changes (at startup, on a debug F1/F2/F3 press, or
#      later when a mod triggers a tier shift), we read the new tier's
#      AestheticTier Resource and push its palette + shader params into
#      the full-screen overlay's ShaderMaterial.
#
#   2. Host a pause menu with RPG-flavored options (Resume / Save /
#      Exit RPG). "Exit RPG" sets a one-shot `returning_from_rpg` flag
#      so the Real World knows to spawn the player next to the PC.
#
# Why load tier data into the shader from GDScript instead of binding
# the Resource directly?
#   GDScript has to hand the shader a fixed-size array of vec4s (the
#   palette). AestheticTier stores an Array[Color] of variable length.
#   We translate the Array[Color] -> PackedVector4Array once per tier
#   change. Doing the marshalling here also lets us clamp to the shader's
#   16-entry ceiling in one well-documented place.

extends Node2D

# --- Node References ---
# The ColorRect that covers the screen and runs the tier overlay shader.
# Its ShaderMaterial.shader_parameter/* fields are what we update.
@onready var tier_overlay: ColorRect = $TierOverlayLayer/TierOverlay
@onready var pause_menu = $PauseMenu
@onready var dialogue_box = $DialogueBox

# The shader uses a fixed 16-entry array; enforced here so we don't silently
# drop palette entries past index 15 without warning the designer.
const PALETTE_SHADER_SIZE: int = 16

# Mirrors ground_floor.gd's DialogMode. Tells the shared _on_choice_made /
# _on_dialogue_dismissed handlers which pause-flow they're resolving.
# Kept locally per-scene rather than in the autoload because only the owning
# scene needs to know about its own in-progress dialog.
enum DialogMode {
	NONE,                # No pause-flow dialog is currently showing
	PAUSE_SAVE_CONFIRM,  # "Save game? [Save] [Cancel]"
	PAUSE_SAVE_RESULT,   # "Game saved." single-page ack
}
var _dialog_mode: DialogMode = DialogMode.NONE


func _ready() -> void:
	# Apply the initial tier. This covers both a fresh RPG entry and any
	# case where the tier was set (e.g. by a debug key) before we loaded.
	_apply_current_tier()
	# Listen for future tier changes (debug keys now; mods later).
	Aesthetic.tier_changed.connect(_on_tier_changed)

	# Pause menu wiring.
	pause_menu.option_selected.connect(_on_pause_option)

	# DialogueBox wiring — used only by the Save confirmation flow in the
	# RPG. Future RPG content (NPCs, battle text) will reuse the same box.
	dialogue_box.choice_made.connect(_on_choice_made)
	dialogue_box.dismissed.connect(_on_dialogue_dismissed)


func _unhandled_input(event: InputEvent) -> void:
	# Escape opens the pause menu, unless another UI is already up.
	if event.is_action_pressed("pause"):
		if not pause_menu.is_open():
			_open_pause_menu()
			get_viewport().set_input_as_handled()
		return


# --- Tier application ---

func _on_tier_changed(_new_tier: Aesthetic.Tier) -> void:
	# We don't need the enum value — we just ask Aesthetic for whichever
	# tier is current. Simpler than passing it around.
	_apply_current_tier()


# Pulls the active tier's Resource from Aesthetic and pushes every piece
# of data into the shader. Called on startup and on each tier change.
func _apply_current_tier() -> void:
	var tier: AestheticTier = Aesthetic.get_palette()
	if tier == null:
		push_warning("rpg_overworld: no active tier to apply")
		return

	var mat: ShaderMaterial = tier_overlay.material as ShaderMaterial
	if mat == null:
		push_warning("rpg_overworld: TierOverlay has no ShaderMaterial")
		return

	# Build the palette array the shader expects. The shader takes vec4s
	# (rgba), so we convert each Color to a Vector4 of (r, g, b, a).
	# Entries beyond the shader's 16-slot cap are dropped with a warning
	# so it's obvious when a tier authoring mistake is silently losing data.
	var palette_source: Array[Color] = tier.palette
	var palette_count: int = min(palette_source.size(), PALETTE_SHADER_SIZE)
	if palette_source.size() > PALETTE_SHADER_SIZE:
		push_warning("Tier '%s' has %d palette entries — only the first %d are used."
			% [tier.tier_name, palette_source.size(), PALETTE_SHADER_SIZE])

	# Shader expects exactly 16 entries; pad unused slots with the first
	# color so the nearest-color loop never considers a stray (0,0,0,0).
	# palette_size (int uniform) is the real count.
	var packed: PackedVector4Array = PackedVector4Array()
	packed.resize(PALETTE_SHADER_SIZE)
	var pad_color: Color = palette_source[0] if palette_count > 0 else Color.BLACK
	for i in PALETTE_SHADER_SIZE:
		var c: Color = palette_source[i] if i < palette_count else pad_color
		packed[i] = Vector4(c.r, c.g, c.b, c.a)

	mat.set_shader_parameter("palette", packed)
	mat.set_shader_parameter("palette_size", maxi(palette_count, 1))
	mat.set_shader_parameter("pixel_scale", float(tier.pixel_scale))
	mat.set_shader_parameter("scanline_strength", tier.scanline_strength)
	mat.set_shader_parameter("scanline_frequency", tier.scanline_frequency)


# --- Pause Menu ---

func _open_pause_menu() -> void:
	# The RPG overworld doesn't currently have a CharacterBody2D-driven
	# player (the placeholder scene has a player instance but no enemies
	# or NPCs to pause against). We still pause the scene tree to keep
	# behavior consistent with Real World: anything we add later (timers,
	# random encounters, roaming enemies) will pause correctly.
	get_tree().paused = true
	# The pause menu itself has process_mode = ALWAYS (see pause_menu.tscn)
	# so it keeps running while the rest of the tree is paused.
	pause_menu.open([
		{"id": "resume",   "label": "Resume"},
		{"id": "save",     "label": "Save"},
		{"id": "exit_rpg", "label": "Exit RPG"},
	])


func _on_pause_option(id: String) -> void:
	match id:
		"resume":
			get_tree().paused = false
		"save":
			# Show a real confirmation dialog. We keep the tree paused so
			# the game behind the dialog stays frozen; _dialog_mode tells
			# _on_choice_made how to route the response.
			_dialog_mode = DialogMode.PAUSE_SAVE_CONFIRM
			dialogue_box.show_choice("Save game?", ["Save", "Cancel"])
		"exit_rpg":
			# One-shot flag the ground_floor scene reads on _ready to
			# spawn the player next to the PC in the Office.
			GameManager.set_flag("returning_from_rpg", true)
			# Must unpause before switching worlds, otherwise the newly
			# loaded Real World scene will also be paused.
			get_tree().paused = false
			GameManager.switch_to_world(GameManager.World.REAL_WORLD)


# --- DialogueBox callbacks (pause flow) ---

func _on_choice_made(index: int) -> void:
	match _dialog_mode:
		DialogMode.PAUSE_SAVE_CONFIRM:
			if index == 0: # Save
				SaveSystem.save_game()
				_dialog_mode = DialogMode.PAUSE_SAVE_RESULT
				dialogue_box.show_text("Game saved.")
			else: # Cancel — drop back to the pause menu where we came from
				_dialog_mode = DialogMode.NONE
				pause_menu.open([
					{"id": "resume",   "label": "Resume"},
					{"id": "save",     "label": "Save"},
					{"id": "exit_rpg", "label": "Exit RPG"},
				])


func _on_dialogue_dismissed() -> void:
	if _dialog_mode == DialogMode.PAUSE_SAVE_RESULT:
		# Save acknowledged — return to the pause menu so the player can
		# pick their next action (keep playing or exit).
		_dialog_mode = DialogMode.NONE
		pause_menu.open([
			{"id": "resume",   "label": "Resume"},
			{"id": "save",     "label": "Save"},
			{"id": "exit_rpg", "label": "Exit RPG"},
		])
