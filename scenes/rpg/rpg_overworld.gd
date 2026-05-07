# rpg_overworld.gd
# The root script for the RPG overworld scene. Responsibilities:
#
#   1. Drive the tier overlay shader (palette / pixel scale / scanlines).
#   2. Host a pause menu with RPG-flavored options (Resume / Save / Exit RPG).
#   3. On first entry, show the name entry screen so the player can name
#      their Hero. Subsequent entries skip it.
#   4. Count player "steps" across the overworld and trigger random
#      encounters every N steps (range tunable in the Inspector). In sub-
#      phase 3a this just prints "Encounter!" — the battle scene hook lands
#      in sub-phase 3c.
#   5. Expose NodePath slots for the TownEntrance and DungeonEntrance Area2Ds
#      you place in the scene. Empty paths are fine — those hooks simply go
#      unwired. That lets the scene be rebuilt incrementally without
#      breaking the game.

extends Node2D

# --- Node References ---
@onready var tier_overlay: ColorRect = $TierOverlayLayer/TierOverlay
@onready var pause_menu = $PauseMenu
@onready var dialogue_box = $DialogueBox
@onready var player: Node2D = $Player
# Optional Label that pops up when the player is standing in an entrance,
# showing the entrance's per-instance hint_text. Wrapped in @onready so the
# scene still loads if the HintLayer hasn't been added yet — we just skip
# show/hide calls when it's null.
@onready var interact_hint: Label = $HintLayer/InteractHint if has_node("HintLayer/InteractHint") else null

# --- Inspector-editable: Entrances ---
# Drag your hand-placed Area2D nodes into these slots in the Inspector.
# Each node must have the `interactable.gd` script attached (it extends
# Area2D), with its `interaction_id` set to "town_entrance" or
# "dungeon_entrance" so we know which one fired when the player presses
# Enter. Leave the paths empty while you're still building the scene —
# the game will run fine without them wired.
@export_node_path("Area2D") var town_entrance_path: NodePath
@export_node_path("Area2D") var dungeon_entrance_path: NodePath

# --- Entrance proximity state ---
# The Interactable the player is currently standing inside, or null. We set
# this in player_entered_zone and clear it in player_left_zone, then read
# it in _unhandled_input when the player presses Enter to decide what to do.
var _current_entrance: Interactable = null

# --- Inspector-editable: Encounter tuning ---
# Encounters fire after a random number of steps in [min, max]. Tune these
# while playtesting until encounter density feels right.
@export_range(1, 50) var min_steps_between_encounters: int = 5
@export_range(1, 100) var max_steps_between_encounters: int = 15
# How many world-units of player movement count as one "step". 32 roughly
# matches a tile-width, which is a familiar JRPG feel.
@export_range(8.0, 128.0) var step_distance: float = 32.0

# --- Shader constants ---
const PALETTE_SHADER_SIZE: int = 16

# --- DialogMode (pause flow routing) ---
enum DialogMode {
	NONE,
	PAUSE_SAVE_CONFIRM,
	PAUSE_SAVE_RESULT,
}
var _dialog_mode: DialogMode = DialogMode.NONE

# --- Encounter stepper state ---
# Accumulates distance between _process frames, converting to discrete
# "steps" every time it crosses step_distance. _steps_until_encounter
# counts down per step; at 0 we fire an encounter and re-roll.
var _distance_since_last_step: float = 0.0
var _steps_until_encounter: int = 0
var _last_player_pos: Vector2 = Vector2.ZERO
# Disabled while the name entry dialog is up (or if entrances are walking
# the player through a scripted transition later).
var _stepper_enabled: bool = false

# Name entry is instanced dynamically so the scene file doesn't have to
# keep a hidden copy at all times.
const NAME_ENTRY_SCENE: PackedScene = preload("res://scenes/rpg/name_entry.tscn")
var _name_entry_instance: CanvasLayer = null


