# battle.gd
# The brain of the battle system. Tracks HP, decides whose turn it is,
# calculates damage, and drives the state machine that controls the flow
# of the whole fight. Attached to the root Battle node in battle.tscn.
#
# Sub-phase 3.5 integration:
#   - Player stats come from the RPGState autoload (max_hp, hp, attack,
#     character_name, base_power, luck) so HP carries over between battles
#     and the player's chosen name is used in messages.
#   - Enemy stats come from a GameManager.pending_battle_enemy EnemyStats
#     Resource if one is set (this is how the combat sandbox specifies
#     which enemy to fight). Falls back to @export defaults otherwise.
#   - Damage formula: (2 × (A + Power) / D + 2) × Critical × Random,
#     clamped to a minimum of 1. Crit chance is luck × 1% (cap 50%).
#   - End-of-battle states (WIN / LOSE / ESCAPE) wait for the player to
#     press the interact key, then return to whichever location triggered
#     the battle (the sandbox if launched from there, otherwise the
#     rpg_battle_return_location).
#   - On defeat we restore HP to max as a placeholder. A proper game-over
#     / save-checkpoint flow lands later when SaveSystem is real.

extends Node2D

# --- State Machine ---
# An "enum" is just a named list of options. We use BattleState to keep track
# of what phase the battle is currently in, so the game always knows what
# should be happening at any given moment.
enum BattleState {
	INTRO,         # The opening message ("A GOBLIN appeared!")
	PLAYER_MENU,   # Waiting for the player to pick an action
	PLAYER_ATTACK, # The player's attack is being resolved
	ENEMY_TURN,    # The enemy is taking their turn
	SUB_MENU,      # Player opened Cast or Item (currently empty stubs)
	WIN,           # The enemy has been defeated; waiting for player to confirm
	LOSE,          # The player has been defeated; waiting for player to confirm
	ESCAPE,        # The player ran away; waiting for confirm before returning
}

# --- Tunable Combat Values ---
# These are the @export fallback enemy stats used when no EnemyStats
# Resource has been supplied via GameManager.pending_battle_enemy. The
# random-encounter overworld doesn't pick a specific enemy yet (that
# lands when enemy variety mods come online), so it defaults to these.
@export var enemy_name: String = "GOBLIN"
@export var enemy_max_hp: int = 8
@export var enemy_attack: int = 4
@export var enemy_defense: int = 2
@export var enemy_luck: int = 2
@export var enemy_base_power: int = 0

# --- Damage formula constants ---
# Tunable knobs for the (2 × (A + Power) / D + 2) × Crit × Random formula.
# Kept inline for readability; can extract to a CombatBalance Resource
# later if iteration speed makes Inspector access valuable.
const STAT_COEFFICIENT: float = 2.0       # The "× 2" in the numerator
const BASE_DAMAGE: float = 2.0            # The "+ 2" floor inside the parens
const CRIT_MULTIPLIER: float = 1.5        # Multiplied onto raw damage on crit
const RANDOM_LOW: float = 0.85            # Lower bound of variance roll
const RANDOM_HIGH: float = 1.0            # Upper bound of variance roll
const LUCK_TO_CRIT_PERCENT: float = 1.0   # Crit chance = luck × this
const MAX_CRIT_CHANCE: float = 0.5        # Hard cap on crit chance (50%)

# --- Runtime Variables ---
# The player's HP lives on RPGState directly — we read and write it
# there so the value persists across battles and the rest of the RPG
# (HUDs, save files, etc.) can read it without needing to know about
# this scene.
# Enemy stats are copied from EnemyStats (or the @export fallbacks) into
# these locals at _ready so the rest of the script doesn't have to keep
# checking which source was used.
var _enemy_name: String
var _enemy_max_hp: int
var _enemy_attack: int
var _enemy_defense: int
var _enemy_luck: int
var _enemy_base_power: int
var enemy_hp: int

var current_state: BattleState  # Tracks which phase we're currently in

# "@onready" means this gets assigned as soon as the scene is ready to use.
# The "$BattleUI" is shorthand for "find the child node named BattleUI".
@onready var battle_ui: CanvasLayer = $BattleUI


# _ready is called once automatically when the scene first loads.
# We use it to set everything up before the battle begins.
func _ready() -> void:
	_seed_enemy_stats_from_source()
	enemy_hp = _enemy_max_hp

	# Push player + enemy max HP / current HP to the UI. The bars in the
	# .tscn have placeholder max values (10/8) — these calls overwrite
	# them with the real stats so the fill ratio is correct from frame 1.
	battle_ui.set_player_name(RPGState.character_name)
	battle_ui.set_enemy_name(_enemy_name)
	battle_ui.set_player_max_hp(RPGState.max_hp)
	battle_ui.set_enemy_max_hp(_enemy_max_hp)
	battle_ui.update_player_hp(RPGState.hp)
	battle_ui.update_enemy_hp(enemy_hp)

	# "Connect" means: whenever the UI tells us the player picked an action,
	# automatically call our _on_action_selected function with that choice.
	# This keeps the UI and the game logic separate — the UI doesn't need to
	# know anything about damage calculations, and vice versa.
	battle_ui.action_selected.connect(_on_action_selected)

	# Kick off the battle with the intro sequence
	_change_state(BattleState.INTRO)


