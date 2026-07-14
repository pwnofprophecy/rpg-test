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

# How many MP each point of Intelligence grants. Max MP is derived
# entirely from Intelligence (+ equipment) — the old max_mp base is
# left in the Resource shape but is no longer used in the effective
# formula. Tuning this knob globally rescales all spellcasting capacity.
const MP_PER_INT_LEVEL: int = 2

# --- Leveling / XP tuning ---
# XP needed to advance from `level` to `level+1` is XP_PER_LEVEL *
# current_level. Linear curve — going to level 2 costs 100, level 3
# costs another 200, etc. Tune this single constant to globally
# rescale the leveling pace.
const XP_PER_LEVEL: int = 100
# Per-level automatic stat-boost overrides. Keyed by the NEW level
# reached (e.g. `5` is the package applied when arriving at level 5).
# Levels NOT listed here fall back to _DEFAULT_LEVEL_BOOSTS below.
# This is the authoring sweet spot for "milestone" levels — define
# just the levels that should feel special and let the rest use the
# default. Reaching a milestone level via a multi-level XP jump still
# applies its custom package (each level is processed individually
# inside add_xp's loop).
#
# Field names match RPGState properties so _apply_auto_boosts can use
# set()/get() generically. luck is normally omitted (gained only via
# bonus picks) and max_mp is always omitted (derived from intelligence
# via MP_PER_INT_LEVEL).
#
# Example milestone packages (uncomment / edit to taste):
#   5:  {"max_hp": 5, "attack": 2, "defense": 1, "speed": 1, "intelligence": 1},
#   10: {"max_hp": 8, "attack": 2, "defense": 2, "speed": 2, "intelligence": 2},
#   20: {"max_hp": 12, "attack": 3, "defense": 3, "speed": 2, "intelligence": 3, "luck": 1},
const LEVEL_UP_STAT_BOOSTS: Dictionary = {
}

# Fallback package applied at every level not explicitly listed in
# LEVEL_UP_STAT_BOOSTS above. Edit this to change the baseline growth
# rate that ordinary levels use.
const _DEFAULT_LEVEL_BOOSTS: Dictionary = {
	"max_hp": 3,
	"attack": 1,
	"defense": 1,
	"speed": 1,
	"intelligence": 1,
}
# Stats the player can spend bonus picks on at level-up. All six core
# combat stats — including luck (the only growth path for it) and
# max_hp (so a "tank" build can dump picks into HP).
const BONUS_PICK_STATS: Array[String] = [
	"max_hp",
	"attack",
	"defense",
	"speed",
	"intelligence",
	"luck",
]
# How many bonus picks per level-up. Each pick adds +1 to a stat from
# BONUS_PICK_STATS. Multiple picks can stack on a single stat (so all
# 2 picks could go into Attack for a +2). Multi-level-ups multiply
# this — the UI shows one overlay per gained level, each requesting
# BONUS_PICKS_PER_LEVEL picks.
const BONUS_PICKS_PER_LEVEL: int = 2

# --- Runtime state (mutated during play) ---
# character_name starts empty as a sentinel for "haven't done name entry
# yet" — rpg_overworld checks this on _ready to decide whether to show the
# name entry screen. reset_from_template() fills it from the template.
#
# IMPORTANT: this stays "" until the player submits a name. Don't read
# it directly for DISPLAY — use get_display_name() so un-named contexts
# (the combat sandbox, anything entered before RPG name entry) still
# show a sensible fallback name instead of a blank.
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
# `xp` is XP TOWARD THE NEXT LEVEL — it resets to 0 (or the leftover
# remainder) every time the player levels up. The "lifetime total XP"
# display in the sandbox is COMPUTED from level + xp via
# get_total_xp_for_curve() — no separate counter to keep in sync.
var xp: int = 0
var gold: int = 0

# Queue of pending level-ups awaiting bonus-pick allocation. Each entry
# is the OLD level number for that level-up (so the overlay can show
# "LEVEL N → LEVEL N+1"). Drained one entry at a time as the player
# confirms each level's picks via the level-up overlay. Battle.gd uses
# has_pending_level_ups() after WIN to drive the overlay loop.
var pending_level_ups: Array[int] = []

