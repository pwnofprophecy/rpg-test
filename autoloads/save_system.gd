# save_system.gd
# Autoload singleton responsible for saving and loading all persistent
# game state (RPG character data, world flags, active mods, Real World
# lock states, collected items, etc.).
#
# Phase 0: stub only. The real implementation will come when there's
# meaningful state worth persisting.
#
# Access from anywhere via the global name "SaveSystem".

extends Node

# Godot convention: "user://" resolves to a per-user writable folder
# (something like %APPDATA%\Godot\app_userdata\RPGTest\ on Windows).
# This is where the save file goes — NOT the project folder, so it survives
# game updates and doesn't accidentally get committed to git.
const SAVE_PATH: String = "user://savegame.save"


# Save all game state to disk.
# Phase 0 stub — will be filled in once RPG/Real World state exists to save.
func save_game() -> void:
	push_warning("SaveSystem.save_game() not yet implemented (Phase 0 stub)")


# Load game state from disk and restore it to the relevant systems.
# Phase 0 stub.
func load_game() -> void:
	push_warning("SaveSystem.load_game() not yet implemented (Phase 0 stub)")


# Check if a save file exists on disk. Used by the main menu to
# enable/disable the "Continue" option.
func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# Delete the save file. Used when starting a new game or by a "reset" option.
func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(SAVE_PATH)