# Pulls enemy stats from the GameManager's pending EnemyStats Resource if
# one was set (e.g. by the combat sandbox), or falls back to the @export
# values on this node. Either way, the rest of the script reads from the
# private _enemy_* fields so it doesn't matter where the data came from.
# After consuming, clears pending_battle_enemy so a stale Resource doesn't
# leak into the next battle.
func _seed_enemy_stats_from_source() -> void:
	var pending: EnemyStats = GameManager.pending_battle_enemy as EnemyStats
	if pending != null:
		_enemy_name = pending.enemy_name
		_enemy_max_hp = pending.max_hp
		_enemy_attack = pending.attack
		_enemy_defense = pending.defense
		_enemy_luck = pending.luck
		_enemy_base_power = pending.base_power
		# Consumed — clear so the next encounter doesn't accidentally
		# reuse this enemy.
		GameManager.pending_battle_enemy = null
	else:
		_enemy_name = enemy_name
		_enemy_max_hp = enemy_max_hp
		_enemy_attack = enemy_attack
		_enemy_defense = enemy_defense
		_enemy_luck = enemy_luck
		_enemy_base_power = enemy_base_power


# Watches for the "press interact to dismiss" prompt at the end of the
# battle. We do this here rather than in battle_ui because the UI is
# generic — it doesn't know which messages are the final ones. The state
# machine knows.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_accept"):
		return
	match current_state:
		BattleState.WIN:
			get_viewport().set_input_as_handled()
			_finish_battle_and_return()
		BattleState.LOSE:
			get_viewport().set_input_as_handled()
			# Restore the player's HP to full as a placeholder game-over.
			# When SaveSystem is real this will load the last save instead.
			RPGState.hp = RPGState.max_hp
			RPGState.stats_changed.emit()
			_finish_battle_and_return()
		BattleState.ESCAPE:
			get_viewport().set_input_as_handled()
			_finish_battle_and_return()


# Central function for moving between battle phases.
# Every time something changes (player acts, enemy acts, battle ends),
# we call this with the next state to transition into.
func _change_state(new_state: BattleState) -> void:
	current_state = new_state
	# "match" is like a switch statement — run a different block of code
	# depending on which state we're switching to.
	match new_state:
		BattleState.INTRO:
			_run_intro()
		BattleState.PLAYER_MENU:
			_run_player_menu()
		BattleState.PLAYER_ATTACK:
			_run_player_attack()
		BattleState.ENEMY_TURN:
			_run_enemy_turn()
		BattleState.SUB_MENU:
			_run_sub_menu()
		BattleState.WIN:
			_run_win()
		BattleState.LOSE:
			_run_lose()
		BattleState.ESCAPE:
			_run_escape_outcome()


# Shows the opening message, waits a moment, then moves to the player's turn.
func _run_intro() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("A %s appeared!" % _enemy_name)
	# Pause for 1.5 seconds so the player has time to read the message.
	# "await" means: stop here and wait for the timer to finish before
	# continuing to the next line.
	await get_tree().create_timer(1.5).timeout
	_change_state(BattleState.PLAYER_MENU)


# Shows the action menu and prompts the player to choose what to do.
func _run_player_menu() -> void:
	battle_ui.set_message("What will you do?")
	battle_ui.show_menu()


# Called by the UI whenever the player confirms a menu choice.
# "action" will be a string like "attack", "cast", "item", or "run".
func _on_action_selected(action: String) -> void:
	match action:
		"attack":
			_change_state(BattleState.PLAYER_ATTACK)
		"cast", "item":
			# Both lead to the sub-menu state (currently just shows "Nothing here...")
			_change_state(BattleState.SUB_MENU)
		"run":
			# Run currently always succeeds. When the Run mod system lands
			# this will gate on ModManager.is_active("run") and possibly
			# fall back to "Can't escape!" without it.
			_change_state(BattleState.ESCAPE)
		"back":
			# Player pressed back from a sub-menu, return to the action menu
			_change_state(BattleState.PLAYER_MENU)


# Resolves the player's basic attack against the enemy.
func _run_player_attack() -> void:
	battle_ui.hide_menu()

	var roll: Dictionary = _calculate_damage(
		RPGState.attack, RPGState.base_power, RPGState.luck, _enemy_defense)
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	# Subtract damage from enemy HP, but don't let it go below 0.
	enemy_hp = maxi(enemy_hp - damage, 0)
	battle_ui.update_enemy_hp(enemy_hp)

	# Show "Critical hit! +damage!" on crit, otherwise the normal line.
	# This is just text — the actual mechanical effect is already baked
	# into the damage value.
	var msg: String = "%s attacks! %d damage!" % [RPGState.character_name, damage]
	if is_crit:
		msg = "Critical hit! " + msg
	battle_ui.set_message(msg)

	await get_tree().create_timer(1.5).timeout

	if enemy_hp <= 0:
		_change_state(BattleState.WIN)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Resolves the enemy's attack against the player.