# Array[String] — active status effect tags. Empty by default.
# Use the add_status / remove_status / has_status helpers rather than
# mutating this directly, so the stats_changed signal fires consistently.
var status_effects: Array[String] = []

# --- Equipment slots ---
# The Hero can have one of each slot equipped. `null` means the slot
# is empty (e.g. unarmed when no weapon is equipped). Mutate via
# equip() / unequip() rather than assigning these directly so the
# stats_changed signal fires and any UI listeners refresh.
var equipped_weapon: Equipment = null
var equipped_armor: Equipment = null
var equipped_accessory: Equipment = null

# --- Inventory ---
# Map of Item Resource → int quantity. Entries with quantity 0 are
# erased entirely (so has_any_items() can use is_empty()). Mutate via
# add_to_inventory() / remove_from_inventory() so the stats_changed
# signal fires and the sandbox / battle item menu refresh.
var inventory: Dictionary = {}

# Emitted whenever any stat or status effect changes. UI (HUD, battle menus)
# can connect and refresh without polling.
signal stats_changed

# Emitted once per level gained (so a multi-level XP grant fires this
# multiple times, in order). `new_level` is the level just reached;
# `auto_boosts` is a copy of the stat boosts that were just applied
# (a dict matching LEVEL_UP_STAT_BOOSTS' shape). The bonus picks for
# this level are NOT in the dict — they're queued via
# pending_level_ups for the player to choose via the overlay.
signal leveled_up(new_level: int, auto_boosts: Dictionary)


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
		# Full reset (include_name=true) also clears equipment so a
		# fresh "new game" starts unarmed/unarmored. Boot-time seeding
		# (include_name=false) leaves equipment alone since the
		# autoload's slots are already null on first init anyway.
		equipped_weapon = null
		equipped_armor = null
		equipped_accessory = null
		# Same logic for inventory — a "new game" starts empty-handed.
		inventory.clear()
		# A fresh game also clears any pending level-up picks (otherwise
		# Reset to Defaults in the sandbox would leave a "Level Up!"
		# overlay queued from the previous run).
		pending_level_ups.clear()
	max_hp = t.max_hp
	hp = t.max_hp
	# max_mp is left in the Resource for legacy / future use but no
	# longer drives effective max MP — see get_effective_max_mp(). For
	# seeding current MP we use the derived effective max so the Hero
	# starts with a full pool regardless of the .tres value.
	max_mp = t.max_mp
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

	# Seed current MP from the derived effective max (intelligence has
	# been assigned just above, so get_effective_max_mp returns the
	# right value). Done AFTER all other fields are set so the lookup
	# sees the freshly-seeded intelligence value.
	mp = get_effective_max_mp()

	stats_changed.emit()


# --- Status effect helpers ---
# These are plumbing only in sub-phase 3a — no gameplay actually reads or
# reacts to status effects yet. Battles / abilities in later phases will
# call these.
# Parameter is `status_name` (not `name`) because every Node has a built-in
# `name` property — using it as a parameter name shadows it and Godot warns.

# Returns true if the status was actually added, false if it was
# rejected (empty name, already active, or blocked by an equipment-
# granted immunity). Callers that care about feedback (e.g. the
# sandbox checkbox auto-revert) read the return value; callers that
# don't can ignore it like before.
func add_status(status_name: String) -> bool:
	if status_name == "" or status_effects.has(status_name):
		return false
	if get_status_immunities().has(status_name):
		return false
	status_effects.append(status_name)
	stats_changed.emit()
	return true


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


# Returns the name to DISPLAY for the Hero. Falls back to the template's
# default name when character_name is still the "" sentinel (e.g. in the
# combat sandbox before the player has gone through RPG name entry). The
# raw character_name field stays "" so the name-entry sentinel still
# works — only display code reads through this.
func get_display_name() -> String:
	if character_name != "":
		return character_name
	var t: HeroStats = _TEMPLATE as HeroStats
	if t != null and t.character_name != "":
		return t.character_name
	# Ultimate fallback if the template somehow has no name.
	return "Hero"


