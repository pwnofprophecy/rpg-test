# rpg_town.gd
# Root script for the RPG Town scene. The town is a small "safe zone"
# inside the RPG world — no random encounters, just NPCs to talk to and
# a single exit that returns the player to the overworld.
#
# It extends RPGLocationBase (scenes/rpg/rpg_location_base.gd), which
# provides everything every RPG location shares — the tier overlay shader,
# the pause menu + Save-confirm flow, camera snap-on-load, the [Interact]
# hint helper, and Exit-RPG handling (which resets the RPG location back to
# OVERWORLD so the next RPG entry doesn't reappear in town).
#
# This script adds ONLY what's unique to the town, via the base's virtual
# hooks:
#
#   _location_ready()        — auto-discover every Interactable in the scene
#                              and connect its proximity signals.
#   _handle_location_input() — Enter triggers whatever interactable the
#                              player is standing in (NPC, exit, etc.).
#
# The town does NOT override _can_open_pause — the base default (block while
# the pause menu or dialogue box is open) is exactly what we want.
#
# NPCs and the exit are Area2D + Interactable nodes placed in the .tscn.
# Their dialogue lives in interaction_pages on each Interactable, so you can
# edit text in the Godot Inspector without touching this script. The exit is
# just an Interactable with interaction_id = "town_exit".

extends RPGLocationBase

# --- Interactable proximity state ---
# The Interactable the player is currently inside, or null. Set in
# _on_zone_entered, cleared in _on_zone_exited, read by
# _handle_location_input when the player presses Enter.
var _current_zone: Interactable = null


# --- Virtual hook overrides ---

func _location_ready() -> void:
	# Auto-discover every Interactable anywhere under this scene and connect
	# its proximity signals. Recursive so NPCs can be wrapped in a Node2D
	# parent (e.g. to attach y_sorter.gd) without breaking the search. Add
	# new NPCs and exits in the editor without ever touching this script —
	# just attach interactable.gd to an Area2D and fill in its
	# interaction_id / interaction_pages / hint_text in the Inspector.
	for ix in find_children("*", "Interactable", true, false):
		var zone: Interactable = ix as Interactable
		if zone == null:
			continue
		zone.player_entered_zone.connect(_on_zone_entered)
		zone.player_left_zone.connect(_on_zone_exited)


func _handle_location_input(event: InputEvent) -> void:
	# Enter triggers whatever interactable the player is standing in
	# (NPC, exit, etc.), provided no UI is blocking. The dialogue box
	# and pause menu both consume input themselves while open, so we
	# only need to guard explicitly against those.
	if event.is_action_pressed("ui_accept"):
		if _current_zone != null and not pause_menu.is_open() and not dialogue_box.is_open():
			_trigger_zone(_current_zone)
			get_viewport().set_input_as_handled()
		return


# --- Interactable zone tracking ---

func _on_zone_entered(zone: Interactable) -> void:
	_current_zone = zone
	_show_hint(zone.hint_text)


func _on_zone_exited(zone: Interactable) -> void:
	# Only clear if it's the zone we last entered — guards against an
	# overlap-then-walk-out from a different zone clobbering us.
	if _current_zone == zone:
		_current_zone = null
		_show_hint("")


# --- Interaction routing ---

func _trigger_zone(zone: Interactable) -> void:
	# Special-case zones routed by interaction_id (e.g. the exit). Anything
	# else falls through to the generic NPC text path, which reads
	# interaction_pages / interaction_text off the Interactable directly.
	# That means new NPCs only need an interaction_id + dialogue text in
	# the Inspector — no script change required.
	match zone.interaction_id:
		"town_exit":
			# Hide the hint immediately so it doesn't flash for a frame on
			# the overworld before the player walks out of the entrance zone.
			_show_hint("")
			GameManager.switch_rpg_location(GameManager.RPGLocation.OVERWORLD)
		_:
			_show_npc_dialogue(zone)


func _show_npc_dialogue(zone: Interactable) -> void:
	# interaction_pages takes priority over interaction_text. If neither
	# is set, fall back to a placeholder so we know which NPC needs text.
	_dialog_mode = DialogMode.NPC_TEXT
	if not zone.interaction_pages.is_empty():
		dialogue_box.show_text(zone.interaction_pages)
	elif zone.interaction_text != "":
		dialogue_box.show_text(zone.interaction_text)
	else:
		dialogue_box.show_text("(This NPC has no dialogue set on its Interactable.)")
