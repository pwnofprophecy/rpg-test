# combat_sandbox.gd
# Debug-only scene for iterating on the combat system. Press F5 from
# anywhere in the game to enter; the sandbox saves where you came from
# (in GameManager.previous_world) and an "Exit Sandbox" button sends
# you back.
#
# What the sandbox lets you do:
#   - Edit every Hero stat live (HP, MP, Attack, Defense, Speed, Int,
#     Luck, base_power, Level, XP, Gold)
#   - Reset Hero stats to the .tres template (Reset to Defaults)
#   - Pick which enemy to fight from a dropdown of every .tres in
#     res://resources/enemies/
#   - Toggle every registered mod on/off (active state)
#   - Launch a battle with the chosen setup; battle returns to the
#     sandbox so you can immediately try another configuration
#
# How it builds the UI:
#   The .tscn provides a minimal frame — root, background, three named
#   containers (PlayerStatsContainer, ModsContainer) plus the enemy
#   OptionButton and the two action buttons. This script populates the
#   stat editors and mod toggles programmatically so adding a new stat
#   or registering a new mod doesn't require Inspector edits — they
#   show up automatically next time you open the sandbox.
#
# What lives elsewhere:
#   - The damage formula and battle flow live in battle.gd, not here.
#   - Battle launching uses the same path the overworld uses: set
#     GameManager.pending_battle_enemies (one EnemyStats per non-empty
#     slot), set battle_returns_to_sandbox, and switch worlds.
#     battle.gd's _finish_battle_and_return reads the sandbox flag and
#     routes back here on end.

extends Node2D

# --- Stat field definitions ---
# Keeps the stat editor in sync with RPGState in one place. Each entry:
#   { "label": <display name>, "prop": <RPGState var name>,
#     "min": <SpinBox lower>, "max": <SpinBox upper>,
#     "effective": <name of RPGState method returning effective value, or "" for none> }
# When `effective` is non-empty, the row gets a "→ N" label after the
# SpinBox showing the effective value (base + equipment bonuses) when
# it differs from base. Stats equipment doesn't affect (hp, mp, level,
# xp, gold) leave it as an empty string.
const _STAT_FIELDS: Array[Dictionary] = [
	{"label": "Max HP",       "prop": "max_hp",        "min": 1, "max": 9999,   "effective": "get_effective_max_hp"},
	{"label": "HP",           "prop": "hp",            "min": 0, "max": 9999,   "effective": ""},
	{"label": "Max MP",       "prop": "max_mp",        "min": 0, "max": 9999,   "effective": "get_effective_max_mp"},
	{"label": "MP",           "prop": "mp",            "min": 0, "max": 9999,   "effective": ""},
	{"label": "Attack",       "prop": "attack",        "min": 0, "max": 999,    "effective": "get_effective_attack"},
	{"label": "Defense",      "prop": "defense",       "min": 0, "max": 999,    "effective": "get_effective_defense"},
	{"label": "Speed",        "prop": "speed",         "min": 0, "max": 999,    "effective": "get_effective_speed"},
	{"label": "Intelligence", "prop": "intelligence",  "min": 0, "max": 999,    "effective": "get_effective_intelligence"},
	{"label": "Luck",         "prop": "luck",          "min": 0, "max": 999,    "effective": "get_effective_luck"},
	{"label": "Base Power",   "prop": "base_power",    "min": 0, "max": 999,    "effective": "get_effective_base_power"},
	{"label": "Level",        "prop": "level",         "min": 1, "max": 99,     "effective": ""},
	{"label": "XP",           "prop": "xp",            "min": 0, "max": 999999, "effective": ""},
	{"label": "Gold",         "prop": "gold",          "min": 0, "max": 999999, "effective": ""},
]

# Equipment slot definitions. The sandbox builds one dropdown per
# entry. `slot` is the Equipment.Slot enum value used by RPGState's
# equip()/unequip()/get_equipped() helpers.
const _EQUIPMENT_SLOTS: Array[Dictionary] = [
	{"label": "Weapon",    "slot": Equipment.Slot.WEAPON},
	{"label": "Armor",     "slot": Equipment.Slot.ARMOR},
	{"label": "Accessory", "slot": Equipment.Slot.ACCESSORY},
]

# All status effects the sandbox lets you toggle on/off. Add new
# statuses here as they're implemented in battle.gd. Strings must
# match what battle.gd looks for in RPGState.status_effects /
# _enemy_statuses (case-sensitive).
const _KNOWN_STATUSES: Array[String] = ["Poisoned"]

