# pause_menu.gd
# A shared CanvasLayer overlay that shows when the player presses Escape.
# Used by BOTH the Real World and the RPG — each world tells it which
# options to show by passing a list into `open()`.
#
# Not a dialog for arbitrary text — it's purpose-built for a "pause ->
# select an option -> close" flow. For general text messages we still use
# the DialogueBox. For the Save / Exit confirmation dialogs that the pause
# menu triggers, the owning world reuses its existing DialogueBox choice
# menu; this keeps the pause menu itself small and single-purpose.
#
# Why is the owning world responsible for routing?
#   Because "Save" means different things in different worlds (future save
#   semantics may differ between Real World and RPG), and "Exit RPG" is
#   meaningless in the Real World. Rather than baking world knowledge into
#   this script, we emit `option_selected(id)` and let each world decide.
#
# Usage:
#   pause_menu.open([
#       {"id": "resume", "label": "Resume"},
#       {"id": "save", "label": "Save"},
#       {"id": "exit_rpg", "label": "Exit RPG"},
#   ])
#   # Listen for the choice:
#   pause_menu.option_selected.connect(func(id): ...)
#   pause_menu.closed.connect(...)

extends CanvasLayer

# Emitted when the player confirms one of the listed options. The `id` is
# whatever the caller set in the options dictionary — "resume", "save",
# "exit_rpg", "quit_game", etc. The caller decides what each id means.
signal option_selected(id: String)

# Emitted after the menu panel is fully hidden, regardless of how it closed
# (selection, Resume, or Escape). Useful for unfreezing the player.
signal closed

# --- Node References ---
# Filled in _ready(). The scene only defines a Panel skeleton — we build
# the option Labels dynamically so the same scene file can host any list
# of options without scene-level edits.
@onready var panel: PanelContainer = $Panel
@onready var options_container: VBoxContainer = $Panel/Margin/VBox/OptionsContainer
# Semi-transparent backdrop that darkens everything behind the menu.
# Toggled in sync with the panel so it appears/disappears together.
@onready var dim: ColorRect = $Dim

# --- State ---
# The list of options currently displayed. Each entry is a Dictionary
# with at minimum "id" and "label" keys (see `open`).
var _options: Array = []
# Label nodes in the same order as _options. Rebuilt on each open().
var _option_labels: Array[Label] = []
# Which option is highlighted. Resets to 0 every open.
var _cursor_index: int = 0


func _ready() -> void:
	# Start hidden. Whoever owns the pause menu calls open() when the
	# player presses Escape.
	panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	# Completely ignore input while closed — we don't want the pause menu
	# to compete with dialogue / normal gameplay inputs.
	if not panel.visible:
		return

	var handled := true

	if event.is_action_pressed("ui_up") and _cursor_index > 0:
		_cursor_index -= 1
	elif event.is_action_pressed("ui_down") and _cursor_index < _option_labels.size() - 1:
		_cursor_index += 1
	elif event.is_action_pressed("ui_accept"):
		# Player confirmed the current selection. Grab the id first because
		# _close() clears _options. Mark the input as handled BEFORE
		# emitting so the owning scene doesn't also react to this Enter
		# press (e.g. re-trigger an interactable).
		var id: String = _options[_cursor_index].get("id", "")
		get_viewport().set_input_as_handled()
		_close()
		option_selected.emit(id)
		closed.emit()
		return
	elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		# Backspace or Escape (pause) while menu is open = same as Resume.
		# Must mark the input handled here, otherwise the Escape press
		# bubbles up to the owning scene's _unhandled_input, which would
		# immediately re-open the pause menu.
		get_viewport().set_input_as_handled()
		_close()
		option_selected.emit("resume")
		closed.emit()
		return
	else:
		handled = false

	if handled:
		_update_cursor()
		get_viewport().set_input_as_handled()


# Opens the pause menu with the given list of options.
# Each option is a Dictionary: {"id": String, "label": String}.
# Rebuilds the Label children so the options list is fully dynamic.
func open(options: Array) -> void:
	# Duplicate the incoming array so the caller's array isn't tied to our
	# internal state — same reason the dialogue box does this.
	_options = []
	for opt in options:
		_options.append(opt.duplicate())

	_clear_labels()
	for opt in _options:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 22)
		options_container.add_child(lbl)
		_option_labels.append(lbl)

	_cursor_index = 0
	_update_cursor()
	dim.visible = true
	panel.visible = true


# Returns true while the menu panel is visible. Owning worlds use this to
# suppress other input (interaction prompts, movement) while paused.
func is_open() -> bool:
	return panel.visible


# --- Private helpers ---

func _clear_labels() -> void:
	for child in options_container.get_children():
		child.queue_free()
	_option_labels.clear()


func _update_cursor() -> void:
	for i in _option_labels.size():
		var label: String = _options[i].get("label", "")
		if i == _cursor_index:
			_option_labels[i].text = "> " + label
		else:
			_option_labels[i].text = "  " + label


func _close() -> void:
	panel.visible = false
	dim.visible = false
	_options.clear()
	_clear_labels()
