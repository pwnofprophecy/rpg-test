# battle_ui.gd
# Handles everything the player sees and interacts with during battle:
# the text box, the action menu, and the HP bars.
# This script deliberately knows nothing about damage math or turn order —
# it just displays information and reports button presses back to battle.gd.

extends CanvasLayer

# This "signal" is how the UI talks back to battle.gd.
# When the player confirms a menu choice, we "emit" this signal with the
# chosen action (e.g. "attack"), and battle.gd responds accordingly.
# Signals are Godot's way of letting nodes communicate without being
# tightly coupled together.
signal action_selected(action: String)

# --- Node References ---
# "@onready" tells Godot: once the scene is loaded, find the node at this
# path and store a reference to it in this variable.
# The "$" is shorthand for "get_node()" — it walks the scene tree to find
# the named node. These paths match the node names in battle.tscn.
@onready var text_label: Label = $TextBox/MarginContainer/TextLabel
@onready var menu_box: PanelContainer = $MenuBox
@onready var player_hp_bar: ProgressBar = $PlayerHealthBar/HPBar
@onready var enemy_hp_bar: ProgressBar = $EnemyHealthBar/HPBar
@onready var player_name_label: Label = $PlayerHealthBar/NameLabel
@onready var enemy_name_label: Label = $EnemyHealthBar/NameLabel
# Optional "current / max" text overlays on the HP bars. Wrapped in
# has_node so the script keeps working if you haven't added the labels
# to the scene yet — they just stay null and the update calls below
# silently skip the text update.
@onready var player_hp_text: Label = $PlayerHealthBar/HPBar/HPText if has_node("PlayerHealthBar/HPBar/HPText") else null
@onready var enemy_hp_text: Label = $EnemyHealthBar/HPBar/HPText if has_node("EnemyHealthBar/HPBar/HPText") else null

# Status text labels appended below each HP bar at runtime in _ready.
# Show comma-separated active status names like "[Poisoned]" — empty/
# hidden when no statuses are active. Created programmatically rather
# than in the .tscn so this script owns the lifecycle.
var player_status_label: Label = null
var enemy_status_label: Label = null

# An array holding references to the four menu option labels,
# in the order they appear in the 2x2 grid:
#   [0: Attack]  [1: Cast]
#   [2: Item  ]  [3: Run ]
@onready var menu_labels: Array[Label] = [
	$MenuBox/MenuGrid/AttackLabel,
	$MenuBox/MenuGrid/CastLabel,
	$MenuBox/MenuGrid/ItemLabel,
	$MenuBox/MenuGrid/RunLabel,
]

# How long an HP bar takes to "drain" from its old value to the new one.
# Short enough to feel snappy, long enough to read as motion. Keep this
# under the battle's 1.5s post-hit pause so a single damage event always
# finishes draining before the next state transition.
const HP_DRAIN_DURATION: float = 0.4

# --- Menu State ---
var cursor_index: int = 0    # Which menu option is currently highlighted (0–3)
var menu_active: bool = false      # True when the player can navigate the main menu
var sub_menu_active: bool = false  # True when the player is inside Cast or Item

# The action strings that match each menu slot by index.
# Index 0 = "attack", 1 = "cast", 2 = "item", 3 = "run".
# "const" means this list never changes at runtime.
const ACTIONS: Array[String] = ["attack", "cast", "item", "run"]


