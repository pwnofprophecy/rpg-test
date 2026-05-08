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
# References to the on-screen sprites for spawning floating damage numbers
# above whoever just took a hit. Both placed by the .tscn — see scene tree.
@onready var player_sprite: Node2D = $PlayerSprite
@onready var enemy_sprite: Node2D = $EnemySprite

# How far above each sprite's origin the floating damage number spawns.
# Negative Y because Godot's screen Y grows downward. Tweak per sprite if
# the .tscn sprites change size — currently both sprites share the same
# 4× scale so a single offset works for both.
const POPUP_OFFSET: Vector2 = Vector2(0, -100)

# --- Lunge animation tuning ---
# How many pixels the attacker moves toward the target at the peak of
# the lunge.
const LUNGE_DISTANCE: float = 50.0
# Forward / return durations. Forward is snappier (fast wind-up) and
# return is slightly longer (relaxed settle back to position).
const LUNGE_FORWARD_DURATION: float = 0.15
const LUNGE_RETURN_DURATION: float = 0.20

# --- Hit effect tuning (flash + shake on the defender) ---
# Color tint applied during the flash. Saturated red over white texture
# reads as "ouch" without needing a shader. Brief duration so it doesn't
# linger.
const FLASH_COLOR: Color = Color(1.6, 0.4, 0.4, 1.0)
const FLASH_IN_DURATION: float = 0.05
const FLASH_OUT_DURATION: float = 0.18
# Horizontal shake — three quick steps (right, left, settle).
const SHAKE_OFFSET: float = 8.0
const SHAKE_STEP_DURATION: float = 0.05

# --- Camera shake (whole-battle) tuning ---
# Camera shake jiggles the Battle root Node2D, which moves all sprites
# and popups together but NOT the BattleUI CanvasLayer (canvas layers
# have their own transform). This gives a "world reacts to impact"
# feel without messing with the HP bars or text.
const CAM_SHAKE_INTENSITY_NORMAL: float = 4.0
const CAM_SHAKE_INTENSITY_CRIT: float = 8.0
const CAM_SHAKE_DURATION: float = 0.18
const CAM_SHAKE_STEPS: int = 6  # number of random offsets before settling

# --- Screen flash tuning (crit only) ---
# A full-screen tinted overlay that fades from full to zero alpha. The
# color's own alpha is the peak intensity; the tween reduces modulate.a
# to fade out.
const SCREEN_FLASH_COLOR: Color = Color(1.0, 0.95, 0.7, 0.55)  # warm gold
const SCREEN_FLASH_DURATION: float = 0.30

# --- Hit-pause (hitstop) tuning ---
# Briefly sets Engine.time_scale to 0 so every running tween freezes at
# the moment of impact. Crits get a longer pause to emphasize them.
# Real-time durations (ignore_time_scale=true on the timer), so the
# pause itself isn't affected by its own time scale change.
const HIT_PAUSE_NORMAL: float = 0.04
const HIT_PAUSE_CRIT: float = 0.10


