# mod_menu.gd
# A CanvasLayer overlay that lists all mods the player has found, and lets
# them toggle each one on or off. Opened from the PC in the Office room.
#
# When no mods have been found yet, it shows "No mods installed."
# Once mods are found, each one appears as:
#   "[ON]  RUN.EXE — Makes the Run command in battle actually work."
#   "[OFF] ITEMS.EXE — Unlocks the item menu in battle."
#
# The player uses Up/Down to navigate, Enter to toggle, and Backspace to close.

extends CanvasLayer

# --- Signals ---
signal closed    # Emitted when the player presses Backspace to close the menu

# --- Node References ---
@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/Margin/VBox/TitleLabel
@onready var mod_list: VBoxContainer = $Panel/Margin/VBox/ModList

# --- Internal State ---
var _mod_ids: Array = []       # The found mod IDs in display order
var _mod_labels: Array = []    # One Label per found mod
var _cursor_index: int = 0     # Currently highlighted row


func _ready() -> void:
	panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return

	if event.is_action_pressed("ui_up") and _cursor_index > 0:
		_cursor_index -= 1
		_update_cursor()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down") and _cursor_index < _mod_ids.size() - 1:
		_cursor_index += 1
		_update_cursor()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") and _mod_ids.size() > 0:
		_toggle_current()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		panel.visible = false
		closed.emit()
		get_viewport().set_input_as_handled()


# Returns true when the mod menu panel is currently showing.
# ground_floor.gd uses this to know whether input is "claimed" by this UI.
func is_open() -> bool:
	return panel.visible


# Opens the mod menu and rebuilds the list from ModManager's current state.
# Call this from ground_floor.gd whenever the player chooses "Manage Mods".
func open() -> void:
	_rebuild_list()
	panel.visible = true


# --- Private Helpers ---

# Rebuilds the mod list from scratch based on what ModManager currently knows.
func _rebuild_list() -> void:
	# Clear previous content
	for child in mod_list.get_children():
		child.queue_free()
	_mod_ids.clear()
	_mod_labels.clear()
	_cursor_index = 0

	# Collect all found mods from ModManager
	for mod_id in ModManager.mods:
		if ModManager.is_found(mod_id):
			_mod_ids.append(mod_id)

	if _mod_ids.is_empty():
		# Nothing found yet — show the empty-state label
		var lbl := Label.new()
		lbl.text = "No mods installed."
		lbl.add_theme_font_size_override("font_size", 20)
		mod_list.add_child(lbl)
	else:
		# Build one label row per found mod
		for mod_id in _mod_ids:
			var lbl := Label.new()
			lbl.add_theme_font_size_override("font_size", 20)
			mod_list.add_child(lbl)
			_mod_labels.append(lbl)
		_update_cursor()


# Refreshes all label texts to reflect current on/off state, and shows
# the ">" cursor on the highlighted row.
func _update_cursor() -> void:
	for i in _mod_labels.size():
		var mod_id: String = _mod_ids[i]
		var mod_data: Dictionary = ModManager.mods[mod_id]
		var status := "[ON] " if mod_data["active"] else "[OFF]"
		var prefix := "> " if i == _cursor_index else "  "
		_mod_labels[i].text = prefix + status + " " + mod_data["name"] + " — " + mod_data["description"]


# Toggles the mod the cursor is currently on.
func _toggle_current() -> void:
	if _cursor_index >= _mod_ids.size():
		return
	var mod_id: String = _mod_ids[_cursor_index]
	if ModManager.is_active(mod_id):
		ModManager.deactivate_mod(mod_id)
	else:
		ModManager.activate_mod(mod_id)
	_update_cursor()
