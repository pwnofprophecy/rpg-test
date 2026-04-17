# mod_manager.gd
# Autoload singleton that manages all RPG mods (floppy disks the player finds
# in the Real World). Systems like the battle scene, the RPG UI, and the
# overworld listen to this and reconfigure themselves when mods change.
#
# Access from anywhere via the global name "ModManager".

extends Node

# --- Signals ---
# Systems that care about mods listen to these and update their behavior.
# The signal-driven approach means the battle scene (for example) never needs
# to know WHICH mods exist — it just reacts to what ModManager broadcasts.

signal mod_found(mod_id: String)         # Player picked up a floppy disk
signal mod_activated(mod_id: String)     # Mod was turned ON
signal mod_deactivated(mod_id: String)   # Mod was turned OFF

# --- Mod Registry ---
# Dictionary of all known mods, keyed by mod_id (e.g. "items", "spells").
# Each entry is a sub-dictionary with:
#   name:        Display name shown in the Mod UI
#   description: Tooltip text
#   found:       True once the player has picked up the floppy disk
#   active:      True when the mod is currently turned on
var mods: Dictionary = {}


# Register a new mod with the manager. Call this during startup (from mod
# initialization scripts) so ModManager knows the mod exists.
# Mods start unfound and inactive — the player must discover the floppy disk
# in the Real World before they can enable the mod.
func register_mod(mod_id: String, display_name: String, description: String) -> void:
	mods[mod_id] = {
		"name": display_name,
		"description": description,
		"found": false,
		"active": false,
	}


# Mark a mod as found — called when the player picks up its floppy disk.
# Once found, the mod appears in the Mod Management UI and can be activated.
func mark_found(mod_id: String) -> void:
	if not mods.has(mod_id):
		push_warning("ModManager: tried to mark unknown mod as found: " + mod_id)
		return
	if mods[mod_id]["found"]:
		return  # Already found, nothing to do
	mods[mod_id]["found"] = true
	mod_found.emit(mod_id)


# Turn a mod on. Does nothing if the mod isn't found yet or is already active.
func activate_mod(mod_id: String) -> void:
	if not mods.has(mod_id):
		return
	if not mods[mod_id]["found"]:
		return  # Can't activate mods you haven't found
	if mods[mod_id]["active"]:
		return  # Already active
	mods[mod_id]["active"] = true
	mod_activated.emit(mod_id)


# Turn a mod off.
func deactivate_mod(mod_id: String) -> void:
	if not mods.has(mod_id):
		return
	if not mods[mod_id]["active"]:
		return  # Already inactive
	mods[mod_id]["active"] = false
	mod_deactivated.emit(mod_id)


# Quick check: is this mod currently turned on?
# Other systems use this to gate features (e.g. "is the Cast menu available?").
func is_active(mod_id: String) -> bool:
	return mods.has(mod_id) and mods[mod_id]["active"]


# Has the player found this mod's floppy disk yet?
func is_found(mod_id: String) -> bool:
	return mods.has(mod_id) and mods[mod_id]["found"]