# _ready is called once automatically when the scene first loads.
# We use it to set everything up before the battle begins.
func _ready() -> void:
	_seed_enemy_stats_from_source()
	enemy_hp = _enemy_max_hp

	# Background ColorRect defaults to mouse_filter = STOP — meaning any
	# click in its full-screen area gets consumed before _unhandled_input
	# can fire. That breaks the "click anywhere to dismiss" flow for
	# end-of-battle text. ColorRect is purely decorative here, so make
	# it click-transparent.
	$Background.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Push player + enemy max HP / current HP to the UI. The bars in the
	# .tscn have placeholder max values (10/8) — these calls overwrite
	# them with the real stats so the fill ratio is correct from frame 1.
	battle_ui.set_player_name(RPGState.character_name)
	battle_ui.set_enemy_name(_enemy_name)
	# Use effective max HP so a Hero with armor equipped shows the
	# correct expanded HP bar (e.g. base 30 + leather armor 10 = 40).
	battle_ui.set_player_max_hp(RPGState.get_effective_max_hp())
	battle_ui.set_enemy_max_hp(_enemy_max_hp)
	# `false` = no drain animation on first display; just snap to the
	# correct value. Otherwise both bars would visibly tween from the
	# .tscn placeholder values up to the real values at battle start.
	battle_ui.update_player_hp(RPGState.hp, false)
	battle_ui.update_enemy_hp(enemy_hp, false)

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
#
# Both Enter (ui_accept) and a left-click anywhere on the screen
# dismiss the end-of-battle text. The mouse path matches what we did
# for the action menu and sub-menu so the whole battle is keyboard-OR-
# mouse playable.
func _unhandled_input(event: InputEvent) -> void:
	# GDScript 4 doesn't narrow `event` to InputEventMouseButton inside
	# the same expression as the `is` check — `event.pressed` would
	# still resolve to Variant, which makes := fail to infer. So we
	# split the check into a separate cast.
	var dismiss: bool = event.is_action_pressed("ui_accept")
	if not dismiss and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		dismiss = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	if not dismiss:
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

	# Effective stats include equipment bonuses (weapon power, +attack
	# from armor, etc.). Defender side is the raw enemy defense — enemies
	# don't have equipment in Phase 3.5.
	var roll: Dictionary = _calculate_damage(
		RPGState.get_effective_attack(),
		RPGState.get_effective_base_power(),
		RPGState.get_effective_luck(),
		_enemy_defense)
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	enemy_hp = maxi(enemy_hp - damage, 0)

	# Lunge forward at the enemy. We await the forward motion so the hit
	# effects land at the apex (where the player's "weapon" would meet the
	# enemy), then start the return motion in parallel with the rest.
	await _lunge_at(player_sprite, enemy_sprite.global_position)

	# Hit lands: flash + shake the enemy, float the damage number, drain
	# their HP bar, shake the camera, flash the screen on crit. All
	# parallel; the actual hp is already updated above.
	_hit_effect(enemy_sprite)
	DamagePopup.spawn(self, enemy_sprite.global_position + POPUP_OFFSET, damage, is_crit)
	battle_ui.update_enemy_hp(enemy_hp)
	_camera_shake(
		CAM_SHAKE_INTENSITY_CRIT if is_crit else CAM_SHAKE_INTENSITY_NORMAL,
		CAM_SHAKE_DURATION)
	if is_crit:
		_screen_flash(SCREEN_FLASH_COLOR, SCREEN_FLASH_DURATION)

	# Hitstop: freeze every running tween for a beat so the eye registers
	# the impact. Crits get a longer freeze than normal hits.
	await _hit_pause(HIT_PAUSE_CRIT if is_crit else HIT_PAUSE_NORMAL)

	# Return motion runs concurrently with the text-display pause below.
	_lunge_back(player_sprite)

	var msg: String = "%s attacks!" % RPGState.character_name
	if is_crit:
		msg += " Critical hit!"
	battle_ui.set_message(msg)

	await get_tree().create_timer(1.0).timeout

	if enemy_hp <= 0:
		_change_state(BattleState.WIN)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Resolves the enemy's attack against the player.
func _run_enemy_turn() -> void:
	# Defender is the player here, so use their effective defense (base
	# + armor + accessory bonuses).
	var roll: Dictionary = _calculate_damage(
		_enemy_attack, _enemy_base_power, _enemy_luck,
		RPGState.get_effective_defense())
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	# Write damage straight into RPGState so the player's HP carries over
	# to the next battle. stats_changed.emit() lets any HUD listeners
	# (overworld pause menu, future status panels) refresh without polling.
	RPGState.hp = maxi(RPGState.hp - damage, 0)
	RPGState.stats_changed.emit()

	# Enemy lunges at the player, hit effects land, then enemy retreats.
	await _lunge_at(enemy_sprite, player_sprite.global_position)
	_hit_effect(player_sprite)
	DamagePopup.spawn(self, player_sprite.global_position + POPUP_OFFSET, damage, is_crit)
	battle_ui.update_player_hp(RPGState.hp)
	_camera_shake(
		CAM_SHAKE_INTENSITY_CRIT if is_crit else CAM_SHAKE_INTENSITY_NORMAL,
		CAM_SHAKE_DURATION)
	if is_crit:
		_screen_flash(SCREEN_FLASH_COLOR, SCREEN_FLASH_DURATION)

	await _hit_pause(HIT_PAUSE_CRIT if is_crit else HIT_PAUSE_NORMAL)

	_lunge_back(enemy_sprite)

	var msg: String = "%s attacks!" % _enemy_name
	if is_crit:
		msg += " Critical hit!"
	battle_ui.set_message(msg)
	await get_tree().create_timer(1.0).timeout

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


# --- Visual effect helpers ---
# All three of these (lunge, flash, shake) tween a sprite's transform or
# modulate temporarily. They use `set_meta("origin", ...)` on first call
# to remember the sprite's original position so subsequent calls always
# return to the same baseline — important because the player and enemy
# sprites get hit on alternating turns.

# Moves the attacker partway toward `target_pos`, then awaits the tween.
# Caller follows up with hit effects on the defender, then calls
# _lunge_back() to start the return motion. The return is intentionally
# NOT awaited so the rest of the turn (text, HP drain) can run in
# parallel with the attacker settling back.
func _lunge_at(attacker: Node2D, target_pos: Vector2) -> void:
	if not attacker.has_meta("origin"):
		attacker.set_meta("origin", attacker.position)
	var origin: Vector2 = attacker.get_meta("origin")

	# Direction vector points from the attacker's current world position
	# toward the target. We only travel LUNGE_DISTANCE pixels — not all
	# the way — so the sprites visually "almost touch" rather than
	# overlap.
	var direction: Vector2 = (target_pos - attacker.global_position).normalized()
	var lunge_pos: Vector2 = origin + direction * LUNGE_DISTANCE

	var tween := create_tween()
	tween.tween_property(attacker, "position", lunge_pos, LUNGE_FORWARD_DURATION) \
		.set_trans(Tween.TRANS_CUBIC) \
		.set_ease(Tween.EASE_OUT)
	await tween.finished