# --- Equipment helpers ---
# All mutations route through equip() / unequip() so the stats_changed
# signal fires once per change, letting the sandbox / future HUDs
# refresh effective-stat readouts automatically.

func equip(item: Equipment) -> void:
	if item == null:
		return
	match item.slot:
		Equipment.Slot.WEAPON:
			equipped_weapon = item
		Equipment.Slot.ARMOR:
			equipped_armor = item
		Equipment.Slot.ACCESSORY:
			equipped_accessory = item
		_:
			push_warning("RPGState.equip: unknown slot %s" % item.slot)
			return
	# Equipping a piece that grants immunity to a status the Hero
	# already has should also CURE the status — otherwise putting on
	# an Antidote Ring while poisoned is useless until you manually
	# clear the status. Pure prevention is less intuitive than
	# prevention + cure.
	_purge_immunized_statuses()
	stats_changed.emit()


func unequip(slot: Equipment.Slot) -> void:
	match slot:
		Equipment.Slot.WEAPON:
			equipped_weapon = null
		Equipment.Slot.ARMOR:
			equipped_armor = null
		Equipment.Slot.ACCESSORY:
			equipped_accessory = null
	stats_changed.emit()


func get_equipped(slot: Equipment.Slot) -> Equipment:
	match slot:
		Equipment.Slot.WEAPON:
			return equipped_weapon
		Equipment.Slot.ARMOR:
			return equipped_armor
		Equipment.Slot.ACCESSORY:
			return equipped_accessory
	return null


# --- Effective stats (base + equipment bonuses) ---
# The damage formula and any HUD that wants to show a "true" current
# stat reads through these methods. Base values (max_hp, attack, etc.)
# stay untouched; equipment effects layer on top via _equipment_bonus.
#
# Why per-stat methods rather than one generic getter? Type clarity at
# call sites — battle.gd reads RPGState.get_effective_attack() and the
# return type is `int`, not `Variant`.

func get_effective_max_hp() -> int:
	return max_hp + _equipment_bonus("hp_bonus")

func get_effective_max_mp() -> int:
	# Max MP is purely derived from Intelligence: 2 MP per point of
	# Intelligence, plus any equipment mp_bonus on top. The HeroStats /
	# RPGState `max_mp` field is no longer used as a base value (kept
	# in the Resource for now in case a future class system wants to
	# reintroduce a flat per-class MP cap on top of the Int scaling).
	return intelligence * MP_PER_INT_LEVEL + _equipment_bonus("mp_bonus")

func get_effective_attack() -> int:
	return attack + _equipment_bonus("attack_bonus")

func get_effective_defense() -> int:
	return defense + _equipment_bonus("defense_bonus")

func get_effective_speed() -> int:
	return speed + _equipment_bonus("speed_bonus")

func get_effective_intelligence() -> int:
	return intelligence + _equipment_bonus("intelligence_bonus")

func get_effective_luck() -> int:
	return luck + _equipment_bonus("luck_bonus")

func get_effective_base_power() -> int:
	return base_power + _equipment_bonus("power_bonus")


# Sums a single bonus field across all three equipment slots. Used by
# every get_effective_* method above so they all share the same
# "iterate slots, sum field" code path. Field names match Equipment
# resource property names.
func _equipment_bonus(field: String) -> int:
	var sum: int = 0
	for eq in [equipped_weapon, equipped_armor, equipped_accessory]:
		if eq != null:
			# eq.get() returns Variant; explicit int() cast keeps the
			# accumulator strictly int and avoids "untyped sum"
			# inference warnings in stricter GDScript modes.
			sum += int(eq.get(field))
	return sum


# Returns the union of every status_immunities list across all three
# equipped slots. add_status() consults this to reject statuses the
# wearer is immune to; equip() consults it to cure already-active
# statuses that the new piece would now block.
func get_status_immunities() -> Array[String]:
	var combined: Array[String] = []
	for eq in [equipped_weapon, equipped_armor, equipped_accessory]:
		if eq == null:
			continue
		for status in eq.status_immunities:
			if not (status in combined):
				combined.append(status)
	return combined