# Wires mouse support onto the menu labels. Labels default to
# mouse_filter = IGNORE (they don't intercept clicks), which is fine
# for the keyboard-only flow but blocks any mouse interaction. Setting
# them to STOP makes them receive hover and click events. We then:
#   - mouse_entered → moves the cursor to whatever the pointer is over
#     (so visual highlight tracks the mouse the same way it tracks
#     arrow-key navigation)
#   - gui_input → on a left click, confirms that option just like
#     pressing Enter would
#
# The bound `i` argument tells each handler which menu slot it belongs
# to without needing to look up "which label fired this signal".
func _ready() -> void:
	for i in menu_labels.size():
		var label: Label = menu_labels[i]
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_entered.connect(_on_menu_label_hovered.bind(i))
		label.gui_input.connect(_on_menu_label_input.bind(i))

	# Make non-interactive UI panels transparent to mouse clicks so
	# left-clicks fall through to battle.gd's _unhandled_input for
	# dismissing end-of-battle text ("GOBLIN was defeated!", "HERO has
	# died.", etc.). Without this, clicking on the TextBox panel (which
	# covers a wide strip at the bottom of the screen) or the HP bars
	# is consumed before _unhandled_input fires — those Controls
	# default to MOUSE_FILTER_STOP. The menu Labels already have STOP
	# explicitly set above so they still receive their own clicks for
	# action selection.
	var pass_through: Array = [
		$TextBox,
		$TextBox/MarginContainer,
		$PlayerHealthBar,
		$EnemyHealthBar,
		player_hp_bar,
		enemy_hp_bar,
	]
	for ctrl in pass_through:
		(ctrl as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Build status labels programmatically and tuck them inside the
	# existing HealthBar VBoxContainers below the HPBar. Hidden by
	# default; battle.gd calls set_*_statuses() to show them.
	player_status_label = _make_status_label()
	$PlayerHealthBar.add_child(player_status_label)
	enemy_status_label = _make_status_label()
	$EnemyHealthBar.add_child(enemy_status_label)


# Builds a styled Label used for showing a combatant's active status
# effects. Matches the muted-but-readable look of the rest of the
# battle UI. mouse_filter is IGNORE so it doesn't intercept clicks
# meant for the dismiss handler.
func _make_status_label() -> Label:
	var lbl := Label.new()
	lbl.text = ""
	lbl.visible = false
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.8, 0.7, 1.0))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


# Public setter — battle.gd calls this whenever the player's active
# statuses change so the on-screen label stays in sync.
func set_player_statuses(statuses: Array) -> void:
	_apply_status_label(player_status_label, statuses)


# Same for the enemy.
func set_enemy_statuses(statuses: Array) -> void:
	_apply_status_label(enemy_status_label, statuses)


# Formats and shows/hides a status label based on the supplied list.
# Empty list → hidden. Non-empty → "[Status1, Status2]" rendered.
func _apply_status_label(label: Label, statuses: Array) -> void:
	if label == null:
		return
	if statuses.is_empty():
		label.text = ""
		label.visible = false
	else:
		label.text = "[%s]" % ", ".join(statuses)
		label.visible = true


# Pointer moved over a menu option. Move the cursor there so the ">"
# indicator follows the mouse — same visual as keyboard nav. No-op
# while the menu isn't accepting input (during attack animations,
# intro, etc.) so hovering during a wait doesn't visually fake-out
# the player.
func _on_menu_label_hovered(idx: int) -> void:
	if not menu_active:
		return
	cursor_index = idx
	_update_cursor()


# Pointer clicked on a menu option. Treat exactly like pressing Enter
# while that option is highlighted: emit the action and disable the
# menu so further input doesn't double-fire. We update cursor_index
# first so the > sits on the clicked option for the brief moment
# before the menu hides.
func _on_menu_label_input(event: InputEvent, idx: int) -> void:
	if not menu_active:
		return
	if not _is_left_click(event):
		return
	cursor_index = idx
	_update_cursor()
	menu_active = false
	action_selected.emit(ACTIONS[idx])
	get_viewport().set_input_as_handled()


