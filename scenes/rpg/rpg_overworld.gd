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

# --- Inspector-editable: Entrances ---
# Drag your hand-placed Area2D nodes into these slots in the Inspector. The
# script connects `body_entered` on _ready. Leave empty while you're still
# building the scene — the game will run fine without them wired.
@export_node_path("Area2D") var town_entrance_path: NodePath
@export_node_path("Area2D") var dungeon_entrance_path: NodePath

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

	# Wire entrance triggers if the designer has assigned them.
	_connect_entrance(town_entrance_path, _on_town_entered)
	_connect_entrance(dungeon_entrance_path, _on_dungeon_entered)

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
	_name_entry_instance = NAME_ENTRY_SCENE.instantiate()
	add_child(_name_entry_instance)
	_name_entry_instance.name_confirmed.connect(_on_name_confirmed)


func _on_name_confirmed(_name: String) -> void:
	if _name_entry_instance != null:
		_name_entry_instance.queue_free()
		_name_entry_instance = null
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

func _connect_entrance(path: NodePath, handler: Callable) -> void:
	# Safe no-op when the NodePath hasn't been set in the Inspector yet —
	# lets us keep this script compiling while you're still placing scene
	# nodes. Also safe if the path points at a missing node.
	if path.is_empty():
		return
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("rpg_overworld: entrance NodePath '%s' not found" % path)
		return
	var area: Area2D = node as Area2D
	if area == null:
		push_warning("rpg_overworld: entrance '%s' is not an Area2D" % path)
		return
	area.body_entered.connect(handler)


func _on_town_entered(body: Node) -> void:
	# Only the player should trigger entrance transitions.
	if body != player:
		return
	# Sub-phase 3b hooks actual town loading here.
	print("TownEntrance triggered")


func _on_dungeon_entered(body: Node) -> void:
	if body != player:
		return
	# Sub-phase 3d hooks actual dungeon loading here.
	print("DungeonEntrance triggered")
