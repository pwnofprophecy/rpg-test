# equipment.gd
# Resource template for a piece of equipment the Hero can wear. Three
# slot types: Weapon, Armor, Accessory — each slot allows one equipped
# item at a time. Bonuses from all equipped items add together onto
# the Hero's base stats (see RPGState.get_effective_*() for the read
# path used by battles).
#
# Mirrors the EnemyStats pattern: each piece of equipment is a .tres
# file the user can edit in the Inspector. Drop new files into
# res://resources/equipment/ and they'll show up in the combat sandbox
# automatically.
#
# Usage in code:
#   var sword: Equipment = preload("res://resources/equipment/iron_sword.tres")
#   RPGState.equip(sword)            # auto-routes to weapon slot
#   RPGState.unequip(Equipment.Slot.WEAPON)
#
# Future-proofing notes:
#   - Adding a new bonus type (e.g. magic resistance) is one new
#     @export var here, plus a matching field on RPGState.get_effective_*().
#   - Adding a new slot type (e.g. RING, HELMET) is one enum entry plus
#     a slot field on RPGState plus a match arm in equip/unequip.
#   - level_required, gold_cost, etc. can be added later for shops/loot.

class_name Equipment
extends Resource

# Which slot this item occupies. The Hero can have one of each.
enum Slot { WEAPON, ARMOR, ACCESSORY }

# Display name shown in equipment menus and the sandbox dropdowns.
@export var item_name: String = "ITEM"
# Which slot this piece occupies. Determines which RPGState field
# equip() writes to.
@export var slot: Slot = Slot.WEAPON
# Flavor / tooltip text. Not currently displayed but useful when shops
# and equipment menus arrive.
@export var description: String = ""

# --- Stat bonuses (added to base stats while equipped) ---
# Mirrors HeroStats / RPGState fields one-for-one so the bonus lookup
# in RPGState can be field-name-driven rather than a giant switch.
@export var hp_bonus: int = 0
@export var mp_bonus: int = 0
@export var attack_bonus: int = 0
@export var defense_bonus: int = 0
@export var speed_bonus: int = 0
@export var intelligence_bonus: int = 0
@export var luck_bonus: int = 0
# Power bonus is added to the Hero's effective attack stat in the
# damage formula — this is how weapons "punch" beyond the wearer's raw
# attack stat. A wooden sword with power_bonus=4 makes EffectiveAttack
# = attack + 4 against the same defender. Spells later will use a
# similar Power value computed at cast time rather than from a slot.
@export var power_bonus: int = 0

# --- Status immunities granted by this item ---
# Status effect names that the wearer becomes immune to while this
# piece is equipped. RPGState.get_status_immunities() unions these
# across all three slots, so e.g. an Antidote Ring (immune to
# Poisoned) and a Frozen Crown (immune to Frozen) stack to make the
# wearer immune to both. Equipping a piece also clears any existing
# statuses it would now block.
@export var status_immunities: Array[String] = []