func _run_enemy_turn() -> void:
	var roll: Dictionary = _calculate_damage(
		_enemy_attack, _enemy_base_power, _enemy_luck, RPGState.defense)
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	# Write damage straight into RPGState so the player's HP carries over
	# to the next battle. stats_changed.emit() lets any HUD listeners
	# (overworld pause menu, future status panels) refresh without polling.
	RPGState.hp = maxi(RPGState.hp - damage, 0)
	RPGState.stats_changed.emit()
	battle_ui.update_player_hp(RPGState.hp)

	var msg: String = "%s attacks! %d damage!" % [_enemy_name, damage]
	if is_crit:
		msg = "Critical hit! " + msg
	battle_ui.set_message(msg)
	await get_tree().create_timer(1.5).timeout

	if RPGState.hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.PLAYER_MENU)


# The damage formula. Keeps all the math in one place so when we tune the
# combat feel we only edit here — and so unit-testable later.
#
# Returns a Dictionary { "damage": int, "crit": bool } so callers can
# show "Critical hit!" text without needing to re-roll.
#
# Formula: (2 × (A + Power) / D + 2) × Critical × Random, min 1
#   - A           = attacker's primary stat (attack for physical, intelligence for magic)
#   - Power       = attacker's base_power (or weapon/spell Power once equipped)
#   - D           = defender's defense (clamped at 1 to avoid divide-by-zero)
#   - Critical    = CRIT_MULTIPLIER on crit, 1.0 otherwise
#   - Random      = uniform RANDOM_LOW..RANDOM_HIGH
#   - Crit chance = attacker.luck × LUCK_TO_CRIT_PERCENT, capped at MAX_CRIT_CHANCE
func _calculate_damage(
		attacker_stat: int,
		attacker_power: int,
		attacker_luck: int,
		defender_defense: int) -> Dictionary:
	var effective_attack: int = attacker_stat + attacker_power
	var safe_defense: int = maxi(defender_defense, 1)

	# Roll a crit. luck × 1% chance, capped so high-luck builds don't crit
	# every swing. (Crit-rate-altering mods will go through these constants.)
	var crit_chance: float = clampf(
		float(attacker_luck) * LUCK_TO_CRIT_PERCENT / 100.0,
		0.0,
		MAX_CRIT_CHANCE)
	var is_crit: bool = randf() < crit_chance
	var crit_mult: float = CRIT_MULTIPLIER if is_crit else 1.0

	# The variance roll. 0.85..1.0 means damage skews slightly low — most
	# hits are 90-95% of theoretical max, occasional rolls are higher.
	var random_mult: float = randf_range(RANDOM_LOW, RANDOM_HIGH)

	var raw: float = (
		(STAT_COEFFICIENT * float(effective_attack) / float(safe_defense) + BASE_DAMAGE)
		* crit_mult
		* random_mult)

	var damage: int = maxi(1, int(raw))
	return {"damage": damage, "crit": is_crit}


# Handles the Cast and Item sub-menus.
# These are stubs for now — they show a message and wait for input to go back.
func _run_sub_menu() -> void:
	battle_ui.enter_sub_menu()
	battle_ui.set_message("Nothing here...")


# Battle is over — player wins. Shows the defeat message and waits for
# the player to press interact (handled in _unhandled_input).
func _run_win() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("%s was defeated!" % _enemy_name)


# Battle is over — player loses. Shows the death message and waits for
# the player to press interact. _unhandled_input handles HP restoration
# and the return-to-overworld transition.
func _run_lose() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("%s has died." % RPGState.character_name)


# Player chose Run and got away. Shows the escape message and waits for
# the player to press interact before returning.
func _run_escape_outcome() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("Got away safely!")


# Sends the player back to wherever the battle was triggered from.
#   - From the combat sandbox  → back to the sandbox (the sandbox set
#     GameManager.battle_returns_to_sandbox before launching).
#   - From the overworld/dungeon → back to rpg_battle_return_location
#     (currently always OVERWORLD; dungeons will set DUNGEON later).
# Either flag/field gets cleared after consumption so a stale value
# doesn't leak into the next battle.
func _finish_battle_and_return() -> void:
	if GameManager.battle_returns_to_sandbox:
		GameManager.battle_returns_to_sandbox = false
		GameManager.switch_to_world(GameManager.World.COMBAT_SANDBOX)
	else:
		GameManager.switch_rpg_location(GameManager.rpg_battle_return_location)
