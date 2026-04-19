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
# Used for single-page messages. For multi-page dialog, fill out
# interaction_pages below instead — that takes priority.
@export var interaction_text: String = ""

# Optional multi-page text. If this array has any entries, each entry is shown
# as a separate page the player advances through by pressing Enter. Used for
# longer conversations or multi-sentence descriptions.
# Example: ["It's a dusty old trunk.", "A faint keyhole sits in the lid.", "I don't remember that being there."]
#
# When BOTH interaction_pages AND choice_options are set, the LAST page becomes
# the prompt sitting above the choice menu, and any earlier pages play as
# flavor text first. Example:
#   interaction_pages = ["I didn't leave the curtain drawn.", "Open it?"]
#   choice_options    = ["Open", "Leave alone"]
# → Player sees "I didn't leave the curtain drawn. ▼" (press Enter)
#   then "Open it?" with the Open / Leave alone options below it.
@export var interaction_pages: Array[String] = []

# If this array is non-empty, a choice menu is shown instead of a plain text box.
# Each string in the array is one menu option (e.g. ["Play RPG", "Manage Mods", "Walk away"]).
@export var choice_options: Array = []

# --- Secondary Dialog (optional) ---
# These fields mirror interaction_text / interaction_pages / choice_options
# and hold the dialog to use AFTER a progression event has changed this
# object's state (e.g. the shower curtain has been opened, a trunk has been
# unlocked, an NPC has been talked to before).
#
# The Interactable itself doesn't decide WHEN to swap — ground_floor.gd does,
# based on GameManager progression flags. When the swap happens, these values
# are copied into their primary counterparts above.
#
# Set these in the Godot Inspector alongside the primary fields. Leave them
# empty if the object never changes state.

# Secondary equivalent of interaction_text. Shown as a single-page message
# when the object is in its "after" state and no secondary_pages are set.
@export var secondary_text: String = ""

# Secondary equivalent of interaction_pages. When non-empty, takes priority
# over secondary_text just like interaction_pages takes priority over
# interaction_text. Combine with secondary_choice_options for a secondary
# multi-page flavor + choice menu.
@export var secondary_pages: Array[String] = []

# Secondary equivalent of choice_options. Leave empty for a plain text-only
# secondary dialog.
@export var secondary_choice_options: Array = []

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