# _unhandled_input is called automatically by Godot whenever a key is pressed,
# but only if no other node has already "handled" it.
# We use this to drive menu navigation without needing a polling loop.
func _unhandled_input(event: InputEvent) -> void:
	# If we're inside a sub-menu (Cast or Item), any confirm/cancel key
	# OR a left-click anywhere sends the player back to the main menu.
	if sub_menu_active:
		var dismiss := (event.is_action_pressed("ui_accept")
			or event.is_action_pressed("ui_cancel")
			or _is_left_click(event))
		if dismiss:
			sub_menu_active = false
			action_selected.emit("back")  # Tell battle.gd to return to PLAYER_MENU
			get_viewport().set_input_as_handled()  # Prevent other nodes reacting to this keypress
		return  # Don't process main menu input while in a sub-menu

	# If the main menu isn't showing, ignore all key input here
	if not menu_active:
		return

	# Try to match the pressed key to a navigation action.
	# "handled" starts true and is set to false if no key matched,
	# so we only refresh the cursor and consume the event when something actually changed.
	var handled := true

	if event.is_action_pressed("ui_right") and cursor_index % 2 == 0:
		# Move right — only if we're in the LEFT column (index 0 or 2).
		# "% 2 == 0" checks if the index is even (left column).
		cursor_index += 1
	elif event.is_action_pressed("ui_left") and cursor_index % 2 == 1:
		# Move left — only if we're in the RIGHT column (index 1 or 3).
		# "% 2 == 1" checks if the index is odd (right column).
		cursor_index -= 1
	elif event.is_action_pressed("ui_down") and cursor_index < 2:
		# Move down — only if we're in the TOP row (index 0 or 1).
		cursor_index += 2  # Add 2 to jump from top row to bottom row
	elif event.is_action_pressed("ui_up") and cursor_index >= 2:
		# Move up — only if we're in the BOTTOM row (index 2 or 3).
		cursor_index -= 2  # Subtract 2 to jump from bottom row to top row
	elif event.is_action_pressed("ui_accept"):
		# Player confirmed their selection — disable the menu and report the choice
		menu_active = false
		action_selected.emit(ACTIONS[cursor_index])
	else:
		handled = false  # No relevant key was pressed

	if handled:
		_update_cursor()                       # Redraw the ">" indicator on the new selection
		get_viewport().set_input_as_handled()  # Mark this event as consumed


# Redraws all four menu labels to show which one is currently selected.
# The selected option gets a ">" prefix; the others get spaces to keep alignment.
func _update_cursor() -> void:
	for i in menu_labels.size():
		if i == cursor_index:
			menu_labels[i].text = "> " + ACTIONS[i].capitalize()  # e.g. "> Attack"
		else:
			menu_labels[i].text = "  " + ACTIONS[i].capitalize()  # e.g. "  Cast"


# Updates the text displayed in the bottom text box.
# Called by battle.gd whenever the message needs to change.
func set_message(text: String) -> void:
	text_label.text = text


# Updates the player's HP bar to reflect the new value.
# The bar smoothly drains from its current value to the new one over
# HP_DRAIN_DURATION seconds; the "X / Y" text overlay tracks the
# interpolated integer value so it stays in sync. Color refresh runs
# at the end (so the green/yellow/red transition lines up with the
# actual remaining ratio rather than the in-progress one).
#
# Pass `animate = false` for the initial setup (battle.gd._ready) so
# the bar snaps to the correct value instead of visibly filling up
# from the .tscn placeholder.
func update_player_hp(value: int, animate: bool = true) -> void:
	if animate:
		_animate_hp_bar(player_hp_bar, player_hp_text, value)
	else:
		_set_hp_bar_instant(player_hp_bar, player_hp_text, value)


# Updates the enemy's HP bar to reflect the new value.
func update_enemy_hp(value: int, animate: bool = true) -> void:
	if animate:
		_animate_hp_bar(enemy_hp_bar, enemy_hp_text, value)
	else:
		_set_hp_bar_instant(enemy_hp_bar, enemy_hp_text, value)


# Instant version — used for initial setup so the bar shows the right
# value on frame 1 instead of tweening from the placeholder.
func _set_hp_bar_instant(bar: ProgressBar, text: Label, value: int) -> void:
	bar.value = value
	_update_bar_color(bar)
	_refresh_hp_text(text, bar)


# Tweens an HP bar from its current value to `target_value` while keeping
# the optional text overlay in sync. Bar color recalculates at the end so
# the threshold transitions (green→yellow→red) snap once on settle rather
# than flickering through during the drain.
func _animate_hp_bar(bar: ProgressBar, text: Label, target_value: int) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(bar, "value", target_value, HP_DRAIN_DURATION)
	if text != null:
		var start: int = int(bar.value)
		var bar_max: int = int(bar.max_value)
		# tween_method calls our setter every frame with an interpolated
		# int between `start` and `target_value`, perfect for keeping the
		# label number locked to the bar's animated fill ratio.
		tween.tween_method(
			func(v: int) -> void:
				text.text = "%d / %d" % [v, bar_max],
			start, target_value, HP_DRAIN_DURATION)
	tween.set_parallel(false)
	tween.tween_callback(_update_bar_color.bind(bar))


