# player.gd
# Controls the player character's movement in the overworld.
# This script is attached to the Player node in main.tscn.

extends CharacterBody2D

# How fast the player moves, in pixels per second.
# The "@export" keyword makes this value show up in the Godot editor,
# so you can tweak it without touching the code.
@export var speed: float = 200.0

func _ready() -> void:
	# Add ourselves to the "player" group so Interactable zones can identify
	# us with body.is_in_group("player") instead of checking the class type.
	# This is safer — it won't accidentally trigger on other CharacterBody2D nodes.
	add_to_group("player")
	# Force a redraw so _draw() runs.
	queue_redraw()


# Keep the player's render order in sync with their world Y position so
# they correctly draw behind objects that are south of them and in front
# of objects north of them. See scripts/y_sorter.gd for the rationale.
func _process(_delta: float) -> void:
	z_index = int(global_position.y)


# _draw() is called by Godot when the node needs to render itself.
# We bypass child visual nodes (Polygon2D / ColorRect) entirely and draw
# the player directly here — this is the most reliable way to guarantee
# something shows up on screen.
func _draw() -> void:
	# Body: 28x44 blue rectangle centered on the player's origin.
	var body_rect := Rect2(Vector2(-14, -22), Vector2(28, 44))
	draw_rect(body_rect, Color(0.357, 0.553, 0.851), true)
	# Head: 18x18 skin-toned square sitting on top of the body.
	var head_rect := Rect2(Vector2(-9, -32), Vector2(18, 18))
	draw_rect(head_rect, Color(0.957, 0.769, 0.541), true)


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
