# ground_floor.gd
# The root script for the Real World ground floor. It owns:
#   - The player character
#   - The room currently being displayed
#   - The dialogue box and mod menu UI
#
# Its main responsibilities are:
#   1. Loading rooms and repositioning the player when they walk through a doorway.
#   2. Tracking which interactable object the player is standing next to.
#   3. Showing the dialogue box or mod menu when the player presses Enter.
#   4. Routing the player's choices (PC menu, shower curtain, floppy pickup) to
#      the right outcome.

extends Node2D

# --- Room Scenes ---
# All four rooms preloaded so switching between them is instant.
const ROOMS: Dictionary = {
	"living_room": preload("res://scenes/real_world/rooms/living_room.tscn"),
	"kitchen":     preload("res://scenes/real_world/rooms/kitchen.tscn"),
	"office":      preload("res://scenes/real_world/rooms/office.tscn"),
	"bathroom":    preload("res://scenes/real_world/rooms/bathroom.tscn"),
}

# Where to spawn the player depending on which side of the room they entered from.
# "entering from east" means they came through the east doorway, so we place
# them just inside the east edge of the new room.
const ENTRY_POSITIONS: Dictionary = {
	"north": Vector2(576, 70),
	"south": Vector2(576, 578),
	"east":  Vector2(1082, 324),
	"west":  Vector2(70, 324),
}

# --- Node References ---
@onready var room_container: Node = $RoomContainer
@onready var player: CharacterBody2D = $Player
@onready var dialogue_box = $UI/DialogueBox
@onready var mod_menu = $UI/ModMenu
@onready var interact_hint: Label = $UI/InteractHint

# --- State ---
var current_room_name: String = "living_room"
# The Interactable node the player is currently standing next to, or null.
var current_interactable = null
# The Interactable that opened the currently visible dialog. Set when dialog opens,
# cleared when it closes. This is separate from current_interactable because
# freezing the player (PROCESS_MODE_DISABLED) removes them from the physics
# server, which fires body_exited and nulls current_interactable — but we still
# need to remember which object we were interacting with to route the choice.
var _active_interactable: Interactable = null

# When an Interactable has both interaction_pages AND choice_options, we first
# play the flavor pages as plain text. This dictionary holds the choice that
# should appear AFTER those pages are dismissed. Empty when nothing is pending.
# Keys: "prompt" (String), "options" (Array).
var _pending_choice: Dictionary = {}


func _ready() -> void:
	# Start in the Living Room. Passing "" as entry_side centers the player.
	_load_room("living_room", "")

	# Wire up dialogue box signals.
	dialogue_box.dismissed.connect(_on_dialogue_dismissed)
	dialogue_box.choice_made.connect(_on_choice_made)

	# Wire up mod menu close signal.
	mod_menu.closed.connect(_on_mod_menu_closed)

	interact_hint.visible = false


func _unhandled_input(event: InputEvent) -> void:
	# Don't intercept input while a UI panel is already open.
	if dialogue_box.is_open() or mod_menu.is_open():
		return

	if event.is_action_pressed("ui_accept") and current_interactable != null:
		_handle_interaction(current_interactable)
		get_viewport().set_input_as_handled()


# --- Room Loading ---

func _load_room(room_name: String, entry_side: String) -> void:
	# Remove the old room.
	for child in room_container.get_children():
		child.queue_free()

	current_interactable = null
	_active_interactable = null
	_pending_choice = {}
	interact_hint.visible = false

	# Instantiate the new room and add it.
	var room_instance: Node2D = ROOMS[room_name].instantiate()
	room_container.add_child(room_instance)
	current_room_name = room_name

	# Connect all Interactable and Doorway signals in the new room.
	_connect_room_signals(room_instance)

	# Apply any persistent state for this room (e.g. shower already opened,
	# floppy already picked up). This has to happen AFTER instantiation so we
	# can mutate the fresh nodes, not the packed scene.
	_apply_persistent_state(room_name, room_instance)

	# Place the player at the correct spawn point.
	if entry_side != "" and ENTRY_POSITIONS.has(entry_side):
		player.position = ENTRY_POSITIONS[entry_side]
	else:
		player.position = Vector2(576, 324)


# Walks every descendant of the new room and connects signals on Interactable
# and Doorway nodes. We recurse because objects are nested several levels deep.
func _connect_room_signals(room: Node2D) -> void:
	for node in _get_all_children(room):
		if node is Interactable:
			node.player_entered_zone.connect(_on_player_entered_zone)
			node.player_left_zone.connect(_on_player_left_zone)
		elif node is Doorway:
			# bind(node) packages the Doorway reference into the callback so we
			# know which doorway triggered the event.
			node.body_entered.connect(_on_doorway_entered.bind(node))


