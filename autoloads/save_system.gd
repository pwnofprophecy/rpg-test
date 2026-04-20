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
# Phase 2 stub: returns true to indicate "success" so the pause menu's Save
# flow can proceed end-to-end (player sees "Game saved.") even though nothing
# is actually written yet. The real implementation lands after Phase 3, once
# RPG state exists to save — at which point only the body of this function
# changes; no caller of save_game() needs to be updated.
func save_game() -> bool:
	push_warning("SaveSystem.save_game() is a stub — no data persisted yet")
	return true


# Load game state from disk and restore it to the relevant systems.
# Phase 2 stub: returns false (no save present / not supported yet) so any
# future "Continue" menu option gracefully falls back to a new game.
func load_game() -> bool:
	push_warning("SaveSystem.load_game() is a stub — no data restored")
	return false


# Check if a save file exists on disk. Used by the main menu to
# enable/disable the "Continue" option.
func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# Delete the save file. Used when starting a new game or by a "reset" option.
func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(SAVE_PATH)
