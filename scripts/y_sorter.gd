# y_sorter.gd
# Attach to any Node2D (or descendant: StaticBody2D, CharacterBody2D, etc.)
# that needs to draw in Y-position order against other y_sorter nodes.
#
# Why we need this instead of Godot's built-in `y_sort_enabled`:
#   Built-in y_sort only sorts a node's immediate children — it does NOT
#   promote grandchildren into an outer parent's sort context, even with
#   `y_sort_enabled` toggled on intermediate nodes. So the moment you put
#   sortable things inside a grouper Node2D (e.g. Obstacles), they all
#   collapse to the grouper's single Y position and the sort breaks.
#
# What this does instead:
#   z_index = int(global_position.y) — every frame, the node's z_index is
#   set to its world Y. CanvasItems with higher z_index draw on top of
#   lower ones, so a node lower on screen (higher Y) draws in front of a
#   node higher on screen (lower Y). This is exactly what y_sort would do,
#   but it works through any depth of nesting because z_index is a global
#   render-order property, not a child-of-parent ordering.
#
# Usage:
#   - Static obstacles (trees, rocks): attach this script. The first frame
#     sets the z_index correctly and they never need to update again, but
#     keeping the per-frame update is cheap and lets you reposition in the
#     editor at runtime if you ever want to.
#   - Moving entities (player, NPCs, enemies): attach the same script.
#     The per-frame update keeps their z_index correct as they move.
#
# Performance note: an int assignment per frame per node is essentially
# free. Don't worry about applying this to every tree on the map.

extends Node2D

func _process(_delta: float) -> void:
	z_index = int(global_position.y)
