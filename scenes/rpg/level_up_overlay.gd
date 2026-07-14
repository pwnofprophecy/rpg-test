# level_up_overlay.gd
# Modal level-up screen shown after a battle WIN that triggered one or
# more level-ups. The entire UI is built programmatically in _ready —
# no .tscn file is required, which keeps scene setup work to zero.
#
# Usage from battle.gd:
#   var overlay := preload("res://scenes/rpg/level_up_overlay.gd").new()
#   add_child(overlay)
#   await overlay.completed
#
# Behavior:
#   - Shows "LEVEL N-1 → LEVEL N" header (reads from
#     RPGState.peek_pending_new_level()).
#   - Lists the automatic stat boosts that just applied (from
#     RPGState.LEVEL_UP_STAT_BOOSTS — purely informational, already
#     applied by RPGState.add_xp()).
#   - Presents one button per stat in RPGState.BONUS_PICK_STATS. Each
#     click allocates +1 pick to that stat; picks can stack on a single
#     stat (e.g. both into Attack for +2).
#   - "Reset" zeros all allocations. "Confirm" applies the picks via
#     RPGState.apply_bonus_picks() and emits `completed`. Confirm is
#     disabled until exactly BONUS_PICKS_PER_LEVEL picks are allocated.
#
# Multi-level-ups: battle.gd loops `while has_pending_level_ups(): new
# overlay; await completed`. Each overlay processes ONE level's picks,
# so the player sees one screen per gained level (clear separation
# rather than a combined "pick 4 stats" mega-screen).

class_name LevelUpOverlay
extends CanvasLayer

# Emitted once the player confirms their bonus-stat allocation. The
# overlay frees itself immediately after emitting; battle.gd awaits this
# to drive the multi-level loop.
signal completed

# Display labels for each stat field name. Keeps the on-screen text
# decoupled from the RPGState field identifiers (which are snake_case).
const _STAT_LABELS: Dictionary = {
	"max_hp": "Max HP",
	"attack": "Attack",
	"defense": "Defense",
	"speed": "Speed",
	"intelligence": "Intelligence",
	"luck": "Luck",
}

# Highlight color reused from the battle menu for visual consistency.
const _HIGHLIGHT_COLOR: Color = Color(1.0, 0.85, 0.2)

# Runtime allocation: stat_field -> number of picks placed on that stat.
# Sum must equal BONUS_PICKS_PER_LEVEL before Confirm enables.
var _pick_counts: Dictionary = {}
# Stat field name -> the Button that allocates +1 to that stat. Kept so
# _refresh_button_labels can re-render the per-button "+N" suffix.
var _stat_buttons: Dictionary = {}
# Footer label showing "Picks: N / M". Refreshed on every click.
var _picks_label: Label = null
# The Confirm button. Toggled enabled/disabled per click based on whether
# the right number of picks have been allocated.
var _confirm_button: Button = null


func _ready() -> void:
	# Render above everything else (battle UI is on layer 1).
	layer = 100
	for stat in RPGState.BONUS_PICK_STATS:
		_pick_counts[stat] = 0
	_build_ui()
	_refresh_button_labels()
	_refresh_picks_footer()


