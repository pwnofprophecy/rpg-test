# spell.gd
# Resource template for a magic spell. Each spell is a .tres file in
# res://resources/spells/, auto-discovered by the battle Magic menu.
#
# Spells parallel the Item Resource pattern with these differences:
#   - Spells cost MP (mp_cost) rather than consuming an inventory entry.
#   - Damage spells use the standard formula with INTELLIGENCE as the
#     attacker stat instead of attack. spell.power adds onto intelligence
#     the same way a weapon's power_bonus adds onto attack.
#   - Each spell can declare its own popup color so the visual reads
#     by element at a glance (Firebolt orange, future Ice Lance blue, etc.).
#
# Currently implemented effect_kinds:
#   - DAMAGE: standard damage formula, A = intelligence + spell.power
#
# Reserved for future implementation (fields are present so the
# Inspector workflow doesn't change when they go live):
#   - HEAL_HP: power-scaled heal
#   - CURE_STATUS: removes status_name
#
# When extending, add the new EffectKind enum entry, then a match arm
# in battle.gd::_use_spell.

class_name Spell
extends Resource

enum EffectKind {
	DAMAGE,        # Damage formula with intelligence as A, spell.power as Power
	HEAL_HP,       # Reserved — not yet implemented in battle.gd
	CURE_STATUS,   # Reserved — not yet implemented in battle.gd
}

@export var spell_name: String = "SPELL"
@export var description: String = ""
@export var mp_cost: int = 5

@export var effect_kind: EffectKind = EffectKind.DAMAGE
# DAMAGE: weapon-power-style bonus added to intelligence in the
# damage formula. HEAL_HP: how much to heal (placeholder; effect
# not yet wired). Ignored by CURE_STATUS.
@export var power: int = 0
# Used by CURE_STATUS to specify which status the spell removes.
# Empty/unused for DAMAGE / HEAL_HP.
@export var status_name: String = ""

# Color the damage popup uses. Lets each spell read distinctly by
# element — Firebolt orange, hypothetical Ice Lance icy blue, etc.
# Defaulting to white means it'll look like a normal attack; set this
# per-spell in the Inspector for a visual signature.
@export var popup_color: Color = Color.WHITE