# Sets the player's HP bar maximum so the fill ratio reflects real stats
# (e.g. RPGState.max_hp of 30) instead of the placeholder 10 from the
# .tscn. Call this BEFORE update_player_hp on first setup so the colour
# calculation uses the right max.
func set_player_max_hp(max_value: int) -> void:
	player_hp_bar.max_value = max_value
	_refresh_hp_text(player_hp_text, player_hp_bar)


# Sets the enemy's HP bar maximum the same way.
func set_enemy_max_hp(max_value: int) -> void:
	enemy_hp_bar.max_value = max_value
	_refresh_hp_text(enemy_hp_text, enemy_hp_bar)


# Updates an HP text overlay to read "current / max". No-op when the
# label is null (i.e. the .tscn doesn't have one yet).
func _refresh_hp_text(label: Label, bar: ProgressBar) -> void:
	if label == null:
		return
	label.text = "%d / %d" % [int(bar.value), int(bar.max_value)]


# Updates the displayed combatant names. battle.gd calls these from _ready
# so the player's chosen character_name shows up instead of the .tscn
# default ("HERO"), and the enemy name reflects whatever encounter spawned.
func set_player_name(text: String) -> void:
	player_name_label.text = text


func set_enemy_name(text: String) -> void:
	enemy_name_label.text = text


# Changes a health bar's fill color based on how much HP remains.
# Green = healthy, Yellow = caution, Red = critical.
func _update_bar_color(bar: ProgressBar) -> void:
	# Calculate the percentage of HP remaining as a value between 0.0 and 1.0.
	# For example, 7 HP out of 10 max gives a ratio of 0.7 (70%).
	var ratio := bar.value / bar.max_value

	var color: Color
	if ratio > 0.75:
		color = Color.GREEN   # Above 75% — healthy
	elif ratio >= 0.30:
		color = Color.YELLOW  # Between 30% and 75% — getting low
	else:
		color = Color.RED     # Below 30% — critical

	# ProgressBar doesn't have a simple "set fill color" property, so we
	# create a StyleBoxFlat (a solid colored rectangle) and override the
	# bar's built-in "fill" style with our colored one.
	var style := StyleBoxFlat.new()
	style.bg_color = color
	bar.add_theme_stylebox_override("fill", style)


# Makes the action menu visible and enables keyboard navigation.
# Also resets the cursor back to "Attack" (index 0) each time it opens.
func show_menu() -> void:
	menu_box.visible = true
	menu_active = true
	cursor_index = 0
	_update_cursor()


# Hides the action menu and disables keyboard navigation.
# Called during narration sequences so the player can't input during them.
func hide_menu() -> void:
	menu_box.visible = false
	menu_active = false


# Switches into sub-menu mode (used for Cast and Item).
# Hides the main menu grid and waits for the player to press back.
func enter_sub_menu() -> void:
	menu_box.visible = false
	menu_active = false
	sub_menu_active = true


# Hides the .tscn's hardcoded single-enemy widgets so battle.gd's
# programmatically-spawned per-enemy bars are the only enemy UI on
# screen. Called from battle.gd::_ready. Also hides the
# enemy_status_label which sits inside the now-hidden EnemyHealthBar
# but Godot leaves it visible if its parent's children are individually
# placed (defensive double-hide).
func hide_legacy_enemy_widgets() -> void:
	$EnemyHealthBar.visible = false
	if enemy_status_label != null:
		enemy_status_label.visible = false


# Convenience: was this input a left mouse-button press? Used to treat a
# click identically to pressing Enter for dismissing the sub-menu and
# end-of-battle text. Uses an explicit cast after the `is` check so
# `event.pressed` resolves to a known type — GDScript 4 doesn't narrow
# event types within a single expression, so a return of an inline
# boolean expression breaks type inference downstream.
static func _is_left_click(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb: InputEventMouseButton = event
	return mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
