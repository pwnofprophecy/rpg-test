# main.gd
# The SceneManager. This is the root scene of the entire game — Godot loads
# this at startup and it never gets unloaded. Its job is to swap the currently
# displayed "world" scene in and out when the player transitions between
# the Real World (house) and the RPG (game on the PC).
#
# Why a SceneManager pattern instead of Godot's built-in change_scene_to_file?
#   - This script stays alive across world switches, so anything attached here
#     (UI overlays, debug hints, music players) persists smoothly.
#   - Swapping child nodes is faster than a full scene reload — no reinit lag.
#   - Autoloads (GameManager, ModManager, SaveSystem) already persist for free;
#     this lets the visible game state do the same without tight coupling.

extends Node

# --- Scene References ---
# "preload" loads these at compile time so they're instantly available at
# runtime. For Phase 0 this is fine because both scenes are tiny. In later
# phases, if scenes get heavy, we can switch to "load()" for lazy loading.
const REAL_WORLD_SCENE: PackedScene = preload("res://scenes/real_world/ground_floor.tscn")

# RPG sub-locations. The active one is chosen by GameManager.rpg_location.
# Adding a new sub-location later (e.g. a second town) is one new entry
# here plus a match arm in _rpg_scene_for_location below.
const RPG_OVERWORLD_SCENE: PackedScene = preload("res://scenes/rpg/rpg_overworld.tscn")
const RPG_TOWN_SCENE: PackedScene = preload("res://scenes/rpg/rpg_town.tscn")

# Reference to the container node that holds the currently active world.
# We'll add/remove children here whenever the world changes.
@onready var current_scene_container: Node = $CurrentScene

# Reference to the debug hint label (shows "Press Tab to switch worlds").
# This is a temporary Phase 0 UI — it'll be removed once real transitions
# (like walking up to the PC) are built in Phase 1.
@onready var debug_hint: Label = $DebugOverlay/HintLabel


# _ready is called once when the scene loads.
# We wire up signals and load the initial world.
func _ready() -> void:
	# Listen to GameManager for world changes.
	# Whenever GameManager emits world_changed, our _on_world_changed runs.
	GameManager.world_changed.connect(_on_world_changed)

	# Listen for RPG sub-location changes (overworld → town → dungeon, etc.)
	# so we can swap the active RPG scene without touching the world layer.
	GameManager.rpg_location_changed.connect(_on_rpg_location_changed)

	# Load whichever world GameManager thinks we should start in
	# (currently REAL_WORLD per the game design — you wake up at your desk).
	_load_world(GameManager.current_world)


# Watches for debug keys:
#   Tab      — toggle between Real World and RPG
#   F1/F2/F3 — force the RPG aesthetic tier to Gameboy / NES / SNES
# _unhandled_input fires only if no other node has already handled the event,
# which means active scenes can intercept these first if they need to.
# These shortcuts are intended for Phase 2 testing only — they'll be removed
# in Phase 4 once mods take over tier control.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_toggle_world"):
		GameManager.toggle_world()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_tier_gameboy"):
		Aesthetic.set_tier(Aesthetic.Tier.GAMEBOY)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_tier_nes"):
		Aesthetic.set_tier(Aesthetic.Tier.NES)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_tier_snes"):
		Aesthetic.set_tier(Aesthetic.Tier.SNES)
		get_viewport().set_input_as_handled()


# Triggered by GameManager's world_changed signal.
# Any time the world switches (via toggle_world, or eventually by walking to
# the PC), we swap out the displayed scene.
func _on_world_changed(new_world: GameManager.World) -> void:
	_load_world(new_world)


# Triggered when GameManager.rpg_location changes (overworld ↔ town, etc.).
# Only relevant while the RPG world is the active one — if the player is in
# the Real World, we don't reload anything; the new location will be picked
# up the next time they enter the RPG.
func _on_rpg_location_changed(_new_location: GameManager.RPGLocation) -> void:
	if GameManager.current_world == GameManager.World.RPG:
		_load_world(GameManager.World.RPG)


# Helper: clear out the current world scene and load a fresh one based on
# which world we're switching to.
func _load_world(world: GameManager.World) -> void:
	# Remove any existing child (the previous world).
	# queue_free() schedules the node for deletion at the end of the frame,
	# which is safer than free() because it waits until Godot is done with it.
	for child in current_scene_container.get_children():
		child.queue_free()

	# Pick the right packed scene and instantiate it as a node.
	# REAL_WORLD has only one scene; RPG has multiple sub-locations chosen
	# by GameManager.rpg_location.
	var packed_scene: PackedScene
	match world:
		GameManager.World.REAL_WORLD:
			packed_scene = REAL_WORLD_SCENE
		GameManager.World.RPG:
			packed_scene = _rpg_scene_for_location(GameManager.rpg_location)

	current_scene_container.add_child(packed_scene.instantiate())


# Maps an RPGLocation enum value to the PackedScene that represents it.
# Add a new sub-location (e.g. DUNGEON) by adding an enum entry in
# game_manager.gd, a preload constant at the top of this file, and a
# match arm here. No other code needs to change.
func _rpg_scene_for_location(loc: GameManager.RPGLocation) -> PackedScene:
	match loc:
		GameManager.RPGLocation.OVERWORLD:
			return RPG_OVERWORLD_SCENE
		GameManager.RPGLocation.TOWN:
			return RPG_TOWN_SCENE
		GameManager.RPGLocation.DUNGEON:
			# Dungeon scene lands in sub-phase 3d; for now fall back to
			# the overworld so an accidental switch doesn't crash.
			push_warning("main: RPGLocation.DUNGEON has no scene yet, using overworld")
			return RPG_OVERWORLD_SCENE
		_:
			push_warning("main: unknown RPGLocation %s, using overworld" % loc)
			return RPG_OVERWORLD_SCENE
