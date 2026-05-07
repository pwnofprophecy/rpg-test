# hero_stats.gd
# Template / starting stats for the Hero in the RPG.
#
# This file defines the SHAPE of a stat block (the class). The actual values
# live in res://resources/hero_stats.tres — you can edit them in the Godot
# Inspector without touching code.
#
# Why split template from runtime state?
#   The .tres holds "what a brand-new Hero looks like." The RPGState autoload
#   copies those values into its own runtime variables on _ready(). During
#   play, battles mutate RPGState (hp drops, xp rises, status effects apply),
#   but the .tres template never changes. That keeps "new game" deterministic
#   and cleanly separates designer data from runtime data.
#
# Why the same pattern as AestheticTier?
#   Consistency. The codebase already uses Resource-backed data for tiers,
#   so using it for hero stats too means one pattern to remember.
#
# Inspector workflow:
#   Double-click res://resources/hero_stats.tres in the FileSystem dock to
#   edit the starting Hero values — name, HP, MP, attack, defense, speed,
#   starting level/xp/gold, and any starting status effects.

class_name HeroStats
extends Resource

# The default name shown on the name-entry screen. If the player confirms
# with an empty field, this is the fallback.
@export var character_name: String = "HERO"

# --- Core combat stats ---
@export var max_hp: int = 30
@export var max_mp: int = 10
@export var attack: int = 8
@export var defense: int = 4
@export var speed: int = 5
# Scales spell power and, together with level, the MP pool. Battles will
# read this when computing magical damage and when rolling spell costs.
@export var intelligence: int = 5
# Affects critical hit chance and loot drop rolls. Battles / loot tables
# will read this when deciding outcomes.
@export var luck: int = 5
# Base attack power when unarmed/uncast. Added to the relevant attack stat
# (attack for physical, intelligence for magic) before defense divides into
# the result. Default 0 — fists do nothing on top of raw stats. Weapons
# and spells will eventually override this with their own Power values.
@export var base_power: int = 0

# --- Progression ---
@export var level: int = 1
@export var xp: int = 0
@export var gold: int = 0

# --- Status effects ---
# Free-form string tags that battles / abilities check and mutate. Empty on
# a fresh Hero, but exposed so a designer could start the Hero with a
# permanent buff for testing without changing code.
@export var status_effects: Array[String] = []