# Strips any currently-active status effects that the Hero is now
# immune to (e.g. just equipped an Antidote Ring while poisoned).
# Caller is expected to emit stats_changed afterward — equip() does
# this once per equip rather than emitting twice.
func _purge_immunized_statuses() -> void:
	var immunities: Array[String] = get_status_immunities()
	for status in immunities:
		if status_effects.has(status):
			status_effects.erase(status)


# --- Inventory helpers ---
# All mutations route through these so stats_changed fires once per
# change, letting the sandbox SpinBoxes and the battle item menu
# refresh automatically.

func add_to_inventory(item: Item, quantity: int = 1) -> void:
	if item == null or quantity <= 0:
		return
	inventory[item] = int(inventory.get(item, 0)) + quantity
	stats_changed.emit()


# Removes `quantity` of `item` from the inventory. If the resulting
# count would be 0 or less, erases the entry entirely (keeps the
# Dictionary "tidy" — only items the player actually owns appear).
func remove_from_inventory(item: Item, quantity: int = 1) -> void:
	if item == null or quantity <= 0 or not inventory.has(item):
		return
	var new_count: int = int(inventory[item]) - quantity
	if new_count <= 0:
		inventory.erase(item)
	else:
		inventory[item] = new_count
	stats_changed.emit()


# Sets the count for an item directly, bypassing the
# additive/subtractive helpers. Useful for the sandbox SpinBox
# (set count = 5) and for save/load restoration. Count of 0
# erases the entry.
func set_inventory_count(item: Item, count: int) -> void:
	if item == null:
		return
	if count <= 0:
		inventory.erase(item)
	else:
		inventory[item] = count
	stats_changed.emit()


func get_inventory_count(item: Item) -> int:
	return int(inventory.get(item, 0))


# True when the player owns at least one of any item. Used by the
# battle item menu to decide whether to show "No items" placeholder
# text or a real list.
func has_any_items() -> bool:
	return not inventory.is_empty()


# --- Leveling / XP helpers ---
# Battles award XP via add_xp() on WIN. Each level-up applies the
# LEVEL_UP_STAT_BOOSTS package immediately and queues a slot in
# pending_level_ups so the post-WIN flow can show the bonus-pick
# overlay (one screen per level gained).

# XP threshold to advance from `from_level` to `from_level+1`. Linear:
# 100 * from_level. So level 1 → 2 needs 100, level 2 → 3 needs 200, etc.
func xp_to_next_level(from_level: int) -> int:
	return XP_PER_LEVEL * maxi(from_level, 1)


# Returns the notional total XP this Hero has "earned" given their
# current level and xp-toward-next: the sum of every threshold for
# levels 1..level-1 plus the current xp. Used by the sandbox's
# "Current XP" readout so the display stays coherent with manual
# edits to `level` / `xp` — both fields contribute and the math
# always reflects "how much XP a normal player would have to earn
# to reach exactly this state."
#
# Because the curve is linear (XP_PER_LEVEL * L), the cumulative sum
# closes to XP_PER_LEVEL * (level-1) * level / 2 — no loop needed.
func get_total_xp_for_curve() -> int:
	var prior_levels: int = maxi(level - 1, 0)
	# Closed-form sum: XP_PER_LEVEL * (1 + 2 + ... + prior_levels)
	#                = XP_PER_LEVEL * prior_levels * (prior_levels+1) / 2
	var sum_thresholds: int = XP_PER_LEVEL * prior_levels * (prior_levels + 1) / 2
	return sum_thresholds + xp


