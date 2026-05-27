# rpg_overworld.gd
# The root script for the RPG overworld scene. It extends RPGLocationBase
# (scenes/rpg/rpg_location_base.gd), which provides all the machinery
# every RPG location shares — the tier overlay shader, the pause menu +
# Save-confirm flow, camera snap-on-load, the [Interact] hint helper, and
# Exit-RPG handling. See that file for the full list.
#
# This script adds ONLY what's unique to the overworld, via the base's
# virtual hooks:
#
#   _location_ready()        — wire entrance triggers, restore the saved
#                              return position, seed the encounter stepper,
#                              and show the name-entry overlay on first entry.
#   _handle_location_input() — Enter triggers a nearby entrance; F4 toggles
#                              random encounters.
#   _can_open_pause()        — also blocks while the name-entry overlay is up.
#
# The overworld's own responsibilities on top of the base:
#   1. On first entry, show the name entry screen so the player can name
#      their Hero. Subsequent entries skip it.
#   2. Count player "steps" and trigger random encounters every N steps
#      (range tunable in the Inspector).
#   3. Expose NodePath slots for the TownEntrance and DungeonEntrance Area2Ds
#      placed in the scene. Empty paths are fine — those hooks just go
#      unwired so the scene can be rebuilt incrementally.

extends RPGLocationBase

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
# this in _on_entrance_entered and clear it in _on_entrance_exited, then read
# it in _handle_location_input when the player presses Enter to decide what
# to do.
var _current_entrance: Interactable = null

# --- Inspector-editable: Encounter tuning ---
# Master switch for random encounters. Flip this in the Inspector to test
# the overworld without battles popping up, or toggle it at runtime with
# F4 (see _handle_location_input below). When false, the stepper still ticks
# distance internally but never fires an encounter.
@export var encounters_enabled: bool = true
# Encounters fire after a random number of steps in [min, max]. Tune these
# while playtesting until encounter density feels right.
@export_range(1, 50) var min_steps_between_encounters: int = 5
@export_range(1, 100) var max_steps_between_encounters: int = 15
# How many world-units of player movement count as one "step". 32 roughly
# matches a tile-width, which is a familiar JRPG feel.
@export_range(8.0, 128.0) var step_distance: float = 32.0

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


# --- Virtual hook overrides ---

func _location_ready() -> void:
	# Wire entrance triggers if the designer has assigned them. The handlers
	# just track proximity — the actual "enter the area" trigger fires from
	# _handle_location_input when the player presses ui_accept while inside.
	_connect_entrance(town_entrance_path)
	_connect_entrance(dungeon_entrance_path)

	# If the player is returning from a sub-location (town/dungeon), drop
	# them back where they were standing. Vector2.ZERO is the "no saved
	# position" sentinel — first entry from the Real World hits this case
	# and the player stays at the scene's default spawn point. This runs
	# BEFORE the base's _snap_camera (the base calls _location_ready first),
	# so the camera frames the restored position, not the default spawn.
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


func _handle_location_input(event: InputEvent) -> void:
	# Enter triggers the current entrance, if the player is standing inside
	# one and no UI is blocking. Pause menu and dialogue box consume input
	# themselves when open, so we mostly just need to guard against name
	# entry being up (it doesn't consume scene-level ui_accept).
	if event.is_action_pressed("ui_accept"):
		if _current_entrance != null and not pause_menu.is_open() and _name_entry_instance == null:
			_trigger_entrance(_current_entrance)
			get_viewport().set_input_as_handled()
		return

	# F4 toggles random encounters on/off at runtime. Useful for walking the
	# overworld during testing without battles interrupting.
	if event.is_action_pressed("debug_toggle_encounters"):
		encounters_enabled = not encounters_enabled
		print("rpg_overworld: encounters_enabled = %s" % encounters_enabled)
		get_viewport().set_input_as_handled()
		return


func _can_open_pause() -> bool:
	# Base blocks while the pause menu or dialogue box is up; we also block
	# while the name-entry overlay is showing.
	return super._can_open_pause() and _name_entry_instance == null


# --- Encounter stepper ---

func _process(_delta: float) -> void:
	# Step-based encounter counter. Distance-based rather than frame-based
	# so that standing still or holding against a wall doesn't rack up
	# steps. Runs unconditionally at the top so we bail cheaply when the
	# stepper is off.
	if not _stepper_enabled or player == null:
		return

	# Pause stepping while the dialogue box is open — otherwise the player
	# could walk during a conversation and rack up steps. Reset the
	# baseline so the next active frame doesn't see a huge accumulated
	# delta from movement that happened while paused.
	if dialogue_box != null and dialogue_box.is_open():
		_last_player_pos = player.global_position
		return

	var current: Vector2 = player.global_position
	var moved: float = current.distance_to(_last_player_pos)
	_last_player_pos = current

	_distance_since_last_step += moved
	# `while` in case a huge delta (e.g. teleport) crosses multiple steps.
	while _distance_since_last_step >= step_distance:
		_distance_since_last_step -= step_distance
		_on_step()


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


# --- Encounters ---

func _on_step() -> void:
	# Distance-based step counter ticks every frame the player moves
	# step_distance world-units. Encounters are gated by encounters_enabled
	# so testing the overworld without battles is a one-checkbox affair.
	if not encounters_enabled:
		return
	_steps_until_encounter -= 1
	if _steps_until_encounter <= 0:
		_trigger_encounter()
		_roll_next_encounter()


func _trigger_encounter() -> void:
	# Save where the player is so the overworld can drop them back exactly
	# where they were standing when the battle ends. Tell GameManager that
	# this battle should return to the overworld (later, dungeon encounters
	# will set this to DUNGEON instead). Then swap the active RPG scene.
	if player != null:
		GameManager.overworld_return_position = player.global_position
	GameManager.rpg_battle_return_location = GameManager.RPGLocation.OVERWORLD
	GameManager.switch_rpg_location(GameManager.RPGLocation.BATTLE)


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
