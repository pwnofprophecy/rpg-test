# game_manager.gd
# Autoload singleton that tracks top-level game state:
# which world is active (Real World vs RPG), progression flags, and
# handles world-switching requests from anywhere in the game.
#
# Access from anywhere via the global name "GameManager" (registered in
# project.godot under [autoload]).

extends Node

# --- World Switching ---

# The two "worlds" the player can be in.
# REAL_WORLD = the house (top-down exploration).
# RPG       = the game-within-a-game on the PC monitor.
enum World { REAL_WORLD, RPG, COMBAT_SANDBOX }

# Broadcast signal: any scene (including the SceneManager) can listen to this
# and react when the player switches worlds.
# This is how we keep the SceneManager decoupled from GameManager's internals —
# it doesn't call a method, it just listens for the change.
signal world_changed(new_world: World)

# Which world is currently active. Starts in REAL_WORLD (you wake up at your desk).
var current_world: World = World.REAL_WORLD

# When entering the combat sandbox via F5, the world we came from is
# stashed here so the sandbox's "Exit" button can return us. Updated by
# switch_to_world() automatically.
var previous_world: World = World.REAL_WORLD


# Switch to a specific world. Does nothing if already there.
# Call this from anywhere: GameManager.switch_to_world(GameManager.World.RPG)
# previous_world is updated FROM the world we're leaving, so the sandbox's
# Exit button can read it and send the player back to where they were.
func switch_to_world(world: World) -> void:
	if world == current_world:
		return
	previous_world = current_world
	current_world = world
	world_changed.emit(world)


# Convenience helper: flip between the two worlds.
# Used by the debug Tab key during Phase 0 testing.
func toggle_world() -> void:
	if current_world == World.REAL_WORLD:
		switch_to_world(World.RPG)
	else:
		switch_to_world(World.REAL_WORLD)


# --- RPG Sub-Location Switching ---
# Within the RPG world the player can be in different "places": the
# overworld (the green map with paths and trees), a town, a dungeon,
# etc. We track that here so main.gd knows which RPG scene to load.
#
# `current_world` is REAL_WORLD vs RPG. `rpg_location` is only meaningful
# when current_world == RPG, but it's safe to read at any time — it just
# describes "if/when we go to the RPG, where will we land".

enum RPGLocation { OVERWORLD, TOWN, DUNGEON, BATTLE }

# Default RPG entry point: the overworld. Switching to a different
# location (TOWN/DUNGEON/BATTLE) is done via switch_rpg_location below.
var rpg_location: RPGLocation = RPGLocation.OVERWORLD

# When a battle starts, the location it was triggered FROM (overworld,
# dungeon, etc.) is stashed here so battle.gd knows where to send the
# player back when the battle ends. Defaults to OVERWORLD because that's
# the only place encounters can fire from in Phase 3c — once dungeon
# encounters land, the dungeon's stepper will set this to DUNGEON before
# triggering the battle.
var rpg_battle_return_location: RPGLocation = RPGLocation.OVERWORLD

# Broadcast whenever rpg_location changes. main.gd listens to this so
# it can swap the active RPG sub-scene (overworld → town, etc.) without
# unloading the player from the RPG world entirely.
signal rpg_location_changed(new_location: RPGLocation)

# When the player enters a town/dungeon from the overworld, we save where
# they were standing so we can drop them back at the same spot when they
# return. Vector2.ZERO is the "no saved position, use the scene's default
# spawn" sentinel — reset to ZERO after the overworld consumes it.
var overworld_return_position: Vector2 = Vector2.ZERO


func switch_rpg_location(loc: RPGLocation) -> void:
	if loc == rpg_location:
		return
	rpg_location = loc
	rpg_location_changed.emit(loc)


# --- Combat Sandbox bridge ---
# The sandbox launches battles for testing. These two fields tell battle.gd
# (1) which enemy template to use, and (2) where to send the player when
# the battle ends. battle.gd reads `pending_battle_enemy` on _ready, and
# checks `battle_returns_to_sandbox` in _finish_battle_and_return.

# When non-empty, battle.gd will spawn one enemy per element instead
# of using its @export defaults. Each entry is an EnemyStats Resource.
# Order in the array becomes left-to-right order on screen. Cleared by
# battle.gd after consuming.
var pending_battle_enemies: Array = []

# When true, battle end returns the player to the sandbox instead of the
# usual rpg_battle_return_location. Cleared by battle.gd after consuming.
var battle_returns_to_sandbox: bool = false

# The enemies the sandbox slot dropdowns were last set to. Index in
# this array matches sandbox slot index. null entries = "(None)" /
# empty slot. Persisted here (rather than on the sandbox node)
# because the sandbox scene gets fully unloaded and reloaded around
# each battle.
var sandbox_selected_enemies: Array = [null, null, null, null]

# Status effects that should be applied to every enemy spawned in the
# next battle. The sandbox toggles these (per status, e.g. ["Poisoned"])
# and battle.gd copies them into each BattleEnemy's status list on
# _ready, filtering out anything that enemy is immune to. Persists
# across sandbox round-trips so toggling once stays in effect for
# subsequent Start Battle presses.
var pending_battle_enemy_statuses: Array[String] = []

# Sandbox cheat: when true, the combat sandbox refills the player's
# inventory to 99 of each item on every sandbox load. Defaults true
# so testing items doesn't require manually refilling between battles.
# Toggled by the "Give 99 of each item" CheckBox in the Inventory
# section.
var sandbox_max_items: bool = true


# --- Progression Flags (stubs for future phases) ---

# A dictionary of arbitrary named flags the game can set/read.
# Examples (future): "edgar_surname_learned", "basement_key_found".
# Stored here so both worlds can reference the same flags.
var flags: Dictionary = {}


func set_flag(flag_name: String, value: Variant = true) -> void:
	flags[flag_name] = value


func get_flag(flag_name: String, default: Variant = false) -> Variant:
	return flags.get(flag_name, default)


func has_flag(flag_name: String) -> bool:
	return flags.has(flag_name)
