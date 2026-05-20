# enemy_stats.gd
# Resource template defining an enemy's stat block. Each enemy in the game
# (Goblin, Slime, Skeleton, etc.) gets its own .tres file in
# res://resources/enemies/ with these fields filled in via the Inspector.
#
# Usage in code:
#   var goblin: EnemyStats = preload("res://resources/enemies/goblin.tres")
#   battle_node.enemy_stats = goblin
#
# Why a Resource and not @export on the battle scene?
#   - Designers can add new enemies by duplicating an existing .tres and
#     editing values in the Inspector — no code or scene work required.
#   - The combat sandbox can list every .tres in the enemies folder and
#     present them as a dropdown for testing.
#   - Phase 4's "Enemy Variety" mod can swap enemy templates at runtime
#     without touching the battle scene's structure.
#
# Mirrors the HeroStats pattern. If a field is missing from a .tres, the
# default declared here is used.

class_name EnemyStats
extends Resource

# Display name shown in battle messages ("A GOBLIN appeared!", "GOBLIN
# attacks!", etc.). Conventionally uppercase to match classic JRPG feel.
@export var enemy_name: String = "ENEMY"

# --- Core combat stats ---
# Same shape as HeroStats so the damage formula treats both sides
# symmetrically. Defense divides into (attack + base_power) for the
# physical damage formula; intelligence will substitute for attack on
# magical attacks once spells are wired.
@export var max_hp: int = 8
@export var attack: int = 4
@export var defense: int = 2
@export var speed: int = 4
@export var intelligence: int = 2
@export var luck: int = 2
# Base attack power when this enemy uses its natural weapon (claws, fists,
# bite, etc.). Added to attack/intelligence before defense divides into
# the result. Most basic enemies sit at 0; heavier hitters use this to
# punch above their stat line.
@export var base_power: int = 0

# --- Status resistances ---
# Status effect names this enemy is fully immune to. Anything in this
# list cannot be applied to the enemy — sandbox toggles, future spells,
# environmental effects, etc. all check here before adding.
# Examples: ["Poisoned"] for a Skeleton, ["Burned", "Frozen"] for a
# Stone Golem. Strings must match what battle.gd looks for (case-
# sensitive — see _KNOWN_STATUSES in combat_sandbox.gd for the live list).
@export var status_immunities: Array[String] = []

# --- Rewards (stubbed for now; XP/gold systems land in Phase 4 mods) ---
@export var xp_reward: int = 0
@export var gold_reward: int = 0
