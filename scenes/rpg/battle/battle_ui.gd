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

# --- Menu State ---
var cursor_index: int = 0    # Which menu option is currently highlighted (0–3)
var menu_active: bool = false      # True when the player can navigate the main menu
var sub_menu_active: bool = false  # True when the player is inside Cast or Item

# The action strings that match each menu slot by index.
# Index 0 = "attack", 1 = "cast", 2 = "item", 3 = "run".
# "const" means this list never changes at runtime.
const ACTIONS: Array[String] = ["attack", "cast", "item", "run"]


# _unhandled_input is called automatically by Godot whenever a key is pressed,
# but only if no other node has already "handled" it.
# We use this to drive menu navigation without needing a polling loop.
func _unhandled_input(event: InputEvent) -> void:
	# If we're inside a sub-menu (Cast or Item), any confirm/cancel key
	# sends the player back to the main menu.
	if sub_menu_active:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
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
# Also updates the bar's color based on remaining health percentage.
func update_player_hp(value: int) -> void:
	player_hp_bar.value = value
	_update_bar_color(player_hp_bar)


# Updates the enemy's HP bar to reflect the new value.
func update_enemy_hp(value: int) -> void:
	enemy_hp_bar.value = value
	_update_bar_color(enemy_hp_bar)


# Sets the player's HP bar maximum so the fill ratio reflects real stats
# (e.g. RPGState.max_hp of 30) instead of the placeholder 10 from the
# .tscn. Call this BEFORE update_player_hp on first setup so the colour
# calculation uses the right max.
func set_player_max_hp(max_value: int) -> void:
	player_hp_bar.max_value = max_value


# Sets the enemy's HP bar maximum the same way.
func set_enemy_max_hp(max_value: int) -> void:
	enemy_hp_bar.max_value = max_value


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
