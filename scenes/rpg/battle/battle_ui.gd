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

# Emitted when the player picks an item from the item menu. The Item
# resource is passed so battle.gd knows what to apply. battle.gd then
# routes through target selection before actually using it.
signal item_selected(item: Item)

# Emitted when the player presses Esc / right-clicks while the item
# menu is open. battle.gd uses this to return to the action menu.
signal item_canceled

# Emitted when the player clicks the on-screen Cancel button during
# target selection. Keyboard Esc is handled by battle.gd directly;
# this signal is the mouse-equivalent path.
signal target_cancel_clicked

# Emitted when the player picks a spell from the magic menu. battle.gd
# then routes through MP check + target selection. Mirrors item_selected.
signal spell_selected(spell: Spell)

# Emitted when the player cancels out of the magic menu (Esc, click
# on Cancel row, or right-click). battle.gd returns to the action menu.
signal magic_canceled

# --- Node References ---
# "@onready" tells Godot: once the scene is loaded, find the node at this
# path and store a reference to it in this variable.
# The "$" is shorthand for "get_node()" — it walks the scene tree to find
# the named node. These paths match the node names in battle.tscn.
@onready var text_label: Label = $TextBox/MarginContainer/TextLabel
@onready var menu_box: PanelContainer = $MenuBox
# Player stat widgets live under PlayerStatusArea (a PanelContainer
# providing the background) → Stats (the VBoxContainer holding the
# rows). Enemy bars are still the .tscn's single EnemyHealthBar (the
# per-enemy bars in multi-enemy fights are built programmatically in
# battle.gd).
@onready var player_hp_bar: ProgressBar = $PlayerStatusArea/Stats/HPBar
@onready var enemy_hp_bar: ProgressBar = $EnemyHealthBar/HPBar
@onready var player_name_label: Label = $PlayerStatusArea/Stats/NameLabel
@onready var enemy_name_label: Label = $EnemyHealthBar/NameLabel
# Optional "current / max" text overlays on the HP bars. Wrapped in
# has_node so the script keeps working if you haven't added the labels
# to the scene yet — they just stay null and the update calls below
# silently skip the text update.
@onready var player_hp_text: Label = $PlayerStatusArea/Stats/HPBar/HPText if has_node("PlayerStatusArea/Stats/HPBar/HPText") else null
@onready var enemy_hp_text: Label = $EnemyHealthBar/HPBar/HPText if has_node("EnemyHealthBar/HPBar/HPText") else null
# Player mana bar + optional "current / max" text overlay. Both
# has_node-guarded so the battle still runs if you haven't added the
# MP bar to the scene yet — the MP update calls below just no-op.
@onready var player_mp_bar: ProgressBar = $PlayerStatusArea/Stats/MPBar if has_node("PlayerStatusArea/Stats/MPBar") else null
@onready var player_mp_text: Label = $PlayerStatusArea/Stats/MPBar/MPText if has_node("PlayerStatusArea/Stats/MPBar/MPText") else null

# Status text labels appended below each HP bar at runtime in _ready.
# Show comma-separated active status names like "[Poisoned]" — empty/
# hidden when no statuses are active. Created programmatically rather
# than in the .tscn so this script owns the lifecycle.
var player_status_label: Label = null
var enemy_status_label: Label = null

# --- Item menu state ---
# The item menu lives in a separately-built PanelContainer that we
# create on demand. show_item_menu(inventory) builds the labels and
# enables input; hide_item_menu() tears it down. While item_menu_active
# is true, _unhandled_input routes arrow keys / Enter / Esc to the
# item menu instead of the regular action flow.
var item_menu_panel: PanelContainer = null
var item_menu_vbox: VBoxContainer = null
var item_menu_labels: Array[Label] = []
var item_menu_items: Array = []  # parallel to item_menu_labels — Array[Item]
var item_menu_counts: Array[int] = []  # parallel — quantity for each item
var item_menu_active: bool = false
var item_menu_cursor: int = 0

