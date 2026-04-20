# aesthetic.gd
# Autoload singleton that owns the currently-active visual tier of the RPG.
# Think of this as a little switch box: it holds a reference to one
# AestheticTier Resource (Gameboy / NES / SNES), and emits a signal every
# time that reference changes. Any scene that cares — primarily the RPG
# overworld's post-processing shader overlay — listens to `tier_changed`
# and reapplies its look from the new tier's palette/shader params.
#
# Access from anywhere as `Aesthetic` (registered in project.godot).
#
# Why a separate autoload (not part of GameManager)?
#   Tiers are purely a presentation concern. Mods in Phase 4 may swap the
#   tier based on progression, but nothing about world state (Real World vs
#   RPG, progression flags) is relevant to how a shader samples colors.
#   Keeping Aesthetic standalone means both systems stay focused.
#
# Why preload the .tres files?
#   Only three tiers exist and they're tiny data resources. Preloading means
#   tier switches are instantaneous — no disk IO during gameplay.

extends Node

# Tier identifiers. The enum is for external callers (e.g. a mod activating
# the SNES tier would call Aesthetic.set_tier(Aesthetic.Tier.SNES)).
# The backing data for each tier lives in the _TIER_RESOURCES dictionary.
enum Tier { GAMEBOY, NES, SNES }

# Map of tier ID -> its AestheticTier Resource.
# Preloaded so switching tiers is just a dictionary lookup, no file load.
const _TIER_RESOURCES: Dictionary = {
	Tier.GAMEBOY: preload("res://resources/tiers/gameboy.tres"),
	Tier.NES:     preload("res://resources/tiers/nes.tres"),
	Tier.SNES:    preload("res://resources/tiers/snes.tres"),
}

# Fires whenever the active tier changes. Listeners receive the new Tier
# enum value; they then call `get_palette()` to pull fresh data.
# We pass the enum (not the Resource) so listeners can also do tier-specific
# behavior based on identity without having to compare resource references.
signal tier_changed(new_tier: Tier)

# Which tier is currently active. Gameboy per Phase 2 design (the RPG
# begins in its most primitive state and evolves as mods are found).
var current_tier: Tier = Tier.GAMEBOY


# Returns the AestheticTier Resource for whichever tier is currently active.
# Callers use this to read the palette, shader params, etc.
# Returns `null` only if something is badly misconfigured (unknown tier).
func get_palette() -> AestheticTier:
	return _TIER_RESOURCES.get(current_tier, null)


# Returns the Resource for a specific tier (useful for previews or mods
# that want to read a tier's data without switching to it).
func get_palette_for(tier: Tier) -> AestheticTier:
	return _TIER_RESOURCES.get(tier, null)


# Switch to a new tier. No-op if already on that tier, to avoid listeners
# redundantly rebuilding shaders on every frame if something sets the tier
# in a loop.
func set_tier(tier: Tier) -> void:
	if tier == current_tier:
		return
	if not _TIER_RESOURCES.has(tier):
		push_warning("Aesthetic.set_tier: unknown tier %s" % tier)
		return
	current_tier = tier
	tier_changed.emit(tier)


# Convenience helper used by the debug F1/F2/F3 keys in main.gd:
# cycle forward through the tiers in enum order (Gameboy -> NES -> SNES -> Gameboy).
# Not used by gameplay code; mods and game events always call set_tier() directly.
func cycle_tier() -> void:
	var next_value: int = (int(current_tier) + 1) % Tier.size()
	set_tier(next_value as Tier)