func _ready() -> void:
	# Apply the initial tier and listen for future tier changes.
	_apply_current_tier()
	Aesthetic.tier_changed.connect(_on_tier_changed)

	# Pause menu wiring.
	pause_menu.option_selected.connect(_on_pause_option)

	# DialogueBox wiring (save confirm flow, future NPC text).
	dialogue_box.choice_made.connect(_on_choice_made)
	dialogue_box.dismissed.connect(_on_dialogue_dismissed)

	# Wire entrance triggers if the designer has assigned them. The handlers
	# now just track proximity — the actual "enter the area" trigger fires
	# from _unhandled_input when the player presses ui_accept while inside.
	_connect_entrance(town_entrance_path)
	_connect_entrance(dungeon_entrance_path)

	# If the player is returning from a sub-location (town/dungeon), drop
	# them back where they were standing. Vector2.ZERO is the "no saved
	# position" sentinel — first entry from the Real World hits this case
	# and the player stays at the scene's default spawn point.
	if player != null and GameManager.overworld_return_position != Vector2.ZERO:
		player.global_position = GameManager.overworld_return_position
		# Consume the saved position so a fresh entry from the Real World
		# next time uses the default spawn instead of stale data.
		GameManager.overworld_return_position = Vector2.ZERO

	# Seed the stepper with the player's current position so the first
	# frame doesn't register a huge distance delta.
	if player != null:
		_last_player_pos = player.global_position
	_roll_next_encounter()

	# First-entry check: if the Hero hasn't been named yet, show the name
	# entry overlay and keep the stepper disabled until it closes.
	if RPGState.character_name == "":
		_open_name_entry()
	else:
		_stepper_enabled = true


func _unhandled_input(event: InputEvent) -> void:
	# Escape opens the pause menu, unless another UI is already up.
	if event.is_action_pressed("pause"):
		if not pause_menu.is_open() and _name_entry_instance == null:
			_open_pause_menu()
			get_viewport().set_input_as_handled()
		return

	# Enter triggers the current entrance, if the player is standing inside
	# one and no UI is blocking. Pause menu and dialogue box consume input
	# themselves when open, so we mostly just need to guard against name
	# entry being up (it doesn't consume scene-level ui_accept).
	if event.is_action_pressed("ui_accept"):
		if _current_entrance != null and not pause_menu.is_open() and _name_entry_instance == null:
			_trigger_entrance(_current_entrance)
			get_viewport().set_input_as_handled()
		return


func _process(_delta: float) -> void:
	# Step-based encounter counter. Distance-based rather than frame-based
	# so that standing still or holding against a wall doesn't rack up
	# steps. Runs unconditionally at the top so we bail cheaply when the
	# stepper is off.
	if not _stepper_enabled or player == null:
		return

	var current: Vector2 = player.global_position
	var moved: float = current.distance_to(_last_player_pos)
	_last_player_pos = current

	_distance_since_last_step += moved
	# `while` in case a huge delta (e.g. teleport) crosses multiple steps.
	while _distance_since_last_step >= step_distance:
		_distance_since_last_step -= step_distance
		_on_step()


# --- Tier application ---

func _on_tier_changed(_new_tier: Aesthetic.Tier) -> void:
	_apply_current_tier()


func _apply_current_tier() -> void:
	var tier: AestheticTier = Aesthetic.get_palette()
	if tier == null:
		push_warning("rpg_overworld: no active tier to apply")
		return

	var mat: ShaderMaterial = tier_overlay.material as ShaderMaterial
	if mat == null:
		push_warning("rpg_overworld: TierOverlay has no ShaderMaterial")
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


# --- Name Entry ---

func _open_name_entry() -> void:
	# Stepper off so movement during name entry doesn't tick encounters.
	_stepper_enabled = false
	# Freeze the player. The name entry's LineEdit captures keys via gui_input
	# for the caret, but player.gd reads Input.get_vector() globally each
	# physics frame, which doesn't care about focus. Without this, arrow
	# keys move the caret AND walk the character. Disabling the player's
	# process_mode skips its _physics_process entirely until we restore it.
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	_name_entry_instance = NAME_ENTRY_SCENE.instantiate()
	add_child(_name_entry_instance)
	_name_entry_instance.name_confirmed.connect(_on_name_confirmed)


