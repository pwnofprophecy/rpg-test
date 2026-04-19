# dialogue_box.gd
# A reusable CanvasLayer that sits at the bottom of the screen and shows
# two kinds of UI:
#   1. Simple text messages — press Enter to advance pages, then dismiss.
#      Supports both single-page (pass a String) and multi-page (pass an
#      Array[String] of "pages"). Multi-page flows show a ▼ indicator while
#      more pages remain.
#   2. Choice menus ("What will you do?" with navigable options) — arrow keys + Enter.
#
# This script mirrors the input/signal pattern in battle_ui.gd, adapted for
# the overworld. It emits signals back to ground_floor.gd, which decides what
# to do based on the choice made.
#
# Usage:
#   dialogue_box.show_text("Some message.")                       # single page
#   dialogue_box.show_text(["First line.", "Second line.", "..."])  # multi-page
#   dialogue_box.show_choice("Prompt?", ["Option A", "Option B"])
# Listen to:
#   dialogue_box.dismissed         — text box was fully closed (last page advanced)
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

# Multi-page text state. A page is one chunk of text the player sees before
# pressing Enter to advance. When pages is empty or we've advanced past the
# last index, the dialog dismisses.
var _pages: Array[String] = []
var _current_page: int = 0

# Suffix appended to the displayed text when more pages remain. Pure visual
# cue so the player knows to press Enter to see more.
const MORE_INDICATOR: String = "  ▼"


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
		# --- Plain text mode ---
		# ui_accept advances to the next page, or closes on the last page.
		# ui_cancel always closes immediately (lets the player skip).
		if event.is_action_pressed("ui_accept"):
			_advance_page()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			_close()
			dismissed.emit()
			get_viewport().set_input_as_handled()


# Show a dismissable text message.
# Accepts either a single String (one page) or an Array[String] (multiple
# pages the player advances through with Enter).
# The `content` parameter is typed as Variant so callers don't have to wrap
# single strings in arrays.
func show_text(content: Variant) -> void:
	_choice_active = false
	_clear_options()
	options_container.visible = false

	# Normalize the input to a list of pages.
	if content is String:
		_pages = [content]
	elif content is Array:
		# duplicate() so clearing _pages later doesn't affect the caller's array.
		# Also coerce each element to String for safety.
		_pages = []
		for item in content:
			_pages.append(str(item))
		if _pages.is_empty():
			_pages = [""]
	else:
		# Unexpected type — fall back to string conversion so we don't crash.
		_pages = [str(content)]

	_current_page = 0
	_render_current_page()
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


# Writes the currently-selected page into the text label. Appends a "more"
# indicator when additional pages remain so the player knows to press Enter
# to continue.
func _render_current_page() -> void:
	var text: String = _pages[_current_page]
	if _current_page < _pages.size() - 1:
		text += MORE_INDICATOR
	text_label.text = text


# Called when the player presses Enter in plain text mode. Advances to the
# next page if there is one; otherwise closes the dialog and fires the
# `dismissed` signal so ground_floor.gd can unfreeze the player.
func _advance_page() -> void:
	if _current_page + 1 < _pages.size():
		_current_page += 1
		_render_current_page()
	else:
		_close()
		dismissed.emit()


# Hides the panel. Always call this before emitting signals so listeners
# don't trigger a new show_* call while we're still closing.
func _close() -> void:
	panel.visible = false
	_choice_active = false
	_pages.clear()
	_current_page = 0
