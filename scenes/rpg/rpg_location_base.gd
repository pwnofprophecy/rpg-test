# rpg_location_base.gd
# Shared base class for every RPG "location" scene — the overworld, the
# town, and (later) the dungeon. Each location's root Node2D script
# `extends RPGLocationBase` and inherits all the common machinery:
#
#   - Tier overlay shader (palette / pixel scale / scanlines)
#   - Pause menu + the Save-confirm dialog flow
#   - Camera snap-on-load (avoids inheriting the previous scene's framing)
#   - The [Interact] hint label helper
#   - Exit-RPG handling
#
# Subclasses add ONLY their unique gameplay by overriding the virtual
# hooks below — they never touch _ready or _unhandled_input directly:
#
#   _location_ready()              — per-location setup, runs in _ready
#                                    BEFORE the camera snap (so anything
#                                    that repositions the player happens
#                                    first).
#   _handle_location_input(event)  — per-location input (after the base
#                                    has handled the pause key).
#   _can_open_pause() -> bool       — whether the pause menu may open
#                                    right now (override to add blockers
#                                    like the name-entry overlay).
#
# Every location scene is expected to have these nodes at these paths:
#   TierOverlayLayer/TierOverlay, PauseMenu, DialogueBox, Player,
#   Player/Camera2D (optional), HintLayer/InteractHint (optional).

class_name RPGLocationBase
extends Node2D

# --- Shared node references ---
@onready var tier_overlay: ColorRect = $TierOverlayLayer/TierOverlay
@onready var pause_menu = $PauseMenu
@onready var dialogue_box = $DialogueBox
@onready var player: Node2D = $Player
# Optional Camera2D child of the player. Snapped on load so smoothing
# doesn't show a stale viewport position inherited from the previous
# scene. has_node-guarded so a camera-less test scene still loads.
@onready var player_camera: Camera2D = $Player/Camera2D if has_node("Player/Camera2D") else null
# Optional "[Interact] to ..." hint label. has_node-guarded so the
# scene loads even before the HintLayer is added.
@onready var interact_hint: Label = $HintLayer/InteractHint if has_node("HintLayer/InteractHint") else null

# --- Shader constants ---
const PALETTE_SHADER_SIZE: int = 16

# --- Dialog flow routing ---
# Shared by the pause/save flow. NPC_TEXT is used by the town for
# plain NPC chatter — the base just clears the mode on dismissal,
# which is the correct behavior for it.
enum DialogMode {
	NONE,
	PAUSE_SAVE_CONFIRM,
	PAUSE_SAVE_RESULT,
	NPC_TEXT,
}
var _dialog_mode: DialogMode = DialogMode.NONE


func _ready() -> void:
	# Apply the initial tier and listen for future tier changes.
	_apply_current_tier()
	Aesthetic.tier_changed.connect(_on_tier_changed)

	# Pause menu + dialogue box wiring (shared by every location).
	pause_menu.option_selected.connect(_on_pause_option)
	dialogue_box.choice_made.connect(_on_choice_made)
	dialogue_box.dismissed.connect(_on_dialogue_dismissed)

	# Per-location setup runs BEFORE the camera snap so anything that
	# repositions the player (e.g. the overworld restoring a saved
	# position) happens first; _snap_camera then frames the final spot.
	_location_ready()
	_snap_camera()


func _unhandled_input(event: InputEvent) -> void:
	# Escape opens the pause menu, unless a blocking UI is already up.
	if event.is_action_pressed("pause"):
		if _can_open_pause():
			_open_pause_menu()
			get_viewport().set_input_as_handled()
		return
	# Everything else is location-specific.
	_handle_location_input(event)


# --- Virtual hooks (override in subclasses) ---

# Per-location _ready setup. Default does nothing.
func _location_ready() -> void:
	pass


# Per-location input handling (after the base consumes the pause key).
# Default does nothing.
func _handle_location_input(_event: InputEvent) -> void:
	pass


