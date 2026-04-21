# name_entry.gd
# A CanvasLayer overlay that prompts the player for the Hero's name on the
# first RPG entry. Shows a LineEdit + Confirm button. On confirm, writes the
# name into RPGState and emits `name_confirmed` so the overworld can close us.
#
# Rules:
#   - Empty input (or pure whitespace) is REJECTED: Confirm is disabled and
#     pressing Enter does nothing. The overlay stays open until the player
#     types at least one non-whitespace character.
#   - The entered name is trimmed (leading/trailing whitespace stripped)
#     before being stored, so "  HERO  " becomes "HERO".
#   - Enter key works the same as clicking Confirm (LineEdit.text_submitted).
#   - Shown only when RPGState.character_name == "" on RPG entry; after the
#     player confirms, character_name is non-empty and we never show again
#     (until a new-game reset).
#
# Why separate this from the overworld?
#   The overworld has its own _unhandled_input, pause menu, shader overlay,
#   and eventually encounter logic. Keeping name entry as a standalone scene
#   means we can later swap the UI (fancy cursor, NES-style letter grid, etc.)
#   without touching overworld code.

extends CanvasLayer

# Emitted once the player confirms a non-empty name.
signal name_confirmed(hero_name: String)

@onready var line_edit: LineEdit = $Panel/Margin/VBox/LineEdit
@onready var confirm_button: Button = $Panel/Margin/VBox/ConfirmButton


func _ready() -> void:
	# Pre-fill with "HERO" so the player sees a suggestion and can just press
	# Enter to accept, or overwrite it with their own name.
	line_edit.text = "HERO"
	# Select-all so typing immediately overwrites the suggestion.
	line_edit.select_all()
	line_edit.grab_focus()

	# Wire confirm paths:
	#   - Button click: straightforward.
	#   - Enter in the LineEdit: we DO NOT use the `text_submitted` signal
	#     here. That signal fires after LineEdit has already internally
	#     triggered its "release focus on submit" behavior, and regrabbing
	#     focus afterward (even deferred) is fragile. Instead we listen to
	#     `gui_input` and intercept Enter ourselves, calling accept_event()
	#     so LineEdit never sees the key and never releases focus. The
	#     field stays active whether we accept or reject the input.
	confirm_button.pressed.connect(_on_confirm)
	line_edit.gui_input.connect(_on_line_edit_input)

	# React to every keystroke so we can disable Confirm on empty input.
	# This gives the player visual feedback that blank names aren't allowed
	# rather than silently ignoring their Enter press.
	line_edit.text_changed.connect(_on_text_changed)
	# Sync initial button state with the pre-filled text.
	_refresh_confirm_enabled()


func _on_text_changed(_new_text: String) -> void:
	_refresh_confirm_enabled()


func _refresh_confirm_enabled() -> void:
	# Button is only clickable when the field contains at least one
	# non-whitespace character.
	confirm_button.disabled = line_edit.text.strip_edges() == ""


func _on_line_edit_input(event: InputEvent) -> void:
	# Intercept Enter before LineEdit's default handler runs. We check
	# both KEY_ENTER (main Return) and KEY_KP_ENTER (numpad). accept_event()
	# stops LineEdit from seeing the key, which keeps the caret alive
	# regardless of whether we accept or reject the name.
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		# accept_event() lives on Control, not CanvasLayer, so we call it
		# on the LineEdit itself — it's a Control and its accept_event
		# marks the viewport input as handled before LineEdit's default
		# gui handler processes the key.
		line_edit.accept_event()
		_on_confirm()


func _on_confirm() -> void:
	var entered: String = line_edit.text.strip_edges()
	if entered == "":
		# Reject silently. Because we consumed the Enter key in
		# _on_line_edit_input, LineEdit never ran its release-focus logic,
		# so the caret is still in the field — nothing else to do.
		return
	RPGState.character_name = entered
	RPGState.stats_changed.emit()
	name_confirmed.emit(entered)
