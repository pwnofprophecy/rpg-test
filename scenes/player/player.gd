# player.gd
# Controls the player character's movement in the overworld.
# This script is attached to the Player node in main.tscn.

extends CharacterBody2D

# How fast the player moves, in pixels per second.
# The "@export" keyword makes this value show up in the Godot editor,
# so you can tweak it without touching the code.
@export var speed: float = 200.0

# _physics_process runs every physics frame (60 times per second by default).
# The "_delta" parameter is the time since the last frame — we're not using it
# here, but Godot requires it in the function signature.
func _physics_process(_delta: float) -> void:
	# Read arrow key (or WASD) input and turn it into a direction vector.
	# For example, pressing Right gives (1, 0), pressing Down gives (0, 1),
	# pressing both gives a diagonal like (0.7, 0.7).
	# The result is automatically normalized so diagonal movement isn't faster.
	var direction = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")

	# Multiply the direction by our speed to get the final velocity.
	# Velocity is inherited from CharacterBody2D — it tells Godot how far to move.
	velocity = direction * speed

	# Actually move the character, and handle any collisions automatically
	# (e.g. sliding along walls instead of stopping dead).
	move_and_slide()
