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
#   - HEAL_HP: power-scaled heal (no crit, no defense)
#   - CURE_STATUS: strips statuses. If status_name is set, removes just
#     that one; if status_name is empty, removes ALL negative statuses
#     (the "Cleanse" behavior — see battle.gd's NEGATIVE_STATUSES list).
#
# When extending, add the new EffectKind enum entry, then a match arm
# in battle.gd::_use_spell.

class_name Spell
extends Resource

enum EffectKind {
	DAMAGE,        # Damage formula with intelligence as A, spell.power as Power
	HEAL_HP,       # Power-scaled heal (no crit, no defense)
	CURE_STATUS,   # Strips status_name (or all negative statuses if empty)
}

# Elemental tag for spells. NONE means "untyped" — the right default for
# HEAL_HP / CURE_STATUS spells (they don't deal damage) and for any
# DAMAGE spell you want to leave neutral. Default keeps existing .tres
# files loading unchanged. No gameplay effect yet — this is plumbing
# for the upcoming damage-type mod (resistances, weaknesses, etc.).
enum MagicDamageType { NONE, FIRE, ICE, LIGHTNING, WATER, HOLY, FORCE }

@export var spell_name: String = "SPELL"
@export var description: String = ""
@export var mp_cost: int = 5

@export var effect_kind: EffectKind = EffectKind.DAMAGE
# Elemental damage type. Set per-spell in the Inspector (e.g. Firebolt
# = FIRE, future ice lance = ICE). Defaults to NONE — appropriate for
# heals/cures and any untyped damage spell. No gameplay effect yet.
@export var damage_type: MagicDamageType = MagicDamageType.NONE
# DAMAGE: weapon-power-style bonus added to intelligence in the
# damage formula. HEAL_HP: how much to heal (placeholder; effect
# not yet wired). Ignored by CURE_STATUS.
@export var power: int = 0
# Used by CURE_STATUS: the single status to remove. Leave EMPTY to make
# the spell a "cleanse" that removes every negative status at once.
# Ignored by DAMAGE / HEAL_HP.
@export var status_name: String = ""

# Color the damage popup uses. Lets each spell read distinctly by
# element — Firebolt orange, hypothetical Ice Lance icy blue, etc.
# Defaulting to white means it'll look like a normal attack; set this
# per-spell in the Inspector for a visual signature.
@export var popup_color: Color = Color.WHITE