# Adds XP and processes any level-ups triggered. Auto-boosts apply
# right away; bonus picks get queued in pending_level_ups for the
# overlay to drain.
#
# Returns a summary dict the caller can use to drive UI:
#   xp_gained:     int — the amount added (= `amount`, for symmetry)
#   levels_gained: int — how many level-ups fired
#   old_level:     int — level before this call
#   new_level:     int — level after this call
#   boosts_total:  Dictionary — summed auto-boosts across all levels
#                              gained (e.g. a 2-level jump shows +6
#                              max_hp / +2 attack rather than +3 / +1).
func add_xp(amount: int) -> Dictionary:
	var summary: Dictionary = {
		"xp_gained": amount,
		"levels_gained": 0,
		"old_level": level,
		"new_level": level,
		"boosts_total": {},
	}
	if amount <= 0:
		return summary
	xp += amount
	# Drain XP into level-ups while we have enough for the next tier.
	# Each iteration pays the cost for the level we're CURRENTLY at
	# (which depends on `level`, so it shifts each loop).
	while xp >= xp_to_next_level(level):
		xp -= xp_to_next_level(level)
		var old_level: int = level
		level += 1
		var per_level: Dictionary = _apply_auto_boosts()
		# Accumulate per-stat totals into the summary so a multi-level
		# message can show the combined boost.
		for k in per_level:
			var prev: int = int(summary["boosts_total"].get(k, 0))
			summary["boosts_total"][k] = prev + int(per_level[k])
		# Queue this level's bonus-pick slot. The overlay drains the
		# queue one entry per confirm.
		pending_level_ups.append(old_level)
		summary["levels_gained"] = int(summary["levels_gained"]) + 1
		leveled_up.emit(level, per_level)
	summary["new_level"] = level
	stats_changed.emit()
	return summary


# Returns the boost dict that applies when arriving at `new_level`.
# Looks up the per-level override table first; falls back to the
# default package when no override exists for that level. The returned
# dict is a fresh copy so callers can iterate without worrying about
# polluting the const tables.
func get_boosts_for_level(new_level: int) -> Dictionary:
	if LEVEL_UP_STAT_BOOSTS.has(new_level):
		return (LEVEL_UP_STAT_BOOSTS[new_level] as Dictionary).duplicate()
	return _DEFAULT_LEVEL_BOOSTS.duplicate()


# Internal: applies the boost package for the level we just reached
# (read off the now-updated `level` field — _apply_auto_boosts is
# called AFTER `level += 1` in add_xp's loop, so it sees the new
# level) and restores HP/MP to full. Returns the boost dict so
# callers can display what was applied.
func _apply_auto_boosts() -> Dictionary:
	var boosts: Dictionary = get_boosts_for_level(level)
	var applied: Dictionary = {}
	for stat_field in boosts:
		var delta: int = int(boosts[stat_field])
		set(stat_field, int(get(stat_field)) + delta)
		applied[stat_field] = delta
	# Full restore on level-up. Reads through the effective getters
	# so any equipment bonuses to max HP/MP are honored.
	hp = get_effective_max_hp()
	mp = get_effective_max_mp()
	return applied


# Applies one level's worth of bonus picks. `picks` is keyed by stat
# field name → number of picks allocated to that stat. The sum of the
# values MUST equal BONUS_PICKS_PER_LEVEL — the overlay enforces this
# before calling. Pops the front of pending_level_ups so subsequent
# has_pending_level_ups() reflects what's left.
func apply_bonus_picks(picks: Dictionary) -> void:
	if pending_level_ups.is_empty():
		push_warning("RPGState.apply_bonus_picks: no level-ups pending")
		return
	for stat_field in picks:
		if not BONUS_PICK_STATS.has(stat_field):
			push_warning("RPGState.apply_bonus_picks: '%s' isn't a valid bonus stat" % stat_field)
			continue
		var delta: int = int(picks[stat_field])
		if delta <= 0:
			continue
		set(stat_field, int(get(stat_field)) + delta)
	pending_level_ups.pop_front()
	# Picks into max_hp grow the cap — top off current HP to match.
	# (Auto-boosts already healed to full, but a later pick into max_hp
	# would leave current HP below the new cap without this.)
	if int(picks.get("max_hp", 0)) > 0:
		hp = get_effective_max_hp()
	# Same for intelligence → MP cap.
	if int(picks.get("intelligence", 0)) > 0:
		mp = get_effective_max_mp()
	stats_changed.emit()


# True if any level-ups are awaiting bonus-pick allocation. Battle.gd
# checks this after WIN to decide whether to spawn the overlay.
func has_pending_level_ups() -> bool:
	return not pending_level_ups.is_empty()


# Returns the NEW level for the next pending overlay (so the header
# can read "LEVEL N-1 → LEVEL N"). Returns -1 when nothing's pending.
func peek_pending_new_level() -> int:
	if pending_level_ups.is_empty():
		return -1
	return int(pending_level_ups[0]) + 1