# Cancel button shown during target selection. Mouse equivalent of
# pressing Esc. battle.gd toggles visibility on TARGET_SELECT entry /
# exit; clicking it fires target_cancel_clicked which battle.gd routes
# to _cancel_target.
var target_cancel_button: Button = null

# --- Magic menu state ---
# Mirrors the item menu state but for spells. Built on demand by
# show_magic_menu; torn down (hidden) by hide_magic_menu. Spells with
# insufficient MP are visually dimmed and rejected on confirm with a
# "Not enough MP!" message that stays in the menu so the player can
# pick something else without backing out.
var magic_menu_panel: PanelContainer = null
var magic_menu_vbox: VBoxContainer = null
var magic_menu_labels: Array[Label] = []
var magic_menu_spells: Array = []  # parallel to magic_menu_labels — Array[Spell]
var magic_menu_active: bool = false
var magic_menu_cursor: int = 0

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
# Index 0 = "attack", 1 = "magic", 2 = "item", 3 = "run".
# "const" means this list never changes at runtime.
# Note: the corresponding label node in the .tscn is still named
# "CastLabel" for historical reasons — the user-visible text comes
# from the capitalized action string here, not the node name.
const ACTIONS: Array[String] = ["attack", "magic", "item", "run"]


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
		$PlayerStatusArea,
		$PlayerStatusArea/Stats,
		$EnemyHealthBar,
		player_hp_bar,
		enemy_hp_bar,
	]
	for ctrl in pass_through:
		(ctrl as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Build status labels programmatically and tuck them inside the
	# stat VBoxContainers below the bars. Hidden by default; battle.gd
	# calls set_*_statuses() to show them.
	player_status_label = _make_status_label()
	# Center the player's status text within the status area to match
	# the centered name above it. The label fills the container width
	# (default VBox Fill sizing), so HORIZONTAL_ALIGNMENT_CENTER puts
	# the text in the middle. The enemy status label is left as-is.
	player_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$PlayerStatusArea/Stats.add_child(player_status_label)
	enemy_status_label = _make_status_label()
	$EnemyHealthBar.add_child(enemy_status_label)

	# Hide the player status panel until the command menu first appears
	# (show_menu reveals it). This keeps it from showing during the
	# intro "Enemy appeared!" banner, so the panel and command menu
	# arrive together once the intro clears.
	$PlayerStatusArea.visible = false


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
	# If we're inside the magic menu, route keys there. Same shape as
	# the item menu — Up/Down navigate, Enter confirms (with MP check),
	# Esc cancels. Cancel row is always present so nav modulo is safe.
	if magic_menu_active:
		var mag_nav_count: int = magic_menu_labels.size()
		if event.is_action_pressed("ui_up") and mag_nav_count > 0:
			magic_menu_cursor = (magic_menu_cursor - 1 + mag_nav_count) % mag_nav_count
			_update_magic_menu_cursor()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_down") and mag_nav_count > 0:
			magic_menu_cursor = (magic_menu_cursor + 1) % mag_nav_count
			_update_magic_menu_cursor()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_accept"):
			_confirm_magic_selection()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			magic_canceled.emit()
			get_viewport().set_input_as_handled()
		return

	# If we're inside the item menu, route keys there: Up/Down navigate,
	# Enter confirms, Esc/Backspace cancels (item_canceled signal).
	# Navigation now includes the Cancel row at the bottom, so the
	# modulo is item_menu_labels.size() (which is at least 1 — the
	# Cancel row is always present).
	if item_menu_active:
		var nav_count: int = item_menu_labels.size()
		if event.is_action_pressed("ui_up") and nav_count > 0:
			item_menu_cursor = (item_menu_cursor - 1 + nav_count) % nav_count
			_update_item_menu_cursor()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_down") and nav_count > 0:
			item_menu_cursor = (item_menu_cursor + 1) % nav_count
			_update_item_menu_cursor()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_accept"):
			_confirm_item_selection()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			# Cancel — back to action menu. battle.gd is the one that
			# actually changes state, so just emit and let it route.
			item_canceled.emit()
			get_viewport().set_input_as_handled()
		return

	# If we're inside a sub-menu (Cast — Item now has its own picker
	# handled above), any confirm/cancel key OR a left-click anywhere
	# sends the player back to the main menu.
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


# --- Player MP bar ---
# Mirrors the HP bar methods but for mana. No green/yellow/red color
# coding — the MP bar's fill color is set once in the .tscn (blue) and
# stays constant. All three methods no-op gracefully if the MP bar
# hasn't been added to the scene yet.

# Sets the MP bar maximum. Call before update_player_mp on first setup.
func set_player_max_mp(max_value: int) -> void:
	if player_mp_bar == null:
		return
	player_mp_bar.max_value = max_value
	_refresh_mp_text()


# Updates the MP bar to `value`. Animates a smooth drain by default
# (e.g. when a spell is cast); pass animate = false for the initial
# battle-start snap.
func update_player_mp(value: int, animate: bool = true) -> void:
	if player_mp_bar == null:
		return
	if animate:
		_animate_mp_bar(value)
	else:
		player_mp_bar.value = value
		_refresh_mp_text()


# Tweens the MP bar value + text overlay, mirroring _animate_hp_bar
# but without the color recalc (MP bar color is constant).
func _animate_mp_bar(target_value: int) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(player_mp_bar, "value", target_value, HP_DRAIN_DURATION)
	if player_mp_text != null:
		var start: int = int(player_mp_bar.value)
		var bar_max: int = int(player_mp_bar.max_value)
		tween.tween_method(
			func(v: int) -> void:
				player_mp_text.text = "%d / %d" % [v, bar_max],
			start, target_value, HP_DRAIN_DURATION)


# Updates the MP text overlay to "current / max". No-op when the bar
# or label is absent.
func _refresh_mp_text() -> void:
	if player_mp_text == null or player_mp_bar == null:
		return
	player_mp_text.text = "%d / %d" % [int(player_mp_bar.value), int(player_mp_bar.max_value)]


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
	# Reveal the player status panel alongside the command menu. It
	# starts hidden (see _ready) so it doesn't pop in during the intro
	# "Enemy appeared!" banner before the menu exists. Once shown it
	# stays visible — hide_menu() only hides the command menu, not the
	# status panel — so the stats persist through attacks/animations.
	$PlayerStatusArea.visible = true


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


# --- Item menu ---
# Builds a vertical list of the player's inventory items as a popup
# anchored where the action menu sits. Each row reads "ITEM_NAME × N".
# Arrow keys navigate, Enter / left-click confirm, Esc / right-click
# cancel. Mouse hover moves the cursor (mirrors the action menu UX).
#
# `inventory_dict` is RPGState.inventory — a Dictionary keyed by Item
# Resource with int quantity values. Empty inventory shows a "No
# items." line and only Esc dismisses.
func show_item_menu(inventory_dict: Dictionary) -> void:
	_ensure_item_menu_built()

	# Tear down any previous list entries so re-opening the menu shows
	# fresh quantities (e.g. after one Potion was just used).
	for lbl in item_menu_labels:
		lbl.queue_free()
	item_menu_labels.clear()
	item_menu_items.clear()
	item_menu_counts.clear()

	# One row per item the player owns. Empty inventory just skips this
	# block and goes straight to the Cancel row — the redundant
	# "No items." placeholder is left to the text box message (set by
	# battle.gd::_run_item_select).
	for item_key in inventory_dict.keys():
		var item: Item = item_key as Item
		if item == null:
			continue
		var qty: int = int(inventory_dict[item_key])
		var lbl := _make_item_menu_label(item, qty)
		item_menu_vbox.add_child(lbl)
		item_menu_labels.append(lbl)
		item_menu_items.append(item)
		item_menu_counts.append(qty)
		var idx: int = item_menu_labels.size() - 1
		lbl.mouse_entered.connect(_on_item_menu_label_hovered.bind(idx))
		lbl.gui_input.connect(_on_item_menu_label_input.bind(idx))

	# Cancel row always sits at the bottom. Its index in item_menu_labels
	# is item_menu_items.size() — that's the boundary _confirm_item_selection
	# and the hover/click handlers use to decide "is the cursor on Cancel?".
	var cancel_lbl := Label.new()
	cancel_lbl.text = "  Cancel"
	cancel_lbl.add_theme_font_size_override("font_size", 18)
	cancel_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	item_menu_vbox.add_child(cancel_lbl)
	item_menu_labels.append(cancel_lbl)
	var cancel_idx: int = item_menu_labels.size() - 1
	cancel_lbl.mouse_entered.connect(_on_item_menu_label_hovered.bind(cancel_idx))
	cancel_lbl.gui_input.connect(_on_item_menu_label_input.bind(cancel_idx))

	# Cursor starts on the first item, or on Cancel if inventory is
	# empty. Either way that's index 0 in the labels list.
	item_menu_cursor = 0
	item_menu_active = true
	item_menu_panel.visible = true
	_update_item_menu_cursor()


# Hides the item menu and disables input routing. battle.gd calls this
# when transitioning out of ITEM_SELECT (either confirm or cancel).
func hide_item_menu() -> void:
	item_menu_active = false
	if item_menu_panel != null:
		item_menu_panel.visible = false


# Lazily creates the item menu's container nodes on first use. Sits
# behind the regular action menu position-wise — anchored to the
# bottom-right of the screen.
func _ensure_item_menu_built() -> void:
	if item_menu_panel != null:
		return
	item_menu_panel = PanelContainer.new()
	item_menu_panel.anchor_left = 1.0
	item_menu_panel.anchor_top = 1.0
	item_menu_panel.anchor_right = 1.0
	item_menu_panel.anchor_bottom = 1.0
	item_menu_panel.offset_left = -300.0
	item_menu_panel.offset_top = -260.0
	item_menu_panel.offset_right = -20.0
	item_menu_panel.offset_bottom = -180.0
	item_menu_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	item_menu_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# IGNORE on the panel itself so a click between item labels doesn't
	# get consumed by the panel — the labels themselves have STOP for
	# their own click handling.
	item_menu_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(item_menu_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_menu_panel.add_child(margin)

	item_menu_vbox = VBoxContainer.new()
	item_menu_vbox.add_theme_constant_override("separation", 4)
	item_menu_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(item_menu_vbox)

	item_menu_panel.visible = false


# Builds one row Label for an inventory entry. Sets up mouse_filter
# STOP so hover/click signals fire (mirroring the action menu labels).
func _make_item_menu_label(item: Item, qty: int) -> Label:
	var lbl := Label.new()
	lbl.text = "  %s × %d" % [item.item_name, qty]
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	return lbl


# Redraws cursor indicator (">") on the highlighted row. Item rows
# show "Name × N"; the Cancel row at the bottom shows "Cancel". Both
# get the same prefix treatment for visual consistency.
func _update_item_menu_cursor() -> void:
	for i in item_menu_labels.size():
		var lbl: Label = item_menu_labels[i]
		var prefix: String = "> " if i == item_menu_cursor else "  "
		if i < item_menu_items.size():
			# Item row.
			var item: Item = item_menu_items[i]
			var qty: int = item_menu_counts[i]
			lbl.text = "%s%s × %d" % [prefix, item.item_name, qty]
		else:
			# Cancel row at the bottom.
			lbl.text = "%sCancel" % prefix


func _on_item_menu_label_hovered(idx: int) -> void:
	if not item_menu_active:
		return
	# Cancel row's index is item_menu_items.size(), so labels.size()
	# is the upper bound for hover.
	if idx < 0 or idx >= item_menu_labels.size():
		return
	item_menu_cursor = idx
	_update_item_menu_cursor()


func _on_item_menu_label_input(event: InputEvent, idx: int) -> void:
	if not item_menu_active:
		return
	if not _is_left_click(event):
		return
	if idx < 0 or idx >= item_menu_labels.size():
		return
	item_menu_cursor = idx
	_confirm_item_selection()
	get_viewport().set_input_as_handled()


# Fires the appropriate signal based on where the cursor sits. Item
# rows (cursor < items.size()) emit item_selected with the resource;
# the Cancel row at the bottom (cursor == items.size()) emits
# item_canceled — same code path as pressing Esc.
func _confirm_item_selection() -> void:
	if item_menu_cursor < 0 or item_menu_cursor >= item_menu_labels.size():
		return
	if item_menu_cursor < item_menu_items.size():
		# Item row.
		var picked: Item = item_menu_items[item_menu_cursor]
		item_selected.emit(picked)
	else:
		# Cancel row.
		item_canceled.emit()


# --- Magic menu ---
# Builds a vertical list of available spells with their MP costs. Same
# structure as the item menu (Labels in a panel, cursor + Enter +
# mouse). Spells the player can't afford (mp_cost > current MP) are
# visually dimmed and reject the selection with a "Not enough MP!"
# message — the menu stays open so the player can pick another.
#
# `spells` is an Array of Spell Resources. `current_mp` is the
# player's current MP at menu-open time — used to render the dim
# state and to gate the confirmation.
func show_magic_menu(spells: Array, current_mp: int) -> void:
	_ensure_magic_menu_built()

	# Tear down any previous list entries so re-opening shows fresh
	# state (e.g. spells the player can no longer afford after casting).
	for lbl in magic_menu_labels:
		lbl.queue_free()
	magic_menu_labels.clear()
	magic_menu_spells.clear()

	for spell_var in spells:
		var spell: Spell = spell_var as Spell
		if spell == null:
			continue
		var lbl := _make_magic_menu_label(spell, current_mp)
		magic_menu_vbox.add_child(lbl)
		magic_menu_labels.append(lbl)
		magic_menu_spells.append(spell)
		var idx: int = magic_menu_labels.size() - 1
		lbl.mouse_entered.connect(_on_magic_menu_label_hovered.bind(idx))
		lbl.gui_input.connect(_on_magic_menu_label_input.bind(idx))

	# Cancel row at the bottom — same pattern as the item menu.
	var cancel_lbl := Label.new()
	cancel_lbl.text = "  Cancel"
	cancel_lbl.add_theme_font_size_override("font_size", 18)
	cancel_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	magic_menu_vbox.add_child(cancel_lbl)
	magic_menu_labels.append(cancel_lbl)
	var cancel_idx: int = magic_menu_labels.size() - 1
	cancel_lbl.mouse_entered.connect(_on_magic_menu_label_hovered.bind(cancel_idx))
	cancel_lbl.gui_input.connect(_on_magic_menu_label_input.bind(cancel_idx))

	magic_menu_cursor = 0
	magic_menu_active = true
	magic_menu_panel.visible = true
	_update_magic_menu_cursor()


func hide_magic_menu() -> void:
	magic_menu_active = false
	if magic_menu_panel != null:
		magic_menu_panel.visible = false


# Lazily creates the magic menu panel on first use. Same screen position
# as the item menu (which is hidden when this one shows).
func _ensure_magic_menu_built() -> void:
	if magic_menu_panel != null:
		return
	magic_menu_panel = PanelContainer.new()
	magic_menu_panel.anchor_left = 1.0
	magic_menu_panel.anchor_top = 1.0
	magic_menu_panel.anchor_right = 1.0
	magic_menu_panel.anchor_bottom = 1.0
	magic_menu_panel.offset_left = -300.0
	magic_menu_panel.offset_top = -260.0
	magic_menu_panel.offset_right = -20.0
	magic_menu_panel.offset_bottom = -180.0
	magic_menu_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	magic_menu_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	magic_menu_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(magic_menu_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	magic_menu_panel.add_child(margin)

	magic_menu_vbox = VBoxContainer.new()
	magic_menu_vbox.add_theme_constant_override("separation", 4)
	magic_menu_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(magic_menu_vbox)

	magic_menu_panel.visible = false


# Builds one row Label for a spell. Sets up mouse_filter STOP so
# hover/click fires. Color reflects MP affordability — dimmed gray
# when the player can't afford it.
func _make_magic_menu_label(spell: Spell, current_mp: int) -> Label:
	var lbl := Label.new()
	lbl.text = "  %s (%d MP)" % [spell.spell_name, spell.mp_cost]
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	if current_mp < spell.mp_cost:
		# Dim uncastable spells. Visible enough to read, clearly
		# distinct from castable ones.
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	return lbl


# Redraws cursor indicator. Spell rows show "Name (X MP)"; Cancel
# row shows "Cancel". Color overrides from _make_magic_menu_label
# (dim for uncastable) survive the prefix re-render.
func _update_magic_menu_cursor() -> void:
	for i in magic_menu_labels.size():
		var lbl: Label = magic_menu_labels[i]
		var prefix: String = "> " if i == magic_menu_cursor else "  "
		if i < magic_menu_spells.size():
			var spell: Spell = magic_menu_spells[i]
			lbl.text = "%s%s (%d MP)" % [prefix, spell.spell_name, spell.mp_cost]
		else:
			lbl.text = "%sCancel" % prefix


func _on_magic_menu_label_hovered(idx: int) -> void:
	if not magic_menu_active:
		return
	if idx < 0 or idx >= magic_menu_labels.size():
		return
	magic_menu_cursor = idx
	_update_magic_menu_cursor()


func _on_magic_menu_label_input(event: InputEvent, idx: int) -> void:
	if not magic_menu_active:
		return
	if not _is_left_click(event):
		return
	if idx < 0 or idx >= magic_menu_labels.size():
		return
	magic_menu_cursor = idx
	_confirm_magic_selection()
	get_viewport().set_input_as_handled()


# Fires the appropriate signal based on cursor position. Spell rows
# emit spell_selected (and battle.gd handles MP check / target select);
# the Cancel row emits magic_canceled.
#
# Cheap MP check happens here too so the dim/disabled visual matches
# behavior — clicking a dimmed spell shows "Not enough MP!" and stays
# in the menu, letting the player pick something else without
# bouncing all the way back to the action menu.
func _confirm_magic_selection() -> void:
	if magic_menu_cursor < 0 or magic_menu_cursor >= magic_menu_labels.size():
		return
	if magic_menu_cursor >= magic_menu_spells.size():
		# Cancel row.
		magic_canceled.emit()
		return
	# Spell row.
	var picked: Spell = magic_menu_spells[magic_menu_cursor]
	spell_selected.emit(picked)


# --- Target cancel button ---
# Shown while battle.gd is in TARGET_SELECT so mouse users can click
# Cancel rather than reaching for Esc. The button is created lazily
# on first show and reused after that.

func show_target_cancel_button() -> void:
	_ensure_target_cancel_button_built()
	target_cancel_button.visible = true


func hide_target_cancel_button() -> void:
	if target_cancel_button != null:
		target_cancel_button.visible = false


# Builds the Cancel button on first use. Anchored to the bottom-right
# of the screen, positioned roughly in the same area as the action
# menu (which is hidden during target select, so the area is free).
func _ensure_target_cancel_button_built() -> void:
	if target_cancel_button != null:
		return
	target_cancel_button = Button.new()
	target_cancel_button.text = "Cancel"
	target_cancel_button.anchor_left = 1.0
	target_cancel_button.anchor_top = 1.0
	target_cancel_button.anchor_right = 1.0
	target_cancel_button.anchor_bottom = 1.0
	# 120x44 button, ~30px above the bottom edge and 20px from the right.
	target_cancel_button.offset_left = -140.0
	target_cancel_button.offset_top = -100.0
	target_cancel_button.offset_right = -20.0
	target_cancel_button.offset_bottom = -56.0
	target_cancel_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	target_cancel_button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	target_cancel_button.add_theme_font_size_override("font_size", 20)
	target_cancel_button.visible = false
	target_cancel_button.pressed.connect(func() -> void:
		target_cancel_clicked.emit())
	add_child(target_cancel_button)