# Whether the pause menu is allowed to open right now. Default blocks
# while the pause menu or dialogue box is already up. Override and AND
# in extra blockers (e.g. `and _name_entry_instance == null`).
func _can_open_pause() -> bool:
	return not pause_menu.is_open() and not dialogue_box.is_open()


# --- Tier overlay ---

func _on_tier_changed(_new_tier: Aesthetic.Tier) -> void:
	_apply_current_tier()


func _apply_current_tier() -> void:
	var tier: AestheticTier = Aesthetic.get_palette()
	if tier == null:
		push_warning("%s: no active tier to apply" % name)
		return

	var mat: ShaderMaterial = tier_overlay.material as ShaderMaterial
	if mat == null:
		push_warning("%s: TierOverlay has no ShaderMaterial" % name)
		return

	var palette_source: Array[Color] = tier.palette
	var palette_count: int = min(palette_source.size(), PALETTE_SHADER_SIZE)
	if palette_source.size() > PALETTE_SHADER_SIZE:
		push_warning("Tier '%s' has %d palette entries — only the first %d are used."
			% [tier.tier_name, palette_source.size(), PALETTE_SHADER_SIZE])

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


# --- Camera ---

# Forces the player's Camera2D to be the active one and snaps its
# smoothed position to the player immediately. Prevents the viewport
# from inheriting the previous scene's camera framing during the
# one-frame overlap of a scene swap, and collapses any post-reposition
# slide into a single frame.
func _snap_camera() -> void:
	if player_camera != null:
		player_camera.make_current()
		player_camera.reset_smoothing()


# --- Pause menu ---

# The option list every location's pause menu shows. Returned fresh
# each call so callers never share a mutable array.
func _pause_options() -> Array:
	return [
		{"id": "resume",   "label": "Resume"},
		{"id": "save",     "label": "Save"},
		{"id": "exit_rpg", "label": "Exit RPG"},
	]


func _open_pause_menu() -> void:
	get_tree().paused = true
	pause_menu.open(_pause_options())


func _on_pause_option(id: String) -> void:
	match id:
		"resume":
			get_tree().paused = false
		"save":
			_dialog_mode = DialogMode.PAUSE_SAVE_CONFIRM
			dialogue_box.show_choice("Save game?", ["Save", "Cancel"])
		"exit_rpg":
			_exit_rpg()


# Leaves the RPG back to the Real World. Resets the RPG location to
# OVERWORLD and clears the saved overworld return position so the next
# RPG entry (via the PC) starts fresh at the overworld's default spawn
# rather than dropping back into this sub-location. Harmless when
# called from the overworld (it's already OVERWORLD).
func _exit_rpg() -> void:
	GameManager.set_flag("returning_from_rpg", true)
	GameManager.rpg_location = GameManager.RPGLocation.OVERWORLD
	GameManager.overworld_return_position = Vector2.ZERO
	get_tree().paused = false
	GameManager.switch_to_world(GameManager.World.REAL_WORLD)


# --- Dialogue box callbacks (save flow) ---

func _on_choice_made(index: int) -> void:
	match _dialog_mode:
		DialogMode.PAUSE_SAVE_CONFIRM:
			if index == 0:
				SaveSystem.save_game()
				_dialog_mode = DialogMode.PAUSE_SAVE_RESULT
				dialogue_box.show_text("Game saved.")
			else:
				_dialog_mode = DialogMode.NONE
				pause_menu.open(_pause_options())


func _on_dialogue_dismissed() -> void:
	# Save-result text acknowledged → return to the pause menu. Any
	# other dismissal (NPC chatter, etc.) just clears the mode flag.
	if _dialog_mode == DialogMode.PAUSE_SAVE_RESULT:
		_dialog_mode = DialogMode.NONE
		pause_menu.open(_pause_options())
	else:
		_dialog_mode = DialogMode.NONE


# --- Hint label ---

func _show_hint(text: String) -> void:
	# Single point of control for the hint label. Empty text hides it.
	# No-ops if the HintLayer/InteractHint node isn't in the scene.
	if interact_hint == null:
		return
	if text == "":
		interact_hint.visible = false
	else:
		interact_hint.text = text
		interact_hint.visible = true
