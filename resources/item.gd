# item.gd
# Resource template for a consumable item in the Hero's inventory.
# Each item is a .tres file in res://resources/items/ that the sandbox
# auto-discovers, and that the battle scene can apply via the Item
# action menu.
#
# Items in this first pass:
#   - Have one effect (the effect_kind enum picks which behavior)
#   - Always go through target selection — even beneficial items can
#     be aimed at enemies (future-proofing for mechanics like "cure
#     the enemy's Berserk to weaken them"). The cursor's *default*
#     position is determined by effect_kind: heals default to the
#     player, damage defaults to the first living enemy.
#   - Are consumed on use (inventory quantity decrements by 1)
#
# Future expansions worth keeping in mind when extending:
#   - Multi-target items (ALL_ENEMIES, ALL_ALLIES) — would need a
#     separate target_mode field plus battle-side dispatch
#   - Buffs (raise stat for N turns) — needs status-effect-like ticking
#   - Out-of-battle use (heal in the overworld menu) — same effect
#     dispatch, no battle context

class_name Item
extends Resource

# What the item does when used. Each kind interprets the `amount` and
# `status_name` fields differently — see the comment on each.
enum EffectKind {
	HEAL_HP,        # Restore `amount` HP to target (capped at target's max)
	HEAL_MP,        # Restore `amount` MP to target (capped at max)
	CURE_STATUS,    # Remove `status_name` from target's status list
	DAMAGE_FIXED,   # Deal `amount` damage to target (flat, no formula/crit/random)
}

@export var item_name: String = "ITEM"
@export var description: String = ""
@export var effect_kind: EffectKind = EffectKind.HEAL_HP

# Effect parameters. Only the field relevant to this item's effect_kind
# matters; others stay at default and are ignored.
#   HEAL_HP / HEAL_MP / DAMAGE_FIXED  → amount
#   CURE_STATUS                        → status_name
@export var amount: int = 0
@export var status_name: String = ""
