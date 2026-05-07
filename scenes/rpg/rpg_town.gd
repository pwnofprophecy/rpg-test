# rpg_town.gd
# Root script for the RPG Town scene. The town is a small "safe zone"
# inside the RPG world — no random encounters, just NPCs to talk to and
# a single exit that returns the player to the overworld.
#
# This script intentionally mirrors a lot of rpg_overworld.gd's structure
# (tier overlay, pause menu, dialogue box, hint label, interactable
# routing). For now we duplicate that boilerplate so each location
# script reads top-to-bottom; if a third location lands later we'll
# refactor the shared parts into a base class.
#
# What the town owns:
#   1. Tier overlay shader (palette / pixel scale / scanlines).
#   2. Pause menu — same Resume / Save / Exit RPG options as the overworld.
#      "Exit RPG" resets the RPG location back to OVERWORLD so the next
#      time the player returns to the RPG they don't reappear in town.
#   3. Dialogue box — used for both NPC conversations and the save flow.
#   4. NPCs — Area2D + Interactable nodes the player can talk to. Their
#      dialogue is set via interaction_pages on the Interactable in the
#      .tscn, so you can edit text in the Godot Inspector without
#      touching this script.
#   5. Town exit — an Interactable with interaction_id = "town_exit"
#      that switches back to the overworld when the player presses Enter.

extends Node2D

# --- Node References ---
@onready var tier_overlay: ColorRect = $TierOverlayLayer/TierOverlay
@onready var pause_menu = $PauseMenu
@onready var dialogue_box = $DialogueBox
@onready var player: Node2D = $Player
# Optional Label that pops up when the player is standing in an
# interactable's zone (e.g. "[Interact] to talk" / "[Interact] to leave town").
@onready var interact_hint: Label = $HintLayer/InteractHint if has_node("HintLayer/InteractHint") else null

# --- Interactable proximity state ---
# The Interactable the player is currently inside, or null. Set in
# _on_zone_entered, cleared in _on_zone_exited, read by _unhandled_input
# when the player presses Enter.
var _current_zone: Interactable = null

# --- Shader constants ---
const PALETTE_SHADER_SIZE: int = 16

# --- DialogMode (pause flow + NPC text routing) ---
# NPC_TEXT exists so we can tell whether a dialogue dismissal came from
# an NPC line (no special handling needed) versus the save-result text
# (which should re-open the pause menu underneath it).
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

	# Pause menu wiring.
	pause_menu.option_selected.connect(_on_pause_option)

	# DialogueBox wiring (handles save-confirm flow AND NPC text dismissal).
	dialogue_box.choice_made.connect(_on_choice_made)
	dialogue_box.dismissed.connect(_on_dialogue_dismissed)

	# Auto-discover every Interactable anywhere under this scene and connect
	# its proximity signals. Recursive so NPCs can be wrapped in a Node2D
	# parent (e.g. to attach y_sorter.gd) without breaking the search. Add
	# new NPCs and exits in the editor without ever touching this script —
	# just attach interactable.gd to an Area2D and fill in its
	# interaction_id / interaction_pages / hint_text in the Inspector.
	for ix in find_children("*", "Interactable", true, false):
		var zone: Interactable = ix as Interactable
		if zone == null:
			continue
		zone.player_entered_zone.connect(_on_zone_entered)
		zone.player_left_zone.connect(_on_zone_exited)


func _unhandled_input(event: InputEvent) -> void:
	# Escape opens the pause menu, unless another UI is already up.
	if event.is_action_pressed("pause"):
		if not pause_menu.is_open() and not dialogue_box.is_open():
			_open_pause_menu()
			get_viewport().set_input_as_handled()
		return

	# Enter triggers whatever interactable the player is standing in
	# (NPC, exit, etc.), provided no UI is blocking. The dialogue box
	# and pause menu both consume input themselves while open, so we
	# only need to guard explicitly against those.
	if event.is_action_pressed("ui_accept"):
		if _current_zone != null and not pause_menu.is_open() and not dialogue_box.is_open():
			_trigger_zone(_current_zone)
			get_viewport().set_input_as_handled()
		return


# --- Tier application ---

func _on_tier_changed(_new_tier: Aesthetic.Tier) -> void:
	_apply_current_tier()


