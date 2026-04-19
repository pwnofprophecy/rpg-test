# dialogue_box.gd
# A reusable CanvasLayer that sits at the bottom of the screen and shows
# two kinds of UI:
#   1. Simple text messages ("A pretty uncomfortable couch.") — press Enter to dismiss.
#   2. Choice menus ("What will you do?" with navigable options) — arrow keys + Enter.
#
# This script mirrors the input/signal pattern in battle_ui.gd, adapted for
# the overworld. It emits signals back to ground_floor.gd, which decides what
# to do based on the choice made.
#
# Usage:
#   dialogue_box.show_text("Some message.")
#   dialogue_box.show_choice("Prompt?", ["Option A", "Option B"])
# Listen to:
#   dialogue_box.dismissed         — text box was closed
#   dialogue_box.choice_made(int)  — player confirmed a choice (0-indexed)

extends CanvasLayer

# --- Signals ---
signal dismissed            # Plain text box was closed by the player
signal choice_made(index: int)  # Player confirmed a choice; index is 0-based

# --- Node References ---
@onready var panel: PanelContainer = $Panel
@onready var text_label: Label = $Panel/Margin/VBox/TextLabel
@onready var options_container: VBoxContainer = $Panel/Margin/VBox/OptionsContainer

# --- Internal State ---
var _choice_active: bool = false      # True when a choice menu is showing
var _cursor_index: int = 0            # Which choice is highlighted
var _options: Array = []              # The current list of option strings
var _option_labels: Array[Label] = [] # The Label nodes we create for each option


func _ready() -> void:
	# Start hidden — ground_floor.gd calls show_text or show_choice when needed.
	panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	# Ignore input when hidden. When visible, we consume all relevant keys
	# so ground_floor.gd doesn't also react to them.
	if not panel.visible:
		return

	if _choice_active:
		# --- Choice menu input ---
		var handled := true
		if event.is_action_pressed("ui_up") and _cursor_index > 0:
			_cursor_index -= 1
		elif event.is_action_pressed("ui_down") and _cursor_index < _option_labels.size() - 1:
			_cursor_index += 1
		elif event.is_action_pressed("ui_accept"):
			var selected := _cursor_index
			_close()
			choice_made.emit(selected)
		elif event.is_action_pressed("ui_cancel"):
			# Backspace cancels — we treat it as the last option (typically "Walk away").
			var last := _option_labels.size() - 1
			_close()
			choice_made.emit(last)
		else:
			handled = false

		if handled:
			_update_cursor()
			get_viewport().set_input_as_handled()
	else:
		# --- Plain text mode: any confirm or cancel key closes the box ---
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
			_close()
			dismissed.emit()
			get_viewport().set_input_as_handled()


# Show a simple dismissable text message.
# The player presses Enter or Backspace to close it.
func show_text(message: String) -> void:
	_choice_active = false
	text_label.text = message
	_clear_options()
	options_container.visible = false
	panel.visible = true


# Show a choice menu: a prompt at the top, then navigable options below.
# The player uses Up/Down arrows and presses Enter to confirm.
func show_choice(prompt: String, options: Array) -> void:
	_choice_active = true
	_cursor_index = 0
	text_label.text = prompt

	# Rebuild the option labels from scratch each time.
	# IMPORTANT: _clear_options() must run BEFORE we store `options` into `_options`.
	# Arrays in GDScript are reference types, so assigning _options = options makes
	# them share the same underlying data — and _clear_options() calls _options.clear(),
	# which would also empty the caller's array.
	_clear_options()
	_options = options.duplicate()  # duplicate() makes an independent copy for safety
	for option in _options:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 20)
		options_container.add_child(lbl)
		_option_labels.append(lbl)

	options_container.visible = true
	panel.visible = true
	_update_cursor()


# Returns true if the dialogue box is currently showing anything.
# ground_floor.gd uses this to know whether to freeze the player.
func is_open() -> bool:
	return panel.visible


# --- Private Helpers ---

# Removes all dynamically-created option labels.
func _clear_options() -> void:
	for child in options_container.get_children():
		child.queue_free()
	_option_labels.clear()
	_options.clear()


# Redraws the ">" cursor on the currently selected option.
func _update_cursor() -> void:
	for i in _option_labels.size():
		if i == _cursor_index:
			_option_labels[i].text = "> " + _options[i]
		else:
			_option_labels[i].text = "  " + _options[i]


# Hides the panel. Always call this before emitting signals so listeners
# don't trigger a new show_* call while we're still closing.
func _close() -> void:
	panel.visible = false
	_choice_active = false
