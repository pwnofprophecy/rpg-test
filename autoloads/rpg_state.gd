# rpg_state.gd
# Autoload singleton that holds the Hero's RUNTIME stats for the RPG.
#
# Registered in project.godot as `RPGState`. Reference it from any script:
#   RPGState.hp -= 5
#   RPGState.add_status("poison")
#
# Why an autoload?
#   The Hero's stats have to survive every scene change — walking between
#   overworld / town / dungeon / battle all blow away the current scene, but
#   autoloads persist. Same reason GameManager and ModManager are autoloads.
#
# Why copy values from a .tres instead of @export on this script?
#   Autoload scripts aren't shown in the Inspector directly (they have no
#   scene node to select). Putting the tunable values on a Resource .tres
#   file makes them Inspector-editable — you just double-click
#   res://resources/hero_stats.tres and edit the fields there. On _ready(),
#   this autoload copies those template values into its own runtime vars.
#
# Lifecycle:
#   _ready()              -> reset_from_template() fills starting values.
#   new game / testing    -> call reset_from_template() again to wipe runtime.
#   save/load (Phase 4+)  -> SaveSystem will serialize these fields directly,
#                            ignoring the .tres (which is only the "new hero"
#                            default).

extends Node

# The template Resource that seeds a fresh Hero. Edited in the Inspector.
const _TEMPLATE: Resource = preload("res://resources/hero_stats.tres")

# --- Runtime state (mutated during play) ---
# character_name starts empty as a sentinel for "haven't done name entry
# yet" — rpg_overworld checks this on _ready to decide whether to show the
# name entry screen. reset_from_template() fills it from the template.
var character_name: String = ""

var max_hp: int = 0
var hp: int = 0
var max_mp: int = 0
var mp: int = 0

var attack: int = 0
var defense: int = 0
var speed: int = 0
# Scales spell power / MP pool. Used by magic abilities in later phases.
var intelligence: int = 0
# Crit chance + loot drop rolls. Used by battles / loot tables later.
var luck: int = 0
# Base attack power when unarmed. Added to the relevant attack stat
# (attack for physical, intelligence for magic) before defense divides into
# the result. Weapons / spells will eventually override this with their own
# Power values when equipped or cast.
var base_power: int = 0

var level: int = 0
var xp: int = 0
var gold: int = 0

# Array[String] — active status effect tags. Empty by default.
# Use the add_status / remove_status / has_status helpers rather than
# mutating this directly, so the stats_changed signal fires consistently.
var status_effects: Array[String] = []

# Emitted whenever any stat or status effect changes. UI (HUD, battle menus)
# can connect and refresh without polling.
signal stats_changed


func _ready() -> void:
	# Seed numeric stats from the template on boot, but DELIBERATELY leave
	# character_name empty. That empty string is the sentinel that tells the
	# RPG overworld to show the name entry screen on first entry. The name
	# entry screen will fill character_name before gameplay begins.
	#
	# If you want to wipe progress and restart the RPG from scratch (new
	# game), call reset_from_template() — that re-seeds everything INCLUDING
	# character_name, so the name prompt will trigger again on next entry.
	_seed_from_template(false)


# Copies values from hero_stats.tres back into the runtime vars. Call this
# when starting a new game, or during testing to wipe progress. Unlike the
# boot-time seeding, this also overwrites character_name, which re-arms
# the name entry sentinel (template default "HERO" -> non-empty, so if you
# really want the prompt again, clear character_name manually afterward).
func reset_from_template() -> void:
	_seed_from_template(true)


# Internal: seed numeric stats from the template. `include_name` controls
# whether character_name is also overwritten — false on boot (so the name
# entry sentinel stays empty), true on explicit full reset.
func _seed_from_template(include_name: bool) -> void:
	var t: HeroStats = _TEMPLATE as HeroStats
	if t == null:
		push_error("RPGState: hero_stats.tres failed to load as HeroStats")
		return

	if include_name:
		character_name = t.character_name
	max_hp = t.max_hp
	hp = t.max_hp
	max_mp = t.max_mp
	mp = t.max_mp
	attack = t.attack
	defense = t.defense
	speed = t.speed
	intelligence = t.intelligence
	luck = t.luck
	base_power = t.base_power
	level = t.level
	xp = t.xp
	gold = t.gold
	# Duplicate the array so runtime mutations don't leak back into the
	# template Resource (Resources are shared by reference in Godot).
	status_effects = t.status_effects.duplicate()

	stats_changed.emit()


# --- Status effect helpers ---
# These are plumbing only in sub-phase 3a — no gameplay actually reads or
# reacts to status effects yet. Battles / abilities in later phases will
# call these.
# Parameter is `status_name` (not `name`) because every Node has a built-in
# `name` property — using it as a parameter name shadows it and Godot warns.

func add_status(status_name: String) -> void:
	if status_name == "" or status_effects.has(status_name):
		return
	status_effects.append(status_name)
	stats_changed.emit()


func remove_status(status_name: String) -> void:
	if status_effects.has(status_name):
		status_effects.erase(status_name)
		stats_changed.emit()


func has_status(status_name: String) -> bool:
	return status_effects.has(status_name)


func clear_statuses() -> void:
	if status_effects.is_empty():
		return
	status_effects.clear()
	stats_changed.emit()