# Folder we scan for enemy templates. Add a .tres here and it'll show up
# in the dropdown automatically next time the sandbox loads.
const _ENEMIES_FOLDER: String = "res://resources/enemies/"
# Folder we scan for equipment templates. Same auto-discovery pattern
# as enemies — drop a .tres in here and it appears in the slot
# dropdowns next time the sandbox loads.
const _EQUIPMENT_FOLDER: String = "res://resources/equipment/"

# --- Node references ---
# Looked up by name (recursive search) rather than absolute path so the
# .tscn can be reorganized — wrapping things in ScrollContainers,
# moving columns, etc. — without breaking the script. Each name must
# still be unique within the scene.
@onready var player_stats_container: VBoxContainer = find_child("PlayerStatsContainer") as VBoxContainer
# Legacy single-enemy dropdown — kept in the .tscn but no longer used
# directly. The sandbox now generates four slot dropdowns programmatically
# (see _populate_enemy_slots below) so we get multi-enemy fights.
# We hide the legacy widget at _ready and rebuild the slots in its place.
@onready var enemy_option: OptionButton = find_child("EnemyOption") as OptionButton
@onready var enemy_stats_display: VBoxContainer = find_child("EnemyStatsDisplay") as VBoxContainer

# Number of enemy slot rows the sandbox renders. Each row has a
# dropdown (None + every loaded enemy) plus a compact stat readout.
# Tweak here if you want more or fewer slots.
const ENEMY_SLOT_COUNT: int = 4
@onready var mods_container: VBoxContainer = find_child("ModsContainer") as VBoxContainer
@onready var start_battle_button: Button = find_child("StartBattleButton") as Button
@onready var reset_button: Button = find_child("ResetButton") as Button
@onready var exit_button: Button = find_child("ExitButton") as Button

# Maps each EnemyStats Resource into the OptionButton's index space, so
# when the dropdown emits item_selected(index) we can look up which
# Resource that index corresponds to.
var _enemy_choices: Array[EnemyStats] = []

# Map of stat property name → SpinBox driving it. Used to refresh the
# spin boxes when RPGState changes (e.g. after Reset to Defaults).
var _stat_editors: Dictionary = {}

# Map of stat property name → { "label": Label, "method": String }.
# The label sits next to the SpinBox and shows " → N" when the
# effective value (after equipment) differs from base. Updated on
# RPGState.stats_changed AND on any SpinBox change.
var _effective_labels: Dictionary = {}

# Per-slot scan of the equipment folder. Keyed by Equipment.Slot int
# value, value is an Array[Equipment]. Built once on _ready.
# Index 0 of each array is implicitly "(None)" — handled in the
# dropdown population. _equipment_dropdowns maps slot → OptionButton
# so we can refresh selections when RPGState changes externally.
var _equipment_choices: Dictionary = {}
var _equipment_dropdowns: Dictionary = {}

# Map of status name → CheckBox driving the player's status toggle.
# Resync'd on RPGState.stats_changed so external mutations (battle
# outcomes, equipment-granted cures, future spells) reflect in the
# sandbox UI.
var _player_status_checkboxes: Dictionary = {}

# Same idea for the enemy side — keyed by status name so we can resync
# when the enemy selection changes (a freshly-picked Skeleton might
# be immune to statuses the previous enemy wasn't, so we filter them
# out and uncheck the boxes).
var _enemy_status_checkboxes: Dictionary = {}

# Per-slot widget references for the multi-enemy picker. Each entry:
#   { "dropdown": OptionButton, "stats_label": Label }
# Indexed by slot (0..ENEMY_SLOT_COUNT-1).
var _enemy_slots: Array = []


