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
#     "min": <SpinBox lower>, "max": <SpinBox upper> }
# Adding a new stat is one new entry.
const _STAT_FIELDS: Array[Dictionary] = [
	{"label": "Max HP",       "prop": "max_hp",        "min": 1, "max": 9999},
	{"label": "HP",           "prop": "hp",            "min": 0, "max": 9999},
	{"label": "Max MP",       "prop": "max_mp",        "min": 0, "max": 9999},
	{"label": "MP",           "prop": "mp",            "min": 0, "max": 9999},
	{"label": "Attack",       "prop": "attack",        "min": 0, "max": 999},
	{"label": "Defense",      "prop": "defense",       "min": 0, "max": 999},
	{"label": "Speed",        "prop": "speed",         "min": 0, "max": 999},
	{"label": "Intelligence", "prop": "intelligence",  "min": 0, "max": 999},
	{"label": "Luck",         "prop": "luck",          "min": 0, "max": 999},
	{"label": "Base Power",   "prop": "base_power",    "min": 0, "max": 999},
	{"label": "Level",        "prop": "level",         "min": 1, "max": 99},
	{"label": "XP",           "prop": "xp",            "min": 0, "max": 999999},
	{"label": "Gold",         "prop": "gold",          "min": 0, "max": 999999},
]

# Folder we scan for enemy templates. Add a .tres here and it'll show up
# in the dropdown automatically next time the sandbox loads.
const _ENEMIES_FOLDER: String = "res://resources/enemies/"

# --- Node references ---
# These names must match what the .tscn provides. See the build
# instructions in the chat for what the user needs to wire up.
@onready var player_stats_container: VBoxContainer = $UI/Margin/Root/HBox/LeftColumn/PlayerStatsContainer
@onready var enemy_option: OptionButton = $UI/Margin/Root/HBox/MiddleColumn/EnemyOption
# Optional VBox that gets populated with the selected enemy's stats so
# you can see what you're about to fight without alt-tabbing into the
# .tres file. Wrapped in has_node so the sandbox still loads if the
# display container isn't in the scene yet.
@onready var enemy_stats_display: VBoxContainer = $UI/Margin/Root/HBox/MiddleColumn/EnemyStatsDisplay if has_node("UI/Margin/Root/HBox/MiddleColumn/EnemyStatsDisplay") else null
@onready var mods_container: VBoxContainer = $UI/Margin/Root/HBox/RightColumn/ModsContainer
@onready var start_battle_button: Button = $UI/Margin/Root/Buttons/StartBattleButton
@onready var reset_button: Button = $UI/Margin/Root/Buttons/ResetButton
@onready var exit_button: Button = $UI/Margin/Root/Buttons/ExitButton

# Maps each EnemyStats Resource into the OptionButton's index space, so
# when the dropdown emits item_selected(index) we can look up which
# Resource that index corresponds to.
var _enemy_choices: Array[EnemyStats] = []

# Map of stat property name → SpinBox driving it. Used to refresh the
# spin boxes when RPGState changes (e.g. after Reset to Defaults).
var _stat_editors: Dictionary = {}


func _ready() -> void:
	_populate_player_stats()
	_populate_enemy_dropdown()
	_populate_mod_toggles()

	start_battle_button.pressed.connect(_on_start_battle_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# Show the initially-selected enemy's stats, and update whenever the
	# player picks a different one. The signal arg is the new index but
	# we don't need it — we re-read enemy_option.selected.
	enemy_option.item_selected.connect(func(_idx: int) -> void: _refresh_enemy_stats_display())
	_refresh_enemy_stats_display()

	# Refresh the spin boxes whenever RPGState changes from outside (e.g.
	# Reset to Defaults). Avoids the SpinBoxes drifting out of sync with
	# the actual stats.
	RPGState.stats_changed.connect(_refresh_stat_editors)


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
		# to the correct RPGState field.
		var prop: String = field["prop"]
		spin.value_changed.connect(func(v: float) -> void:
			RPGState.set(prop, int(v)))
		row.add_child(spin)

		_stat_editors[prop] = spin
		player_stats_container.add_child(row)


func _refresh_stat_editors() -> void:
	# Re-pull values from RPGState into each SpinBox. Guarded against the
	# spinbox-emits-value-changed-which-writes-back loop by only updating
	# when the value actually differs.
	for prop in _stat_editors:
		var spin: SpinBox = _stat_editors[prop]
		var current: int = RPGState.get(prop)
		if int(spin.value) != current:
			spin.set_value_no_signal(current)


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
