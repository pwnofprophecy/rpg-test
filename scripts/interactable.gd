# interactable.gd
# A reusable Area2D component that marks an object in the world as something
# the player can interact with (by pressing Enter near it).
#
# Each interactable object in a room (couch, TV, sink, etc.) has one of these
# as a child node. The ground_floor.gd script listens to this class's signals
# to know when the player is nearby and what to show when they press Enter.
#
# Physical collision (stopping the player from walking through objects) is
# handled by a SEPARATE StaticBody2D sibling — this class only handles
# the "nearby enough to interact" detection zone.

class_name Interactable
extends Area2D

# --- Exported Configuration ---
# These are set in the .tscn scene file so each object can have different text
# without needing its own unique script.

# A unique string ID so ground_floor.gd knows which object was triggered.
# Used for special-case logic (e.g. "pc" opens the PC menu, "shower" opens the curtain).
@export var interaction_id: String = ""

# The text shown in the dialogue box when the player interacts.
@export var interaction_text: String = ""

# If this array is non-empty, a choice menu is shown instead of a plain text box.
# Each string in the array is one menu option (e.g. ["Play RPG", "Manage Mods", "Walk away"]).
@export var choice_options: Array = []

# --- Signals ---
# Emitted to ground_floor.gd so it can track which interactable the player is near.

# Fires when the player's collision body enters this Area2D's detection zone.
signal player_entered_zone(which: Interactable)

# Fires when the player walks away and leaves the detection zone.
signal player_left_zone(which: Interactable)


func _ready() -> void:
	# Connect to our own Area2D body signals so we can re-emit them as
	# named signals that ground_floor.gd can listen to.
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	# "player" is a group we add to the player node in player.gd.
	# Checking the group (instead of the node type) is safer — it avoids
	# accidentally triggering on other CharacterBody2D nodes in future.
	if body.is_in_group("player"):
		player_entered_zone.emit(self)


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		player_left_zone.emit(self)