# Constructs the entire overlay: dimmer, centered panel, and all the
# labels / buttons inside. Split into a single function for readability;
# this is run once per overlay instance.
func _build_ui() -> void:
	# Full-screen dimmer behind the panel. Mouse_filter STOP eats clicks
	# that would otherwise fall through to the battle scene (which is
	# still alive underneath).
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Centered panel with internal margin. The panel auto-sizes to fit
	# the VBox content; the anchor + offsets center it on screen.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	# Pre-size guesses; PanelContainer's min size will expand to fit.
	panel.offset_left = -220
	panel.offset_top = -230
	panel.offset_right = 220
	panel.offset_bottom = 230
	# Give the panel a clear background + border so it reads as a modal
	# above the battle UI.
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.08, 0.08, 0.12, 0.97)
	panel_sb.border_color = _HIGHLIGHT_COLOR
	panel_sb.border_width_left = 2
	panel_sb.border_width_right = 2
	panel_sb.border_width_top = 2
	panel_sb.border_width_bottom = 2
	panel_sb.corner_radius_top_left = 6
	panel_sb.corner_radius_top_right = 6
	panel_sb.corner_radius_bottom_left = 6
	panel_sb.corner_radius_bottom_right = 6
	panel_sb.content_margin_left = 18
	panel_sb.content_margin_right = 18
	panel_sb.content_margin_top = 14
	panel_sb.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", panel_sb)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Header — "LEVEL UP!" in gold.
	var header := Label.new()
	header.text = "LEVEL UP!"
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", _HIGHLIGHT_COLOR)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	# Subheader — "Level N-1 → Level N" reading from the queue head.
	var new_level: int = RPGState.peek_pending_new_level()
	var sub := Label.new()
	sub.text = "Level %d  →  Level %d" % [maxi(new_level - 1, 1), new_level]
	sub.add_theme_font_size_override("font_size", 16)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	vbox.add_child(HSeparator.new())

	# Automatic boost list — read via get_boosts_for_level(new_level)
	# so a level with a custom override in LEVEL_UP_STAT_BOOSTS shows
	# its own package, and ordinary levels show the default. Walks the
	# dict actually applied to the current level, not the global default.
	var auto_header := Label.new()
	auto_header.text = "Automatic boosts:"
	auto_header.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	vbox.add_child(auto_header)
	var boosts: Dictionary = RPGState.get_boosts_for_level(new_level)
	for stat in boosts:
		var l := Label.new()
		var pretty: String = _STAT_LABELS.get(stat, stat)
		l.text = "    +%d  %s" % [int(boosts[stat]), pretty]
		vbox.add_child(l)

	vbox.add_child(HSeparator.new())

	# Bonus picks prompt + grid of stat buttons.
	var prompt := Label.new()
	prompt.text = "Choose %d bonus stat points:" % RPGState.BONUS_PICKS_PER_LEVEL
	prompt.add_theme_color_override("font_color", Color(0.8, 1.0, 0.85))
	vbox.add_child(prompt)

	# 2-column grid keeps the six stat buttons compact and readable.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(grid)
	for stat in RPGState.BONUS_PICK_STATS:
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_ALL
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_stat_picked.bind(stat))
		grid.add_child(btn)
		_stat_buttons[stat] = btn

	_picks_label = Label.new()
	_picks_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_picks_label)

	# Reset + Confirm actions row.
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	vbox.add_child(actions)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(_on_reset_pressed)
	actions.add_child(reset_btn)

	_confirm_button = Button.new()
	_confirm_button.text = "Confirm"
	_confirm_button.pressed.connect(_on_confirm_pressed)
	actions.add_child(_confirm_button)


# Click handler for any of the per-stat buttons. Allocates +1 to that
# stat unless we're already at the max pick count, in which case the
# click is a no-op (the player has to Reset or unpick to free a slot).
func _on_stat_picked(stat: String) -> void:
	if _picks_used() >= RPGState.BONUS_PICKS_PER_LEVEL:
		return
	_pick_counts[stat] = int(_pick_counts.get(stat, 0)) + 1
	_refresh_button_labels()
	_refresh_picks_footer()


# Wipes all allocations back to zero. Useful when the player changes
# their mind partway through; cheaper than letting them decrement each
# stat one click at a time.
func _on_reset_pressed() -> void:
	for stat in _pick_counts:
		_pick_counts[stat] = 0
	_refresh_button_labels()
	_refresh_picks_footer()


# Commits the picks to RPGState and tears down the overlay. Guarded by
# the same "exactly N picks" rule that disables the button visually —
# defensive in case a malformed click bypasses the disabled state.
func _on_confirm_pressed() -> void:
	if _picks_used() != RPGState.BONUS_PICKS_PER_LEVEL:
		return
	RPGState.apply_bonus_picks(_pick_counts)
	completed.emit()
	queue_free()


# Sums the current per-stat allocations into a single "picks used" count.
func _picks_used() -> int:
	var total: int = 0
	for stat in _pick_counts:
		total += int(_pick_counts[stat])
	return total


# Re-renders each stat button to reflect its current allocation (e.g.
# "Attack  +2"). Buttons that haven't been picked show just the stat
# name to keep the row clean.
func _refresh_button_labels() -> void:
	for stat in _stat_buttons:
		var btn: Button = _stat_buttons[stat]
		var count: int = int(_pick_counts.get(stat, 0))
		var pretty: String = _STAT_LABELS.get(stat, stat)
		btn.text = "%s  +%d" % [pretty, count] if count > 0 else pretty


# Refreshes the "Picks: N / M" footer and the Confirm button's enabled
# state. Confirm only enables when the allocation is exactly right.
func _refresh_picks_footer() -> void:
	var used: int = _picks_used()
	var total: int = RPGState.BONUS_PICKS_PER_LEVEL
	_picks_label.text = "Picks: %d / %d" % [used, total]
	_confirm_button.disabled = (used != total)
