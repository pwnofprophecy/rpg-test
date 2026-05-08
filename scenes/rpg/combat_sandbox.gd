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
#     GameManager.pending_battle_enemy, set battle_returns_to_sandbox,
#     and switch worlds. battle.gd's _finish_battle_and_return reads
#     the sandbox flag and routes back here on end.

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
@onready var enemy_option: OptionButton = find_child("EnemyOption") as OptionButton
# Optional VBox that gets populated with the selected enemy's stats so
# you can see what you're about to fight without alt-tabbing into the
# .tres file. Stays null if the .tscn doesn't have the node — handled
# by null checks downstream.
@onready var enemy_stats_display: VBoxContainer = find_child("EnemyStatsDisplay") as VBoxContainer
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


func _ready() -> void:
	_populate_player_stats()
	_populate_enemy_dropdown()
	_populate_mod_toggles()

	start_battle_button.pressed.connect(_on_start_battle_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# Show the initially-selected enemy's stats, and update whenever the
	# player picks a different one. We also persist the choice to
	# GameManager so it survives the sandbox-reload that happens around
	# each battle.
	enemy_option.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < _enemy_choices.size():
			GameManager.sandbox_selected_enemy = _enemy_choices[idx]
		_refresh_enemy_stats_display())
	_refresh_enemy_stats_display()

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

	# Effective-stat labels refresh last, since they read both the
	# (possibly just-resync'd) base stats AND the (possibly just-
	# resync'd) equipment.
	_refresh_effective_labels()


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


# --- Enemy dropdown ---

func _populate_enemy_dropdown() -> void:
	_enemy_choices = _scan_enemies_folder()
	enemy_option.clear()
	if _enemy_choices.is_empty():
		enemy_option.add_item("(no enemies found)")
		enemy_option.disabled = true
		start_battle_button.disabled = true
		return
	for stats in _enemy_choices:
		enemy_option.add_item(stats.enemy_name)

	# Restore the last-selected enemy if there is one and it's still in
	# the list. find() works here because Godot's resource cache returns
	# the same instance for a given path on subsequent load() calls — so
	# the freshly-loaded EnemyStats and the saved reference are the same
	# object. If the user deleted/renamed the enemy file between sessions,
	# find() returns -1 and we fall through to the default index 0.
	if GameManager.sandbox_selected_enemy != null:
		var saved: EnemyStats = GameManager.sandbox_selected_enemy as EnemyStats
		var idx: int = _enemy_choices.find(saved)
		if idx >= 0:
			enemy_option.selected = idx


# Rebuilds the enemy stats display panel for whichever enemy is
# currently selected in the dropdown. Saves you from opening the .tres
# file every time you want to know what you're fighting.
#
# The label-value pairs come from a small inline list rather than a
# const so we can format strings (e.g. "5 (XP reward)" if needed
# later). Adding a new EnemyStats field means one new line here.
func _refresh_enemy_stats_display() -> void:
	if enemy_stats_display == null:
		return

	# Clear previous rows.
	for child in enemy_stats_display.get_children():
		child.queue_free()

	if _enemy_choices.is_empty():
		return
	var sel: int = enemy_option.selected
	if sel < 0 or sel >= _enemy_choices.size():
		return
	var stats: EnemyStats = _enemy_choices[sel]

	var rows: Array[Array] = [
		["Max HP",   str(stats.max_hp)],
		["Attack",   str(stats.attack)],
		["Defense",  str(stats.defense)],
		["Speed",    str(stats.speed)],
		["Int",      str(stats.intelligence)],
		["Luck",     str(stats.luck)],
		["Power",    str(stats.base_power)],
		["XP",       str(stats.xp_reward)],
		["Gold",     str(stats.gold_reward)],
	]
	for row_data in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var label := Label.new()
		label.text = row_data[0]
		label.custom_minimum_size = Vector2(80, 0)
		row.add_child(label)

		var value := Label.new()
		value.text = row_data[1]
		row.add_child(value)

		enemy_stats_display.add_child(row)


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
	if _enemy_choices.is_empty():
		return
	# OptionButton.selected returns the chosen item's index in the list
	# (the values we passed to add_item earlier). Out-of-range guards
	# against an empty/unset selection.
	var sel: int = enemy_option.selected
	if sel < 0 or sel >= _enemy_choices.size():
		sel = 0
	GameManager.pending_battle_enemy = _enemy_choices[sel]
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