# Sends the attacker back to its origin. Fire-and-forget — caller doesn't
# await; the return runs in the background while the rest of the turn
# state machine continues.
func _lunge_back(attacker: Node2D) -> void:
	if not attacker.has_meta("origin"):
		return
	var origin: Vector2 = attacker.get_meta("origin")
	var tween := create_tween()
	tween.tween_property(attacker, "position", origin, LUNGE_RETURN_DURATION) \
		.set_trans(Tween.TRANS_CUBIC) \
		.set_ease(Tween.EASE_IN)


# Plays the "got hit" visual on a defender: a brief red tint flash plus
# a quick horizontal shake. Both run in parallel so the effect feels
# like a single event rather than a sequence. Fire-and-forget — caller
# doesn't await.
func _hit_effect(target: Node2D) -> void:
	if not target.has_meta("origin"):
		target.set_meta("origin", target.position)
	var origin: Vector2 = target.get_meta("origin")

	# Two independent tweens so the flash (modulate) and the shake
	# (position) can run truly in parallel without conflicting steps.

	var flash_tween := create_tween()
	flash_tween.tween_property(target, "modulate", FLASH_COLOR, FLASH_IN_DURATION)
	flash_tween.tween_property(target, "modulate", Color.WHITE, FLASH_OUT_DURATION)

	var shake_tween := create_tween()
	shake_tween.tween_property(target, "position", origin + Vector2(SHAKE_OFFSET, 0), SHAKE_STEP_DURATION)
	shake_tween.tween_property(target, "position", origin - Vector2(SHAKE_OFFSET, 0), SHAKE_STEP_DURATION)
	shake_tween.tween_property(target, "position", origin, SHAKE_STEP_DURATION)


# Shakes the entire battle world (Battle root Node2D) by tweening its
# position through a series of random offsets, then settling back to
# origin. Fire-and-forget. The Battle root is at (0,0) per the .tscn,
# so we always settle there. CanvasLayer children (BattleUI) are
# unaffected — their transform is independent — so the HP bars and
# text don't shake along with the sprites.
func _camera_shake(intensity: float, duration: float) -> void:
	# Save the origin via metadata in case future scene work moves the
	# Battle root off (0,0). Same pattern as _lunge_at uses.
	if not has_meta("origin"):
		set_meta("origin", position)
	var origin: Vector2 = get_meta("origin")

	var step_duration: float = duration / float(CAM_SHAKE_STEPS + 1)
	var tween := create_tween()
	for i in CAM_SHAKE_STEPS:
		var offset := Vector2(
			randf_range(-intensity, intensity),
			randf_range(-intensity, intensity))
		tween.tween_property(self, "position", origin + offset, step_duration)
	# Final step settles back to origin so the sprites don't drift.
	tween.tween_property(self, "position", origin, step_duration)


# Spawns a full-screen colored overlay that fades from its initial
# alpha (baked into `color`) to zero over `duration`. Lives on a
# dedicated CanvasLayer with a high layer number so it draws on top of
# the BattleUI HP bars / text. Self-cleaning — the layer + rect free
# themselves when the fade completes. Fire-and-forget.
func _screen_flash(color: Color, duration: float) -> void:
	var layer := CanvasLayer.new()
	# Layer 100 is above BattleUI (default 1) and above any tier overlay
	# we'd add later (5). Anything below this layer renders before the
	# flash, so the flash tints everything visible.
	layer.layer = 100
	add_child(layer)

	var rect := ColorRect.new()
	rect.color = color
	# Anchor to fill the screen.
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	# Don't intercept clicks (irrelevant for this game but good hygiene).
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)

	var tween := create_tween()
	tween.tween_property(rect, "modulate:a", 0.0, duration)
	await tween.finished
	layer.queue_free()


# Briefly sets Engine.time_scale to 0 so all running tweens freeze in
# place. The freeze is awaited via a real-time timer (ignore_time_scale
# = true on the SceneTreeTimer) so it actually unfreezes. After the
# pause, time_scale returns to 1.0 and tweens resume from where they
# stopped.
#
# This is "hitstop": a tiny moment of suspended time at the impact
# instant that makes hits feel weighty in action games. The eye reads
# it as "the world is reacting to the blow." Crits use a longer pause
# than normal hits.
func _hit_pause(duration: float) -> void:
	Engine.time_scale = 0.0
	# Args to create_timer: (time_sec, process_always, physics, ignore_time_scale).
	# We need ignore_time_scale=true so the timer counts real seconds;
	# otherwise it would also be frozen by our own time_scale=0 and
	# never elapse.
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


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
