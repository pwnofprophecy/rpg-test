# doorway.gd
# A simple Area2D that marks a room exit point (a gap in the wall).
# When the player walks into this zone, ground_floor.gd loads the
# destination room and repositions the player at the correct entry point.
#
# Each room scene has one Doorway node per connection (e.g. EastDoor,
# SouthDoor). ground_floor.gd finds them by checking "if node is Doorway".

class_name Doorway
extends Area2D

# Which room this doorway leads to.
# Must match a key in ground_floor.gd's ROOMS dictionary
# (e.g. "kitchen", "bathroom", "office", "living_room").
@export var destination_room: String = ""

# Which SIDE of the destination room the player enters from.
# ground_floor.gd uses this to place the player at the right spawn position.
# Values: "north", "south", "east", "west"
# Example: if this doorway leads to the Kitchen from the east,
# entry_side = "west" (the player enters Kitchen from its west side).
@export var entry_side: String = ""
