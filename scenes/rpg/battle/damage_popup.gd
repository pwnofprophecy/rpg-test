# damage_popup.gd
# A floating damage number that appears above a character, drifts upward
# while fading out, then deletes itself. Self-contained — no .tscn needed,
# no manual cleanup required.
#
# Use the static `spawn` helper rather than instantiating directly:
#
#   DamagePopup.spawn(self, enemy_sprite.global_position, 5, false)
#
# Critical hits render larger and in gold to differentiate at a glance
# without needing the player to read the text box.
#
# Built with a Tween rather than an AnimationPlayer because the values
# are simple (position + alpha) and we want zero scene-file overhead.
# `await tween.finished` keeps the cleanup clean.

class_name DamagePopup
extends Node2D

# How far the number drifts upward over its lifetime, in pixels.
const RISE_DISTANCE: float = 60.0
# Total animation duration, in seconds. The fade is applied to the second
# half so the number is fully visible while it pops up.
const DURATION: float = 1.0
const FADE_FRACTION: float = 0.5  # Fade starts halfway through the rise.

# Visual differentiation between normal hits and crits.
const NORMAL_COLOR: Color = Color.WHITE
const CRIT_COLOR: Color = Color(1.0, 0.85, 0.2)  # Gold
const NORMAL_FONT_SIZE: int = 36
const CRIT_FONT_SIZE: int = 52

# Black outline + thickness keeps the number readable against any
# background — battle has a green floor and dark sprites.
const OUTLINE_COLOR: Color = Color.BLACK
const OUTLINE_SIZE: int = 6


# Convenience: build a popup, attach it to `parent`, position it at
# `world_pos`, and kick off the animation. Caller doesn't have to track
# the instance — it free's itself when the rise/fade completes.
#
#   parent     — the node that should own this popup (typically the
#                battle scene root). Owning it via the battle root means
#                the popup dies with the scene if the battle ends mid-pop.
#   world_pos  — global position to spawn at. Caller is responsible for
#                offsetting from the target sprite (e.g. sprite.global_position
#                + Vector2(0, -100) to place it above the head).
#   damage     — number to display. Always rendered as an integer.
#   is_crit    — toggles the larger gold styling and a "!" suffix.
static func spawn(parent: Node, world_pos: Vector2, damage: int, is_crit: bool) -> void:
	var popup := DamagePopup.new()
	parent.add_child(popup)
	popup.global_position = world_pos
	# z_index bumped so the popup always renders above the sprite layer
	# regardless of tree-order shenanigans.
	popup.z_index = 100
	popup._init_visuals(damage, is_crit)


# Builds the Label, applies styling, and starts the rise-and-fade tween.
# Called immediately after spawn() positions the popup.
func _init_visuals(damage: int, is_crit: bool) -> void:
	var label := Label.new()
	label.text = ("%d!" % damage) if is_crit else str(damage)

	var color: Color = CRIT_COLOR if is_crit else NORMAL_COLOR
	var font_size: int = CRIT_FONT_SIZE if is_crit else NORMAL_FONT_SIZE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# Reserve a generously wide box so the centered text isn't pinched.
	# Position the box centered on this Node2D's origin so global_position
	# corresponds to where the number visually sits.
	label.size = Vector2(160, 80)
	label.position = Vector2(-80, -40)

	add_child(label)
	_animate(label)


# Runs the rise + fade in parallel via a single Tween, then frees the
# popup. await tween.finished is the cleanest way to schedule cleanup
# after parallel tweens — no Timer, no signal wiring.
func _animate(label: Label) -> void:
	var target_position: Vector2 = position + Vector2(0, -RISE_DISTANCE)
	var fade_duration: float = DURATION * FADE_FRACTION
	var fade_delay: float = DURATION - fade_duration

	var tween := create_tween()
	tween.set_parallel(true)
	# Rise — quadratic ease-out so the number decelerates as it floats up.
	tween.tween_property(self, "position", target_position, DURATION) \
		.set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
	# Fade — only the second half of the duration so the number is fully
	# legible while it's popping up, then fades just before it disappears.
	tween.tween_property(label, "modulate:a", 0.0, fade_duration) \
		.set_delay(fade_delay)

	await tween.finished
	queue_free()
