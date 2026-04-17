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
enum World { REAL_WORLD, RPG }

# Broadcast signal: any scene (including the SceneManager) can listen to this
# and react when the player switches worlds.
# This is how we keep the SceneManager decoupled from GameManager's internals —
# it doesn't call a method, it just listens for the change.
signal world_changed(new_world: World)

# Which world is currently active. Starts in REAL_WORLD (you wake up at your desk).
var current_world: World = World.REAL_WORLD


# Switch to a specific world. Does nothing if already there.
# Call this from anywhere: GameManager.switch_to_world(GameManager.World.RPG)
func switch_to_world(world: World) -> void:
	if world == current_world:
		return
	current_world = world
	world_changed.emit(world)


# Convenience helper: flip between the two worlds.
# Used by the debug Tab key during Phase 0 testing.
func toggle_world() -> void:
	if current_world == World.REAL_WORLD:
		switch_to_world(World.RPG)
	else:
		switch_to_world(World.REAL_WORLD)


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