func _ready() -> void:
	_populate_player_stats()
	# Hide the .tscn's legacy single-enemy widgets — we render four
	# multi-enemy slots in their place via _populate_enemy_slots below.
	if enemy_option != null:
		enemy_option.visible = false
	if enemy_stats_display != null:
		enemy_stats_display.visible = false
	# Scan the enemies folder once and cache the list — used by every
	# slot dropdown and any later refresh.
	_enemy_choices = _scan_enemies_folder()
	_populate_enemy_slots()
	_populate_enemy_status_section()
	_populate_mod_toggles()

	start_battle_button.pressed.connect(_on_start_battle_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# Refresh the spin boxes whenever RPGState changes from outside (e.g.
	# Reset to Defaults, equipping/unequipping). _refresh_stat_editors
	# also calls _refresh_effective_labels so the " → N" readouts stay
	# in sync with both base stats and equipment bonuses.
	RPGState.stats_changed.connect(_refresh_stat_editors)
	# Show the initial effective values (in case equipment was already
	# slotted before sandbox load — e.g. on subsequent F5 re-entries).
	_refresh_effective_labels()


# --- Player stat editor ---

func _populate_player_stats() -> void:
	for field in _STAT_FIELDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var label := Label.new()
		label.text = field["label"]
		label.custom_minimum_size = Vector2(120, 0)
		row.add_child(label)

		var spin := SpinBox.new()
		spin.min_value = field["min"]
		spin.max_value = field["max"]
		spin.step = 1
		spin.value = RPGState.get(field["prop"])
		spin.custom_minimum_size = Vector2(100, 0)
		# Bind the property name into the closure so each spinbox writes
		# to the correct RPGState field. We also re-fire stats_changed
		# so any "effective" labels watching base stats update too.
		var prop: String = field["prop"]
		spin.value_changed.connect(func(v: float) -> void:
			RPGState.set(prop, int(v))
			RPGState.stats_changed.emit())
		row.add_child(spin)

		# Effective-stat readout: appears as " → N" after the SpinBox
		# when the effective value differs from base (e.g. when
		# equipment bonuses are active). Created for every row but
		# only wired if the stat field declares an `effective` method.
		var eff_label := Label.new()
		eff_label.text = ""
		row.add_child(eff_label)
		var method_name: String = field["effective"]
		if method_name != "":
			_effective_labels[prop] = {"label": eff_label, "method": method_name}

		_stat_editors[prop] = spin
		player_stats_container.add_child(row)

	# Equipment section sits inside the same Player Stats column.
	# Visual divider + header + three slot dropdowns (Weapon, Armor,
	# Accessory). Built programmatically so adding a new slot type
	# only needs a new entry in _EQUIPMENT_SLOTS — no .tscn edit.
	_populate_equipment_section()

	# Status effect toggles below the Equipment section. Same pattern:
	# all script-generated, driven by _KNOWN_STATUSES.
	_populate_player_status_section()


func _refresh_stat_editors() -> void:
	# Re-pull values from RPGState into each SpinBox. Guarded against the
	# spinbox-emits-value-changed-which-writes-back loop by only updating
	# when the value actually differs.
	for prop in _stat_editors:
		var spin: SpinBox = _stat_editors[prop]
		var current: int = RPGState.get(prop)
		if int(spin.value) != current:
			spin.set_value_no_signal(current)

	# Equipment dropdowns also resync — covers the case where
	# RPGState.reset_from_template clears equipment, or any external
	# system equips/unequips on the player.
	_refresh_equipment_dropdowns()

	# Status checkboxes resync too so add_status/remove_status calls
	# from outside the sandbox (e.g. a future battle that applies
	# poison) update the visible checkbox state.
	_refresh_player_status_checkboxes()

	# Effective-stat labels refresh next, since they read both the
	# (possibly just-resync'd) base stats AND the (possibly just-
	# resync'd) equipment.
	_refresh_effective_labels()

	# Enemy slot readouts include matchup metrics (average damage,
	# turns-to-KO) that depend on the player's effective stats, so
	# they refresh whenever player stats might have changed.
	_refresh_all_enemy_slot_stats()


# Resyncs each slot dropdown to match what RPGState says is equipped.
# Index 0 is always "(None)"; subsequent indices map to the items in
# _equipment_choices[slot].
func _refresh_equipment_dropdowns() -> void:
	for slot in _equipment_dropdowns:
		var dropdown: OptionButton = _equipment_dropdowns[slot]
		var current: Equipment = RPGState.get_equipped(slot)
		var items: Array = _equipment_choices.get(slot, [])
		var target_idx: int = 0
		if current != null:
			var found: int = items.find(current)
			if found >= 0:
				target_idx = found + 1
		if dropdown.selected != target_idx:
			dropdown.selected = target_idx


# Updates the " → N" label next to each equipment-affected stat. Shows
# the effective value (base + equipment bonuses) when it differs from
# base, blank otherwise. Called whenever RPGState.stats_changed fires.
func _refresh_effective_labels() -> void:
	for prop in _effective_labels:
		var entry: Dictionary = _effective_labels[prop]
		var base_value: int = RPGState.get(prop)
		var eff_value: int = RPGState.call(entry["method"])
		if eff_value != base_value:
			(entry["label"] as Label).text = " → %d" % eff_value
		else:
			(entry["label"] as Label).text = ""


# --- Equipment section ---

func _populate_equipment_section() -> void:
	# Scan once and stash by slot so each dropdown only iterates over
	# the items that fit it.
	_equipment_choices = _scan_equipment_folder()

	# Visual gap + header.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	player_stats_container.add_child(spacer)

	var header := Label.new()
	header.text = "Equipment"
	header.add_theme_font_size_override("font_size", 22)
	player_stats_container.add_child(header)

	# One row per slot type.
	for slot_def in _EQUIPMENT_SLOTS:
		var slot: int = slot_def["slot"]
		var slot_label: String = slot_def["label"]

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var name_label := Label.new()
		name_label.text = slot_label
		name_label.custom_minimum_size = Vector2(120, 0)
		row.add_child(name_label)

		var dropdown := OptionButton.new()
		dropdown.custom_minimum_size = Vector2(180, 0)
		# Index 0 is always "(None)" so the player can clear a slot.
		# Subsequent indices map 1:1 to _equipment_choices[slot].
		dropdown.add_item("(None)")
		var items: Array = _equipment_choices.get(slot, [])
		for item in items:
			dropdown.add_item(item.item_name)
		row.add_child(dropdown)

		_equipment_dropdowns[slot] = dropdown

		# Restore the currently-equipped item from RPGState if any.
		var current: Equipment = RPGState.get_equipped(slot)
		if current != null:
			var idx: int = items.find(current)
			if idx >= 0:
				dropdown.selected = idx + 1  # +1 for the "(None)" prefix

		# Captured locally so each closure binds correctly.
		var captured_slot: int = slot
		dropdown.item_selected.connect(func(picked_idx: int) -> void:
			if picked_idx == 0:
				RPGState.unequip(captured_slot)
			else:
				var slot_items: Array = _equipment_choices[captured_slot]
				var picked: Equipment = slot_items[picked_idx - 1]
				RPGState.equip(picked))

		player_stats_container.add_child(row)


# --- Status effect section ---
# Toggles below Equipment that apply/remove statuses on the Hero.
# Routes to RPGState.add_status / remove_status which already emits
# stats_changed, so the battle UI's status label and our own
# checkbox refresh both stay in sync.

func _populate_player_status_section() -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	player_stats_container.add_child(spacer)

	var header := Label.new()
	header.text = "Statuses"
	header.add_theme_font_size_override("font_size", 22)
	player_stats_container.add_child(header)

	for status_name in _KNOWN_STATUSES:
		var cb := CheckBox.new()
		cb.text = status_name
		cb.button_pressed = RPGState.has_status(status_name)
		var captured: String = status_name
		cb.toggled.connect(func(pressed: bool) -> void:
			if pressed:
				# add_status returns false if it was rejected (already
				# active or blocked by an equipment-granted immunity).
				# Bounce the checkbox back so the visual state matches
				# RPGState — clear feedback that the toggle didn't take.
				var added: bool = RPGState.add_status(captured)
				if not added:
					cb.set_pressed_no_signal(RPGState.has_status(captured))
			else:
				RPGState.remove_status(captured))
		_player_status_checkboxes[status_name] = cb
		player_stats_container.add_child(cb)


# Re-syncs each status checkbox to RPGState.has_status() — used when
# something other than the sandbox mutates the player's statuses
# (battle ticks aren't supposed to mutate them now, but future cure
# items / spells will). set_pressed_no_signal avoids the toggled
# signal firing in a loop.
func _refresh_player_status_checkboxes() -> void:
	for status_name in _player_status_checkboxes:
		var cb: CheckBox = _player_status_checkboxes[status_name]
		var current: bool = RPGState.has_status(status_name)
		if cb.button_pressed != current:
			cb.set_pressed_no_signal(current)


# Builds a status section under the Enemy column. Mirrors the player
# version but writes to GameManager.pending_battle_enemy_statuses
# (which battle.gd reads on _ready) instead of RPGState. Lives as a
# sibling of EnemyStatsDisplay rather than inside it, so it isn't
# rebuilt when the dropdown selection changes.
func _populate_enemy_status_section() -> void:
	if enemy_option == null:
		return
	var middle_col: Node = enemy_option.get_parent()
	if middle_col == null:
		return

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	middle_col.add_child(spacer)

	var header := Label.new()
	header.text = "Statuses"
	header.add_theme_font_size_override("font_size", 22)
	middle_col.add_child(header)

	for status_name in _KNOWN_STATUSES:
		var cb := CheckBox.new()
		cb.text = status_name
		cb.button_pressed = status_name in GameManager.pending_battle_enemy_statuses
		var captured: String = status_name
		cb.toggled.connect(func(pressed: bool) -> void:
			if pressed:
				# Reject the toggle if the currently-selected enemy is
				# immune to this status — bounce the checkbox back
				# rather than appending to pending_battle_enemy_statuses
				# (which battle.gd would just filter out anyway).
				if _selected_enemy_is_immune_to(captured):
					cb.set_pressed_no_signal(false)
					return
				if not (captured in GameManager.pending_battle_enemy_statuses):
					GameManager.pending_battle_enemy_statuses.append(captured)
			else:
				GameManager.pending_battle_enemy_statuses.erase(captured))
		_enemy_status_checkboxes[status_name] = cb
		middle_col.add_child(cb)

	# Filter the initial state against the currently-selected enemy's
	# immunities. Handles the edge case where the saved selection (an
	# autoload-persisted Skeleton, say) is immune to a status that was
	# left in the pending list from a previous session.
	_refresh_enemy_status_checkboxes()


# Returns true if every currently-selected enemy in any slot is immune
# to this status. With multiple enemies, a status is considered
# "blocked" only if literally none of the picked enemies could be
# afflicted — otherwise we let the player apply it (the immune ones
# just shrug it off at battle start).
func _selected_enemy_is_immune_to(status_name: String) -> bool:
	var any_susceptible: bool = false
	var any_selected: bool = false
	for sel in GameManager.sandbox_selected_enemies:
		var enemy: EnemyStats = sel as EnemyStats
		if enemy == null:
			continue
		any_selected = true
		if not (status_name in enemy.status_immunities):
			any_susceptible = true
			break
	# If no enemy is selected at all, allow the toggle so the user can
	# pre-configure statuses before picking enemies.
	if not any_selected:
		return false
	return not any_susceptible


# Re-syncs each enemy status checkbox to whatever's actually pending.
# Called when an enemy slot changes — switching to a Skeleton while
# Poisoned is checked might leave Poisoned valid (because some other
# slot still holds a Goblin). We only strip statuses that NO selected
# enemy can be afflicted with.
func _refresh_enemy_status_checkboxes() -> void:
	# Filter the pending list: keep statuses that at least one selected
	# enemy is susceptible to. If no enemies are selected at all, leave
	# the list alone (preserves user intent before picking).
	var any_selected: bool = false
	for sel in GameManager.sandbox_selected_enemies:
		if sel != null:
			any_selected = true
			break
	if any_selected:
		var still_pending: Array[String] = []
		for status in GameManager.pending_battle_enemy_statuses:
			var someone_susceptible: bool = false
			for sel in GameManager.sandbox_selected_enemies:
				var enemy: EnemyStats = sel as EnemyStats
				if enemy != null and not (status in enemy.status_immunities):
					someone_susceptible = true
					break
			if someone_susceptible:
				still_pending.append(status)
		GameManager.pending_battle_enemy_statuses = still_pending

	# Then sync each checkbox to the (possibly now-shorter) pending list.
	for status_name in _enemy_status_checkboxes:
		var cb: CheckBox = _enemy_status_checkboxes[status_name]
		var should_be_checked: bool = status_name in GameManager.pending_battle_enemy_statuses
		if cb.button_pressed != should_be_checked:
			cb.set_pressed_no_signal(should_be_checked)


# Scans res://resources/equipment/ for every .tres, loads each as
# Equipment, and groups them by slot. Returns a Dictionary keyed by
# the Equipment.Slot int with Array[Equipment] values. Items within
# each slot are sorted by name for stable dropdown order.
func _scan_equipment_folder() -> Dictionary:
	var by_slot: Dictionary = {
		Equipment.Slot.WEAPON: [],
		Equipment.Slot.ARMOR: [],
		Equipment.Slot.ACCESSORY: [],
	}

	var dir: DirAccess = DirAccess.open(_EQUIPMENT_FOLDER)
	if dir == null:
		push_warning("combat_sandbox: cannot open %s" % _EQUIPMENT_FOLDER)
		return by_slot

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var path: String = _EQUIPMENT_FOLDER + file_name
			var res: Resource = load(path)
			var item: Equipment = res as Equipment
			if item != null:
				if not by_slot.has(item.slot):
					by_slot[item.slot] = []
				by_slot[item.slot].append(item)
			else:
				push_warning("combat_sandbox: %s isn't an Equipment" % path)
		file_name = dir.get_next()
	dir.list_dir_end()

	for slot in by_slot:
		(by_slot[slot] as Array).sort_custom(func(a: Equipment, b: Equipment) -> bool:
			return a.item_name < b.item_name)
	return by_slot


# --- Enemy slot picker (multi-enemy) ---

# Builds ENEMY_SLOT_COUNT slot rows under MiddleColumn. Each row has
# a dropdown (None + every loaded enemy) and a one-line stat readout.
# Slot selections persist via GameManager.sandbox_selected_enemies so
# the picks survive battle round-trips.
func _populate_enemy_slots() -> void:
	if enemy_option == null:
		return
	var middle_col: Node = enemy_option.get_parent()
	if middle_col == null:
		return

	# Header for the section.
	var header := Label.new()
	header.text = "Enemy Slots"
	header.add_theme_font_size_override("font_size", 18)
	middle_col.add_child(header)

	# Make sure the persisted selections list is sized correctly. If the
	# saved array is shorter (e.g. older save), pad with nulls. If
	# longer, truncate.
	while GameManager.sandbox_selected_enemies.size() < ENEMY_SLOT_COUNT:
		GameManager.sandbox_selected_enemies.append(null)
	if GameManager.sandbox_selected_enemies.size() > ENEMY_SLOT_COUNT:
		GameManager.sandbox_selected_enemies = GameManager.sandbox_selected_enemies.slice(0, ENEMY_SLOT_COUNT)

	for i in ENEMY_SLOT_COUNT:
		var slot := _build_enemy_slot(i)
		middle_col.add_child(slot)


# Builds one slot row: "Slot N: [dropdown ▼]  HP X ATK Y DEF Z".
# Dropdown changes write back to GameManager.sandbox_selected_enemies
# and refresh the stats label inline.
func _build_enemy_slot(slot_index: int) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	# Top: label + dropdown side-by-side.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "Slot %d" % (slot_index + 1)
	label.custom_minimum_size = Vector2(60, 0)
	top.add_child(label)

	var dropdown := OptionButton.new()
	dropdown.add_item("(None)")
	for stats in _enemy_choices:
		dropdown.add_item(stats.enemy_name)

	# Restore saved selection: index 0 is "(None)", subsequent indices
	# map 1:1 to _enemy_choices entries.
	var saved: EnemyStats = GameManager.sandbox_selected_enemies[slot_index] as EnemyStats
	if saved != null:
		var idx: int = _enemy_choices.find(saved)
		if idx >= 0:
			dropdown.selected = idx + 1

	top.add_child(dropdown)
	row.add_child(top)

	# Bottom: compact stats readout.
	var stats_label := Label.new()
	stats_label.add_theme_font_size_override("font_size", 12)
	stats_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(stats_label)

	# Stash refs so refresh helpers can find this slot's widgets.
	_enemy_slots.append({"dropdown": dropdown, "stats_label": stats_label})

	# Wire selection change. picked_idx 0 = "(None)" → null. picked_idx
	# > 0 → _enemy_choices[picked_idx - 1].
	var captured: int = slot_index
	dropdown.item_selected.connect(func(picked_idx: int) -> void:
		var picked: EnemyStats = null
		if picked_idx > 0 and picked_idx - 1 < _enemy_choices.size():
			picked = _enemy_choices[picked_idx - 1]
		GameManager.sandbox_selected_enemies[captured] = picked
		_refresh_enemy_slot_stats(captured)
		# Re-filter pending statuses against the union of immunities
		# across all selected enemies.
		_refresh_enemy_status_checkboxes())

	# Initial stat readout.
	_refresh_enemy_slot_stats.call_deferred(slot_index)

	return row


# Updates the compact stats readout under a slot's dropdown based on
# whatever's currently selected. Empty for "(None)" slots. The readout
# shows:
#   Line 1: raw stats — HP, ATK, DEF, PWR
#   Line 2: average damage in each direction (enemy → player, player → enemy)
#   Line 3: turns-to-KO in each direction (assuming basic attacks only)
#   Line 4 (optional): status immunities, if any
# Lines 2/3 use the player's CURRENT effective stats, so they update
# whenever the player tweaks a SpinBox or swaps equipment.
func _refresh_enemy_slot_stats(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= _enemy_slots.size():
		return
	var slot: Dictionary = _enemy_slots[slot_index]
	var lbl: Label = slot["stats_label"]
	var stats: EnemyStats = GameManager.sandbox_selected_enemies[slot_index] as EnemyStats
	if stats == null:
		lbl.text = ""
		return

	var m: Dictionary = _calculate_matchup_metrics(stats)

	var lines: Array[String] = [
		"HP %d  ATK %d  DEF %d  PWR %d" % [stats.max_hp, stats.attack, stats.defense, stats.base_power],
		"Their hit: %d  •  Your hit: %d" % [m["enemy_dmg"], m["player_dmg"]],
		"Kills you in %d  •  Dies in %d" % [m["turns_to_kill_player"], m["turns_to_die"]],
	]
	if not stats.status_immunities.is_empty():
		lines.append("Immune: " + ", ".join(stats.status_immunities))

	# Two-space indent on each line so the readout visually nests under
	# its dropdown.
	lbl.text = "  " + "\n  ".join(lines)


# Computes average damage and turns-to-KO numbers for the given enemy
# against the player's CURRENT effective stats. Returns:
#   { "enemy_dmg":            avg damage the enemy lands on the player
#     "player_dmg":           avg damage the player lands on the enemy
#     "turns_to_kill_player": ceil(player.hp / enemy_dmg)
#     "turns_to_die":         ceil(enemy.max_hp / player_dmg) }
#
# Uses the same formula as battle.gd's _calculate_damage, with the
# random and crit factors averaged so the result is the long-run
# expected damage rather than any single roll.
func _calculate_matchup_metrics(enemy: EnemyStats) -> Dictionary:
	# Damage formula constants must stay in sync with battle.gd. If
	# those values change, update here too — or extract both to a
	# shared CombatBalance Resource later.
	const _CRIT_MULTIPLIER: float = 1.5
	const _RANDOM_LOW: float = 0.85
	const _RANDOM_HIGH: float = 1.0
	const _MAX_CRIT_CHANCE: float = 0.5
	const _LUCK_TO_CRIT_PERCENT: float = 1.0

	# Average random multiplier across a uniform [low, high] roll.
	var avg_random: float = (_RANDOM_LOW + _RANDOM_HIGH) / 2.0

	# Average crit factor = 1.0 weighted by (1 - p_crit) + 1.5 weighted
	# by p_crit. Crit chance is luck × 1% capped at 50%.
	var enemy_crit_p: float = clampf(
		float(enemy.luck) * _LUCK_TO_CRIT_PERCENT / 100.0, 0.0, _MAX_CRIT_CHANCE)
	var enemy_crit_factor: float = 1.0 + enemy_crit_p * (_CRIT_MULTIPLIER - 1.0)

	var player_crit_p: float = clampf(
		float(RPGState.get_effective_luck()) * _LUCK_TO_CRIT_PERCENT / 100.0,
		0.0, _MAX_CRIT_CHANCE)
	var player_crit_factor: float = 1.0 + player_crit_p * (_CRIT_MULTIPLIER - 1.0)

	# Damage formula: (2 × (A + Power) / D + 2) × crit_factor × random.
	# Each defense clamped at 1 to avoid div-by-zero.
	var safe_def_player: int = maxi(RPGState.get_effective_defense(), 1)
	var safe_def_enemy: int = maxi(enemy.defense, 1)

	var enemy_eff_atk: int = enemy.attack + enemy.base_power
	var enemy_raw: float = (
		(2.0 * float(enemy_eff_atk) / float(safe_def_player) + 2.0)
		* enemy_crit_factor * avg_random)
	var enemy_dmg: int = maxi(1, int(enemy_raw))

	var player_eff_atk: int = (
		RPGState.get_effective_attack() + RPGState.get_effective_base_power())
	var player_raw: float = (
		(2.0 * float(player_eff_atk) / float(safe_def_enemy) + 2.0)
		* player_crit_factor * avg_random)
	var player_dmg: int = maxi(1, int(player_raw))

	# Turns-to-KO. Uses CURRENT hp (not max) so taking damage in
	# sandbox testing shifts the metric — "if the fight started right
	# now, this is how many hits until lights out". ceil() so partial
	# rounds count as a full turn.
	var ttk_player: int = int(ceil(float(RPGState.hp) / float(enemy_dmg)))
	var ttk_enemy: int = int(ceil(float(enemy.max_hp) / float(player_dmg)))

	return {
		"enemy_dmg": enemy_dmg,
		"player_dmg": player_dmg,
		"turns_to_kill_player": ttk_player,
		"turns_to_die": ttk_enemy,
	}


# Refreshes every slot's stat readout. Called whenever player stats
# might have changed (SpinBox edit, equipment swap, Reset to Defaults)
# so the per-slot metrics stay in sync with the player's effective
# stats.
func _refresh_all_enemy_slot_stats() -> void:
	for i in _enemy_slots.size():
		_refresh_enemy_slot_stats(i)


# Scans res://resources/enemies/ for every .tres and loads each as
# EnemyStats. Anything that fails the cast is silently skipped (with a
# push_warning so the debugger surfaces it) so a malformed file in the
# folder doesn't break the whole sandbox.
func _scan_enemies_folder() -> Array[EnemyStats]:
	var found: Array[EnemyStats] = []
	var dir: DirAccess = DirAccess.open(_ENEMIES_FOLDER)
	if dir == null:
		push_warning("combat_sandbox: cannot open %s" % _ENEMIES_FOLDER)
		return found

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		# When Godot imports a .tres at build time it generates a .remap
		# file alongside it; we only want the source .tres. Also skip
		# directories.
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var path: String = _ENEMIES_FOLDER + file_name
			var res: Resource = load(path)
			var stats: EnemyStats = res as EnemyStats
			if stats != null:
				found.append(stats)
			else:
				push_warning("combat_sandbox: %s isn't an EnemyStats" % path)
		file_name = dir.get_next()
	dir.list_dir_end()

	# Sort alphabetically by display name for predictable ordering.
	found.sort_custom(func(a: EnemyStats, b: EnemyStats) -> bool:
		return a.enemy_name < b.enemy_name)
	return found


# --- Mod toggles ---

func _populate_mod_toggles() -> void:
	# ModManager.mods is a Dictionary keyed by mod_id, each value a
	# sub-dict with name/description/found/active. We list each one
	# with a CheckBox tied to its active state.
	#
	# IMPORTANT: ModManager.activate_mod requires the mod to already be
	# `found` (because in the production flow you have to pick up the
	# floppy disk first). The sandbox bypasses that — we mark the mod
	# as found before activating so debug-toggling Just Works without
	# requiring the player to traipse through the Real World first.
	var ids: Array = ModManager.mods.keys()
	if ids.is_empty():
		var lbl := Label.new()
		lbl.text = "(no mods registered)"
		mods_container.add_child(lbl)
		return

	for id in ids:
		var info: Dictionary = ModManager.mods[id]
		var cb := CheckBox.new()
		cb.text = "%s — %s" % [info.get("name", id), info.get("description", "")]
		cb.button_pressed = ModManager.is_active(id)
		# Enable word-wrap so long mod descriptions break to multiple
		# lines instead of stretching the CheckBox (and therefore the
		# whole Mods column) to fit on a single line. WORD_SMART tries
		# to break at word boundaries first and falls back to character
		# breaks for long unbroken strings.
		cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# Without this the CheckBox still claims its single-line width as
		# its minimum size — the autowrap only kicks in if the size_flags
		# tell the layout system the box is allowed to be narrower.
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Each CheckBox should grow vertically to accommodate however
		# many wrapped lines it ends up needing.
		cb.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var captured_id: String = id
		cb.toggled.connect(func(pressed: bool) -> void:
			if pressed:
				# Bypass the "must be found" gate for debug testing.
				ModManager.mark_found(captured_id)
				ModManager.activate_mod(captured_id)
			else:
				ModManager.deactivate_mod(captured_id))
		mods_container.add_child(cb)


# --- Button handlers ---

func _on_start_battle_pressed() -> void:
	# Build the pending list from non-empty slots, preserving order
	# (slot 0 → leftmost on screen). Empty slots are silently dropped
	# so a fight with slots [Goblin, None, Bandit, None] becomes a
	# Goblin + Bandit battle.
	var roster: Array = []
	for sel in GameManager.sandbox_selected_enemies:
		var stats: EnemyStats = sel as EnemyStats
		if stats != null:
			roster.append(stats)

	if roster.is_empty():
		# Refuse to start a fight with zero enemies — would just sit on
		# the action menu forever. Surface a warning rather than crash.
		push_warning("combat_sandbox: at least one enemy slot must be set before starting a battle")
		return

	GameManager.pending_battle_enemies = roster
	GameManager.battle_returns_to_sandbox = true
	# Use the RPG world's BATTLE sub-location so main.gd routes us into
	# battle.tscn the same way a real encounter would.
	GameManager.rpg_location = GameManager.RPGLocation.BATTLE
	GameManager.switch_to_world(GameManager.World.RPG)


func _on_reset_pressed() -> void:
	# Re-seed RPGState from hero_stats.tres. _refresh_stat_editors fires
	# off the stats_changed signal RPGState emits, so the SpinBoxes
	# update without us touching them directly.
	RPGState.reset_from_template()


func _on_exit_pressed() -> void:
	# Send the player back to wherever they entered the sandbox from.
	# previous_world was set by switch_to_world when F5 was pressed.
	GameManager.switch_to_world(GameManager.previous_world)