# Reads persistent flags from GameManager and mutates the freshly-instanced
# room to match. Called every time a room is loaded, so returning to a room
# after a change preserves that change.
func _apply_persistent_state(room_name: String, room: Node2D) -> void:
	if room_name == "bathroom":
		# Case 1: the player already opened the shower curtain at some point.
		# Replace the shower's "Open / Leave alone" dialog with a plain message
		# that just says the curtain is already drawn back.
		if GameManager.get_flag("shower_opened"):
			var shower: Interactable = _find_node_by_id(room, "shower")
			if shower != null:
				_apply_shower_opened_state(shower)

			# If the floppy is still in the world (not yet picked up), reveal it
			# so the player sees it sitting there on their return trip.
			if not GameManager.get_flag("floppy_picked_up"):
				var floppy: Interactable = _find_node_by_id(room, "floppy_run")
				if floppy != null:
					floppy.visible = true

		# Case 2: the player already picked up the floppy. Remove it from the
		# scene entirely so it can't be picked up again.
		if GameManager.get_flag("floppy_picked_up"):
			var floppy: Interactable = _find_node_by_id(room, "floppy_run")
			if floppy != null:
				floppy.queue_free()


# Returns every descendant of a node as a flat array (recursive).
func _get_all_children(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		result.append(child)
		result.append_array(_get_all_children(child))
	return result


# --- Interactable Tracking ---

func _on_player_entered_zone(which: Interactable) -> void:
	# is_visible_in_tree() checks both the node's own visibility AND all its
	# ancestors — important for the FloppyDisk (visible=false until shower opened)
	# and for ShowerInteractable (its parent StaticBody2D gets hidden after opening).
	if not which.is_visible_in_tree():
		return
	current_interactable = which
	interact_hint.visible = true


func _on_player_left_zone(which: Interactable) -> void:
	if current_interactable == which:
		current_interactable = null
		interact_hint.visible = false


# --- Doorway Handling ---

func _on_doorway_entered(body: Node2D, doorway: Doorway) -> void:
	if not body.is_in_group("player"):
		return
	# call_deferred prevents crashing from modifying the scene tree while a
	# physics callback is still running.
	call_deferred("_load_room", doorway.destination_room, doorway.entry_side)


# --- Interaction Routing ---

func _handle_interaction(target: Interactable) -> void:
	# Remember which object we're interacting with. Do this BEFORE freezing the
	# player — once frozen, the player exits the Area2D zone and current_interactable
	# gets cleared by _on_player_left_zone.
	_active_interactable = target

	# Freeze the player so they can't walk away mid-dialogue.
	player.process_mode = Node.PROCESS_MODE_DISABLED

	# Floppy pickup: register the find immediately, then show the pickup message.
	# When the player dismisses the text, _on_dialogue_dismissed removes the node.
	if target.interaction_id == "floppy_run":
		ModManager.mark_found("run")
		dialogue_box.show_text("You picked up [RUN.EXE]!")
		return

	# Decide the dialog flow based on which fields the Interactable has set:
	#   - pages only        → play all pages as plain text
	#   - choices only      → show choice menu with interaction_text as prompt
	#   - pages + choices   → play all pages EXCEPT the last, then show the last
	#                         page as the prompt for the choice menu
	#   - neither           → show interaction_text as a single-page message
	var has_pages := not target.interaction_pages.is_empty()
	var has_choices := not target.choice_options.is_empty()

	if has_pages and has_choices:
		# The last page is the prompt that sits above the choice options.
		# Any earlier pages are flavor text shown in sequence first.
		var prompt: String = target.interaction_pages[-1]
		if target.interaction_pages.size() == 1:
			# Only one page — skip straight to the choice menu using it as prompt.
			dialogue_box.show_choice(prompt, target.choice_options)
		else:
			# Play the earlier pages first; stash the choice for after dismissal.
			var flavor_pages: Array = target.interaction_pages.slice(0, -1)
			_pending_choice = {"prompt": prompt, "options": target.choice_options}
			dialogue_box.show_text(flavor_pages)
	elif has_pages:
		dialogue_box.show_text(target.interaction_pages)
	elif has_choices:
		dialogue_box.show_choice(target.interaction_text, target.choice_options)
	else:
		dialogue_box.show_text(target.interaction_text)


func _on_dialogue_dismissed() -> void:
	# If flavor text just finished and a choice menu is queued up (set by
	# _handle_interaction for objects with pages + choices), switch to the
	# choice menu now. Do NOT unfreeze the player — the interaction isn't
	# over yet, it's just changing modes.
	if not _pending_choice.is_empty():
		var prompt: String = _pending_choice.get("prompt", "")
		var options: Array = _pending_choice.get("options", [])
		_pending_choice = {}
		dialogue_box.show_choice(prompt, options)
		return

	# After picking up the floppy, remove it from the scene and persist the
	# pickup so returning to the bathroom later won't spawn another one.
	if _active_interactable != null and _active_interactable.interaction_id == "floppy_run":
		GameManager.set_flag("floppy_picked_up", true)
		_active_interactable.queue_free()
		current_interactable = null
		interact_hint.visible = false

	_active_interactable = null
	player.process_mode = Node.PROCESS_MODE_INHERIT


func _on_choice_made(index: int) -> void:
	var id: String = _active_interactable.interaction_id if _active_interactable else ""

	match id:
		"pc":
			match index:
				0: # "Play RPG"
					player.process_mode = Node.PROCESS_MODE_INHERIT
					GameManager.switch_to_world(GameManager.World.RPG)
				1: # "Manage Mods" — stay frozen, open mod menu instead
					mod_menu.open()
				2: # "Walk away"
					player.process_mode = Node.PROCESS_MODE_INHERIT

		"shower":
			match index:
				0: # "Open"
					_open_shower_curtain()
					# Player stays frozen — we show the discovery text next
				1: # "Leave alone"
					player.process_mode = Node.PROCESS_MODE_INHERIT

		_:
			player.process_mode = Node.PROCESS_MODE_INHERIT


# Reveals the floppy disk, rewrites the shower's interaction to its post-reveal
# state, and shows the discovery message.
func _open_shower_curtain() -> void:
	# Record that the shower has been opened, so returning to the bathroom
	# later loads it in the already-opened state.
	GameManager.set_flag("shower_opened", true)

	var room: Node2D = room_container.get_child(0)

	# Rewrite the shower Interactable in-place so the player can still interact
	# with it (now seeing the post-reveal text) without having to leave and
	# come back. _apply_persistent_state sets the same values on future room
	# loads; _apply_shower_opened_state is the single source of truth.
	var shower_interactable: Interactable = _find_node_by_id(room, "shower")
	if shower_interactable != null:
		_apply_shower_opened_state(shower_interactable)

	# The FloppyDisk is the Interactable node itself (not a child of a StaticBody2D),
	# so we show the node directly.
	var floppy: Node = _find_node_by_id(room, "floppy_run")
	if floppy != null:
		floppy.visible = true

	# Clear the interactable references so the next Enter press doesn't
	# re-trigger the shower dialog mid-transition. The player is frozen
	# while the discovery text is showing; when they dismiss it and physics
	# re-engages, the Area2D will re-fire body_entered if they're still in
	# the zone, setting current_interactable to the (now post-reveal) shower.
	current_interactable = null
	_active_interactable = null
	interact_hint.visible = false

	# Show discovery text. When the player dismisses it, _on_dialogue_dismissed
	# unfreezes them. They can then walk to the floppy and press Enter to pick it up.
	dialogue_box.show_text("You find a floppy disk behind the curtain.")


# Mutates a shower Interactable into its "already opened" state. Called from
# both _open_shower_curtain (same-session reveal) and _apply_persistent_state
# (room re-entry), so the two code paths can never disagree about what the
# opened shower says.
#
# The actual post-reveal dialog is authored in the Godot Inspector on the
# ShowerInteractable node itself, via the secondary_text / secondary_pages /
# secondary_choice_options fields on the Interactable. This function just
# copies those fields into the primary interaction_* fields so the normal
# _handle_interaction flow picks them up.
func _apply_shower_opened_state(shower: Interactable) -> void:
	# Copy the author-provided secondary dialog into the primary fields that
	# _handle_interaction reads. Duplicate the arrays so mutating one doesn't
	# mutate the source of truth on the Interactable.
	shower.interaction_text = shower.secondary_text
	shower.interaction_pages = shower.secondary_pages.duplicate()
	shower.choice_options = shower.secondary_choice_options.duplicate()


# Searches all descendants of root for an Interactable with the given interaction_id.
func _find_node_by_id(root: Node, id: String):
	for node in _get_all_children(root):
		if node is Interactable and node.interaction_id == id:
			return node
	return null


# --- Mod Menu ---

func _on_mod_menu_closed() -> void:
	player.process_mode = Node.PROCESS_MODE_INHERIT