func _apply_current_tier() -> void:
	var tier: AestheticTier = Aesthetic.get_palette()
	if tier == null:
		push_warning("rpg_town: no active tier to apply")
		return

	var mat: ShaderMaterial = tier_overlay.material as ShaderMaterial
	if mat == null:
		push_warning("rpg_town: TierOverlay has no ShaderMaterial")
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


# --- Pause Menu ---

func _open_pause_menu() -> void:
	get_tree().paused = true
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
			_dialog_mode = DialogMode.PAUSE_SAVE_CONFIRM
			dialogue_box.show_choice("Save game?", ["Save", "Cancel"])
		"exit_rpg":
			# Going back to the Real World from town. Reset the RPG
			# location to OVERWORLD so next time the player enters the
			# RPG (via the PC) they spawn on the overworld map, not back
			# in this town. Also clear the saved overworld return
			# position — they're starting a fresh RPG entry.
			GameManager.set_flag("returning_from_rpg", true)
			GameManager.rpg_location = GameManager.RPGLocation.OVERWORLD
			GameManager.overworld_return_position = Vector2.ZERO
			get_tree().paused = false
			GameManager.switch_to_world(GameManager.World.REAL_WORLD)


# --- DialogueBox callbacks ---

func _on_choice_made(index: int) -> void:
	# Currently the only choice flow in town is the save-confirm prompt.
	# When NPCs gain branching dialogue we'll route by _dialog_mode here too.
	match _dialog_mode:
		DialogMode.PAUSE_SAVE_CONFIRM:
			if index == 0:
				SaveSystem.save_game()
				_dialog_mode = DialogMode.PAUSE_SAVE_RESULT
				dialogue_box.show_text("Game saved.")
			else:
				_dialog_mode = DialogMode.NONE
				pause_menu.open([
					{"id": "resume",   "label": "Resume"},
					{"id": "save",     "label": "Save"},
					{"id": "exit_rpg", "label": "Exit RPG"},
				])


func _on_dialogue_dismissed() -> void:
	# Save-result text was acknowledged → return the player to the pause menu.
	# All other dismissals (NPC chatter, etc.) just clear the mode flag.
	if _dialog_mode == DialogMode.PAUSE_SAVE_RESULT:
		_dialog_mode = DialogMode.NONE
		pause_menu.open([
			{"id": "resume",   "label": "Resume"},
			{"id": "save",     "label": "Save"},
			{"id": "exit_rpg", "label": "Exit RPG"},
		])
	else:
		_dialog_mode = DialogMode.NONE


# --- Interactable zone tracking ---

func _on_zone_entered(zone: Interactable) -> void:
	_current_zone = zone
	_show_hint(zone.hint_text)


func _on_zone_exited(zone: Interactable) -> void:
	# Only clear if it's the zone we last entered — guards against an
	# overlap-then-walk-out from a different zone clobbering us.
	if _current_zone == zone:
		_current_zone = null
		_show_hint("")


func _show_hint(text: String) -> void:
	# Single point of control for the hint label. Empty text hides it.
	if interact_hint == null:
		return
	if text == "":
		interact_hint.visible = false
	else:
		interact_hint.text = text
		interact_hint.visible = true


# --- Interaction routing ---

func _trigger_zone(zone: Interactable) -> void:
	# Special-case zones routed by interaction_id (e.g. the exit). Anything
	# else falls through to the generic NPC text path, which reads
	# interaction_pages / interaction_text off the Interactable directly.
	# That means new NPCs only need an interaction_id + dialogue text in
	# the Inspector — no script change required.
	match zone.interaction_id:
		"town_exit":
			# Hide the hint immediately so it doesn't flash for a frame on
			# the overworld before the player walks out of the entrance zone.
			_show_hint("")
			GameManager.switch_rpg_location(GameManager.RPGLocation.OVERWORLD)
		_:
			_show_npc_dialogue(zone)


func _show_npc_dialogue(zone: Interactable) -> void:
	# interaction_pages takes priority over interaction_text. If neither
	# is set, fall back to a placeholder so we know which NPC needs text.
	_dialog_mode = DialogMode.NPC_TEXT
	if not zone.interaction_pages.is_empty():
		dialogue_box.show_text(zone.interaction_pages)
	elif zone.interaction_text != "":
		dialogue_box.show_text(zone.interaction_text)
	else:
		dialogue_box.show_text("(This NPC has no dialogue set on its Interactable.)")