func _on_name_confirmed(_name: String) -> void:
	if _name_entry_instance != null:
		_name_entry_instance.queue_free()
		_name_entry_instance = null
	# Restore player processing — back to inheriting from the parent's mode.
	if player != null:
		player.process_mode = Node.PROCESS_MODE_INHERIT
	# Reset the stepper baseline so pre-name-entry movement doesn't count.
	if player != null:
		_last_player_pos = player.global_position
	_stepper_enabled = true


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
			GameManager.set_flag("returning_from_rpg", true)
			get_tree().paused = false
			GameManager.switch_to_world(GameManager.World.REAL_WORLD)


# --- DialogueBox callbacks (pause flow) ---

func _on_choice_made(index: int) -> void:
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
	if _dialog_mode == DialogMode.PAUSE_SAVE_RESULT:
		_dialog_mode = DialogMode.NONE
		pause_menu.open([
			{"id": "resume",   "label": "Resume"},
			{"id": "save",     "label": "Save"},
			{"id": "exit_rpg", "label": "Exit RPG"},
		])


# --- Encounters ---

func _on_step() -> void:
	_steps_until_encounter -= 1
	if _steps_until_encounter <= 0:
		# Sub-phase 3a: just log. 3c will hook this to the battle scene.
		print("Encounter!")
		_roll_next_encounter()


func _roll_next_encounter() -> void:
	_steps_until_encounter = randi_range(
		min_steps_between_encounters, max_steps_between_encounters)


# --- Entrance wiring ---

func _connect_entrance(path: NodePath) -> void:
	# Safe no-op when the NodePath hasn't been set in the Inspector yet —
	# lets us keep this script compiling while you're still placing scene
	# nodes. The target must be an Interactable (interactable.gd attached);
	# we listen to its proximity signals so the player has to press Enter
	# to actually trigger entry, rather than falling in by walking through.
	if path.is_empty():
		return
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("rpg_overworld: entrance NodePath '%s' not found" % path)
		return
	var interactable: Interactable = node as Interactable
	if interactable == null:
		push_warning(
			"rpg_overworld: entrance '%s' isn't an Interactable. Attach "
			% path
			+ "scripts/interactable.gd and set its interaction_id.")
		return
	interactable.player_entered_zone.connect(_on_entrance_entered)
	interactable.player_left_zone.connect(_on_entrance_exited)


func _on_entrance_entered(zone: Interactable) -> void:
	# Player walked into an entrance trigger zone. Remember which one so
	# Enter knows what to fire, and pop up the per-instance hint text
	# (e.g. "[Enter] to enter the town"). If hint_text is empty, the
	# label stays hidden — designers can opt out per entrance.
	_current_entrance = zone
	_show_hint(zone.hint_text)


func _on_entrance_exited(zone: Interactable) -> void:
	# Only clear if it's the entrance we last entered. Guards against an
	# overlap-then-walk-out from a different zone clobbering us.
	if _current_entrance == zone:
		_current_entrance = null
		_show_hint("")


func _show_hint(text: String) -> void:
	# Single point of control for the hint label. Empty text hides the
	# label entirely. Safely no-ops if the HintLayer/InteractHint node
	# hasn't been added to the scene yet.
	if interact_hint == null:
		return
	if text == "":
		interact_hint.visible = false
	else:
		interact_hint.text = text
		interact_hint.visible = true


func _trigger_entrance(zone: Interactable) -> void:
	# Routed by interaction_id so adding a third entrance later is one new
	# match arm rather than another @onready / NodePath / handler trio.
	#
	# Each entrance saves the player's current position into
	# GameManager.overworld_return_position so when the player exits the
	# sub-location and we reload this scene, they re-appear right where
	# they left from instead of at the default spawn.
	match zone.interaction_id:
		"town_entrance":
			if player != null:
				GameManager.overworld_return_position = player.global_position
			GameManager.switch_rpg_location(GameManager.RPGLocation.TOWN)
		"dungeon_entrance":
			# Sub-phase 3d hooks actual dungeon loading here.
			print("DungeonEntrance triggered")
		_:
			push_warning(
				"rpg_overworld: unknown entrance interaction_id '%s'"
				% zone.interaction_id)
