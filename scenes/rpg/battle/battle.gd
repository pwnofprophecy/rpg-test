# battle.gd
# The brain of the battle system. Tracks HP, decides whose turn it is,
# calculates damage, and drives the state machine that controls the flow
# of the whole fight. Attached to the root Battle node in battle.tscn.
#
# Sub-phase 3.5 integration:
#   - Player stats come from the RPGState autoload (max_hp, hp, attack,
#     character_name, base_power, luck) so HP carries over between battles
#     and the player's chosen name is used in messages.
#   - Enemy roster comes from GameManager.pending_battle_enemies (an
#     Array of EnemyStats Resources) when set. Each entry spawns one
#     enemy on screen, in array order, left to right. Falls back to a
#     single enemy synthesized from the @export defaults otherwise
#     (e.g. random encounters from the overworld).
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
	INTRO,          # The opening message ("A GOBLIN appeared!")
	PLAYER_MENU,    # Waiting for the player to pick an action
	ITEM_SELECT,    # Picking an item from the inventory list
	MAGIC_SELECT,   # Picking a spell from the magic list
	TARGET_SELECT,  # Choosing the target of an attack / item / spell
	PLAYER_ATTACK,  # The player's attack is being resolved
	ENEMY_TURN,     # The enemy(s) are taking their turn(s)
	SUB_MENU,       # Placeholder state (was Cast; Cast is now MAGIC_SELECT)
	WIN,            # All enemies defeated; waiting for player to confirm
	LOSE,           # The player has been defeated; waiting for player to confirm
	ESCAPE,         # The player ran away; waiting for confirm before returning
}


# --- Per-enemy runtime state ---
# One BattleEnemy instance is created per active enemy at battle start.
# Bundles the EnemyStats template, mutable runtime fields (hp, statuses)
# and references to the on-screen widgets representing this enemy
# (sprite + HP bar VBox + status label + target indicator). Storing the
# widget refs on the same object as the data simplifies update calls
# from "look up bar by index" to "enemy.hp_bar.value = X".
class BattleEnemy:
	var stats: EnemyStats
	var name: String           # display name; copied from stats.enemy_name
	var max_hp: int
	var hp: int
	var attack: int
	var defense: int
	var luck: int
	var base_power: int
	var statuses: Array[String] = []
	var immunities: Array[String] = []

	# UI/world refs — populated by battle.gd after spawning
	var sprite: Sprite2D = null
	var spawn_position: Vector2 = Vector2.ZERO  # where the sprite rests; lunge returns to here
	var hp_bar_root: Control = null   # the VBoxContainer holding name + bar + status
	var hp_bar: ProgressBar = null
	var hp_text: Label = null
	var status_label: Label = null
	var target_indicator: Label = null  # the "▼" cursor floated above when targeted
	# Invisible Area2D layered over the sprite for mouse-based target
	# selection. Hover → highlights, click → confirms target. Only
	# meaningful during TARGET_SELECT state; the handlers no-op otherwise.
	var target_area: Area2D = null

	func is_alive() -> bool:
		return hp > 0

# --- Tunable Combat Values ---
# These are the @export fallback enemy stats used when
# GameManager.pending_battle_enemies is empty (random encounters from
# the overworld take this path). The combat sandbox sets pending_battle_enemies
# to one or more EnemyStats Resources before launching a battle, so the
# fallback isn't used in sandbox flows.
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
#
# Enemies live in `_enemies` as BattleEnemy instances (see inner class
# above). The array is built from GameManager.pending_battle_enemies
# on _ready, falling back to a single @export-defined enemy if no
# pending list was set (e.g. random-encounter path from the overworld).
var _enemies: Array = []  # Array[BattleEnemy]

# Target index for the player's current selection in TARGET_SELECT.
# -1 means the player is targeting themselves (only valid for item
# use, never attacks). 0..N-1 means the player is targeting
# _enemies[i]. Auto-corrects to the first living enemy or to -1
# (depending on context) when entering TARGET_SELECT so the cursor
# never sits on a dead enemy or invalid target.
var _target_index: int = 0
const TARGET_INDEX_PLAYER: int = -1

# When set, TARGET_SELECT's confirm path applies this item to the
# chosen target instead of starting a regular attack. battle_ui's
# item_selected signal hands the picked Item here. Cleared after
# the item resolves (or on cancel back to the item menu).
var _pending_item: Item = null

# Same idea for spells — battle_ui's spell_selected hands the picked
# Spell here, target select confirms the target, _use_spell runs the
# effect. Cleared after the spell resolves (or on cancel).
var _pending_spell: Spell = null

# All Spells discovered in res://resources/spells/ at battle start.
# For now every spell in the folder is castable by the player — no
# "learnable spells" gate yet. Scanned once in _ready and cached for
# the duration of the battle.
var _available_spells: Array[Spell] = []

# Tracks whether the player has already taken their per-turn status
# tick (poison damage, etc.) this turn. Prevents double-ticking when
# the player cancels out of a sub-menu (item menu, target select) and
# re-commits to a different action. Reset to false at the start of
# each new player turn.
var _player_ticked_this_turn: bool = false

var current_state: BattleState  # Tracks which phase we're currently in

# "@onready" means this gets assigned as soon as the scene is ready to use.
# The "$BattleUI" is shorthand for "find the child node named BattleUI".
@onready var battle_ui: CanvasLayer = $BattleUI
# Player sprite reference. Each enemy sprite is built programmatically
# at battle start (see _spawn_enemy_sprite) so they don't need an
# @onready slot — they live on the per-enemy BattleEnemy.sprite field.
# The .tscn's EnemySprite stays in the scene as a hidden placeholder
# (we hide it in _ready); _spawn_enemies handles all real enemy sprites.
@onready var player_sprite: Node2D = $PlayerSprite

# Player-side target indicator (▼) and clickable Area2D for mouse
# targeting. Mirror the ones on each BattleEnemy but for the player.
# Created in _ready and shown only during TARGET_SELECT when the
# player is a valid target (i.e. when _pending_item != null).
var _player_target_indicator: Label = null
var _player_target_area: Area2D = null

# How far above each sprite's origin the floating damage number spawns.
# Negative Y because Godot's screen Y grows downward. Tweak per sprite if
# the .tscn sprites change size.
const POPUP_OFFSET: Vector2 = Vector2(0, -90)

# Popup colors for non-attack damage / healing events. Distinct from
# normal white (attack damage) and gold (crit) so the type of effect
# reads at a glance. The poison-tick color is its own constant in the
# status section below.
const HEAL_HP_POPUP_COLOR: Color = Color(0.4, 1.0, 0.4)   # bright green
const HEAL_MP_POPUP_COLOR: Color = Color(0.4, 0.6, 1.0)   # blue
const ITEM_DAMAGE_POPUP_COLOR: Color = Color(1.0, 0.7, 0.3)  # orange (distinct from white attack)
# Fallback popup color for magic damage when the Spell resource
# itself doesn't override (Color.WHITE default in spell.gd).
const MAGIC_DAMAGE_DEFAULT_COLOR: Color = Color(1.0, 0.4, 0.9)  # magenta

# Folder we scan for spell templates at battle _ready. Drop a .tres in
# here and it becomes castable next time a battle starts.
const SPELLS_FOLDER: String = "res://resources/spells/"

# --- Multi-enemy layout ---
# Sprites lay out in a horizontal row centered on ENEMY_ROW_CENTER_X
# at vertical position ENEMY_ROW_Y. ENEMY_ROW_TOTAL_WIDTH is the
# distance from the leftmost to rightmost sprite when 4 enemies are
# present; with fewer enemies they're spaced proportionally tighter.
const ENEMY_ROW_CENTER_X: float = 750.0
const ENEMY_ROW_Y: float = 220.0
const ENEMY_ROW_TOTAL_WIDTH: float = 480.0
# Smaller scale than the original 4× single-enemy sprite so multiple
# enemies fit without overlapping AND there's room above them for the
# HP bar widget.
const ENEMY_SPRITE_SCALE: Vector2 = Vector2(3.0, 3.0)
# Where the player sprite sits — moved down from the original (200, 400)
# so the upper portion of the screen has room for enemies + their bars.
const PLAYER_SPRITE_POSITION: Vector2 = Vector2(200, 470)

# Extra padding (in local sprite-space pixels, before scale) added to
# each side of the mouse-click target area. Gives the player a more
# forgiving click radius — a tiny enemy doesn't require pixel-perfect
# aim. Scaled by the sprite's scale at runtime, so 20 px in local
# space becomes 60 px at the default 3× scale.
const TARGET_AREA_PADDING: float = 20.0

# --- Enemy HP bar layout ---
# Each enemy gets a VBoxContainer with NameLabel + HPBar (with HPText
# overlay) + StatusLabel, anchored above the sprite's spawn position.
# The bar block itself doesn't move during lunges/shakes — it stays
# pinned to the spawn position so it reads as a stable HUD.
const ENEMY_HP_BAR_WIDTH: float = 150.0
const ENEMY_HP_BAR_HEIGHT: int = 16
const ENEMY_HP_BAR_OFFSET_Y: float = -130.0  # bar VBox top-left, relative to sprite center
const ENEMY_HP_BAR_FONT_SIZE: int = 16
const ENEMY_HP_TEXT_FONT_SIZE: int = 12
const ENEMY_STATUS_FONT_SIZE: int = 12
# Gold tint applied to the currently-targeted enemy's sprite during
# TARGET_SELECT so the player can see who they're about to hit.
const TARGET_TINT: Color = Color(1.4, 1.3, 0.5)
# Texture used for programmatically-spawned enemy sprites. Single
# placeholder for now; per-enemy textures could be added to EnemyStats
# later (e.g. enemy_stats.tres → @export var sprite: Texture2D).
const ENEMY_TEXTURE: Texture2D = preload("res://assets/sprites/enemy_placeholder.svg")

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

# --- Death fade tuning ---
# When an enemy hits 0 HP, their sprite and HP bar widget fade from
# full opacity to invisible over this many seconds. Fast enough that
# the next combatant's turn isn't waiting on it, slow enough that the
# player reads the "death" as a moment rather than a snap.
const DEATH_FADE_DURATION: float = 0.8
# How long to wait BEFORE starting the fade. Set to match
# battle_ui.gd's HP_DRAIN_DURATION (0.4s) so the bar finishes draining
# to 0 — letting the player visually register the kill — before the
# sprite starts disappearing. If you tune HP_DRAIN_DURATION over in
# battle_ui.gd, update this number to match.
const DEATH_FADE_DELAY: float = 0.4

# --- Status effect tuning ---
# Status effect names are simple String tags matching what's stored in
# RPGState.status_effects. The first concrete status is POISONED, which
# ticks for a percentage of max HP at the start of each affected
# combatant's turn (after action select for the player; before the
# attack for the enemy).
const STATUS_POISONED: String = "Poisoned"
# Poisoned takes 5% of max HP per tick, floored at 1 so even tiny HP
# pools still feel it. 0.05 means a 30-max-HP Hero loses ~1-2 / turn
# and a 100-HP heavy enemy loses 5.
const POISON_PERCENT_DAMAGE: float = 0.1
# Visual color for poison damage popups — green to read at-a-glance as
# distinct from white normal hits and gold crits.
const POISON_POPUP_COLOR: Color = Color(0.5, 1.0, 0.4)
# How long the camera lingers on a status tick before the rest of the
# turn proceeds. Long enough to read the message and see the popup.
const STATUS_TICK_PAUSE: float = 1.2


# _ready is called once automatically when the scene first loads.
# We use it to set everything up before the battle begins.
func _ready() -> void:
	# Background ColorRect defaults to mouse_filter = STOP — meaning any
	# click in its full-screen area gets consumed before _unhandled_input
	# can fire. That breaks the "click anywhere to dismiss" flow for
	# end-of-battle text. ColorRect is purely decorative here, so make
	# it click-transparent.
	$Background.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Position the player sprite per our layout constants and hide the
	# .tscn placeholder enemy sprite + HP bar — battle.gd builds those
	# programmatically per-enemy below.
	player_sprite.position = PLAYER_SPRITE_POSITION
	$EnemySprite.visible = false
	battle_ui.hide_legacy_enemy_widgets()

	# Player UI setup. Use effective max HP so equipment bonuses show on
	# the bar at battle start. `false` = no drain animation on first
	# display; just snap to the correct value, otherwise the bar would
	# visibly tween from the .tscn placeholder up to the real value.
	battle_ui.set_player_name(RPGState.character_name)
	battle_ui.set_player_max_hp(RPGState.get_effective_max_hp())
	battle_ui.update_player_hp(RPGState.hp, false)
	battle_ui.set_player_statuses(RPGState.status_effects)

	# Refresh the player's status label whenever RPGState mutates
	# statuses externally (e.g. the sandbox toggle while a battle is
	# already in progress, or future cure spells).
	RPGState.stats_changed.connect(func() -> void:
		battle_ui.set_player_statuses(RPGState.status_effects))

	# Build the enemy roster from GameManager's pending list (or the
	# @export defaults as a single-enemy fallback) and spawn each one's
	# sprite + HP bar widget.
	_spawn_enemies()

	# Connect action menu signal. When UI tells us "player picked X",
	# _on_action_selected runs.
	battle_ui.action_selected.connect(_on_action_selected)
	# Item menu signals — picking an item routes through item-targeting;
	# cancel returns to the action menu.
	battle_ui.item_selected.connect(_on_item_selected)
	battle_ui.item_canceled.connect(_on_item_canceled)
	# Magic menu signals mirror the item ones — pick a spell → MP check
	# → target select → cast. Cancel returns to action menu.
	battle_ui.spell_selected.connect(_on_spell_selected)
	battle_ui.magic_canceled.connect(_on_magic_canceled)
	# Cancel button shown during TARGET_SELECT. Same code path as
	# pressing Esc — call _cancel_target so the dispatch logic
	# (back to item menu vs back to action menu) is centralized.
	battle_ui.target_cancel_clicked.connect(_cancel_target)

	# Scan available spells once at battle start. Cached for the
	# duration so the Magic menu can pop instantly when opened.
	_available_spells = _scan_spells_folder()

	# Build the player-side target indicator (▼) and clickable Area2D
	# so the player can be targeted by items the same way enemies are.
	_build_player_target_widgets()

	# Kick off with the intro sequence.
	_change_state(BattleState.INTRO)


# Creates the ▼ indicator above the player sprite and an invisible
# Area2D over the sprite for mouse-based targeting. Both are hidden
# / inert outside TARGET_SELECT — toggled visible by _set_target.
func _build_player_target_widgets() -> void:
	# ▼ floats above the player sprite. Parented to the sprite so it
	# follows lunges and shakes; visibility controlled per-frame in
	# _set_target / _clear_target_indicators.
	_player_target_indicator = Label.new()
	_player_target_indicator.text = "▼"
	_player_target_indicator.add_theme_font_size_override("font_size", 24)
	_player_target_indicator.add_theme_color_override("font_color", TARGET_TINT)
	_player_target_indicator.position = Vector2(-10, -75)
	_player_target_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_target_indicator.visible = false
	player_sprite.add_child(_player_target_indicator)

	# Clickable area covering the player sprite. Same pattern as the
	# enemy Area2Ds — local-space shape scaled by the sprite's transform.
	_player_target_area = Area2D.new()
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	# Player sprite size is similar to the enemy placeholder; use a
	# rough 70×100 local-space box plus the standard padding.
	shape.size = Vector2(70, 100) + Vector2.ONE * TARGET_AREA_PADDING * 2.0
	collision.shape = shape
	_player_target_area.add_child(collision)
	player_sprite.add_child(_player_target_area)
	_player_target_area.mouse_entered.connect(_on_player_hovered)
	_player_target_area.input_event.connect(_on_player_input_event)


# Builds the _enemies list from one of two sources: the sandbox's
# GameManager.pending_battle_enemies list (for picked encounters) or
# the @export defaults (for random encounters). Each entry becomes a
# BattleEnemy with its own sprite + HP bar widget on screen.
func _spawn_enemies() -> void:
	_enemies = []

	# Source array: pending list if non-empty, otherwise a single-element
	# list synthesized from @export defaults. Filters out null entries
	# in the pending list (sandbox slots set to "(None)").
	var sources: Array[EnemyStats] = []
	for pending in GameManager.pending_battle_enemies:
		var s: EnemyStats = pending as EnemyStats
		if s != null:
			sources.append(s)

	if sources.is_empty():
		# Fallback: synthesize an EnemyStats from the @export defaults
		# so the random-encounter path keeps working even before enemy
		# encounter tables are wired.
		var fallback := EnemyStats.new()
		fallback.enemy_name = enemy_name
		fallback.max_hp = enemy_max_hp
		fallback.attack = enemy_attack
		fallback.defense = enemy_defense
		fallback.luck = enemy_luck
		fallback.base_power = enemy_base_power
		fallback.status_immunities = []
		sources.append(fallback)

	# Consume the pending list now so a future battle doesn't accidentally
	# reuse this roster.
	GameManager.pending_battle_enemies = []

	# Build BattleEnemy instances + spawn their on-screen widgets.
	var total: int = sources.size()
	for i in total:
		var src: EnemyStats = sources[i]
		var be := BattleEnemy.new()
		be.stats = src
		be.name = src.enemy_name
		be.max_hp = src.max_hp
		be.hp = src.max_hp
		be.attack = src.attack
		be.defense = src.defense
		be.luck = src.luck
		be.base_power = src.base_power
		be.immunities = src.status_immunities.duplicate()
		# Filter pending statuses through this enemy's immunities so a
		# Skeleton never starts the fight Poisoned even if the sandbox
		# checked the box.
		for status in GameManager.pending_battle_enemy_statuses:
			if not (status in be.immunities):
				be.statuses.append(status)

		_spawn_enemy_sprite(be, i, total)
		_spawn_enemy_hp_bar(be, i, total)
		_enemies.append(be)


# Creates and adds the enemy's sprite to the battle scene root.
# Position computed from the enemy's index/total via _enemy_position_for.
# Stored on the BattleEnemy so attack/lunge/popup logic can reference it.
func _spawn_enemy_sprite(be: BattleEnemy, index: int, total: int) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = ENEMY_TEXTURE
	sprite.scale = ENEMY_SPRITE_SCALE
	sprite.position = _enemy_position_for(index, total)
	add_child(sprite)
	be.sprite = sprite
	be.spawn_position = sprite.position

	# Add an invisible clickable area covering the sprite. The Area2D
	# is a child of the sprite, so it inherits the sprite's scale —
	# the local-space shape size below gets multiplied by sprite.scale
	# automatically. Padding gives extra forgiveness around the edges.
	var area := Area2D.new()
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	var rect: Rect2 = sprite.get_rect()  # local-space, pre-scale
	shape.size = rect.size + Vector2.ONE * TARGET_AREA_PADDING * 2.0
	collision.shape = shape
	area.add_child(collision)
	sprite.add_child(area)
	be.target_area = area

	# Mouse hover → highlight (preview target). Click → confirm target.
	# We bind the BattleEnemy instance so each handler knows which
	# enemy was hit. The handlers themselves check current_state to
	# silently no-op outside TARGET_SELECT.
	area.mouse_entered.connect(_on_enemy_hovered.bind(be))
	area.input_event.connect(_on_enemy_input_event.bind(be))


# Returns the world position the enemy at `index` should sit at, given
# `total` enemies in the row. Centers the row on ENEMY_ROW_CENTER_X
# and spaces enemies evenly across ENEMY_ROW_TOTAL_WIDTH.
func _enemy_position_for(index: int, total: int) -> Vector2:
	if total <= 1:
		return Vector2(ENEMY_ROW_CENTER_X, ENEMY_ROW_Y)
	var spacing: float = ENEMY_ROW_TOTAL_WIDTH / float(total - 1)
	var start_x: float = ENEMY_ROW_CENTER_X - ENEMY_ROW_TOTAL_WIDTH / 2.0
	return Vector2(start_x + spacing * float(index), ENEMY_ROW_Y)


# Builds a VBoxContainer above each enemy with: target indicator (▼),
# name label, HP bar (with current/max text overlay), status label.
# Added to BattleUI so it stays put during camera shake / lunges
# (CanvasLayer doesn't inherit Node2D transforms).
func _spawn_enemy_hp_bar(be: BattleEnemy, index: int, total: int) -> void:
	var sprite_pos := _enemy_position_for(index, total)
	var bar_x := sprite_pos.x - ENEMY_HP_BAR_WIDTH / 2.0
	var bar_y := sprite_pos.y + ENEMY_HP_BAR_OFFSET_Y

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(bar_x, bar_y)
	vbox.size = Vector2(ENEMY_HP_BAR_WIDTH, 0)
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Target indicator (▼). Hidden by default; flipped on/off as the
	# target cursor moves between enemies.
	var target := Label.new()
	target.text = "▼"
	target.add_theme_font_size_override("font_size", 24)
	target.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	target.add_theme_color_override("font_outline_color", Color.BLACK)
	target.add_theme_constant_override("outline_size", 4)
	target.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	target.visible = false
	target.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(target)

	# Name label.
	var name_lbl := Label.new()
	name_lbl.text = be.name
	name_lbl.add_theme_font_size_override("font_size", ENEMY_HP_BAR_FONT_SIZE)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(name_lbl)

	# HP bar.
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(ENEMY_HP_BAR_WIDTH, ENEMY_HP_BAR_HEIGHT)
	bar.max_value = be.max_hp
	bar.value = be.hp
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(bar)

	# HP text overlay on the bar.
	var hp_text := Label.new()
	hp_text.text = "%d / %d" % [be.hp, be.max_hp]
	hp_text.anchor_right = 1.0
	hp_text.anchor_bottom = 1.0
	hp_text.add_theme_font_size_override("font_size", ENEMY_HP_TEXT_FONT_SIZE)
	hp_text.add_theme_color_override("font_color", Color.WHITE)
	hp_text.add_theme_color_override("font_outline_color", Color.BLACK)
	hp_text.add_theme_constant_override("outline_size", 4)
	hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(hp_text)

	# Status label (e.g. "[Poisoned]"). Hidden when no statuses.
	var status := Label.new()
	status.add_theme_font_size_override("font_size", ENEMY_STATUS_FONT_SIZE)
	status.add_theme_color_override("font_color", Color(0.8, 0.7, 1.0))
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.visible = false
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(status)

	# Stash refs on the BattleEnemy and add to the BattleUI canvas layer.
	be.hp_bar_root = vbox
	be.hp_bar = bar
	be.hp_text = hp_text
	be.status_label = status
	be.target_indicator = target
	battle_ui.add_child(vbox)

	# Apply initial color + status text.
	_refresh_enemy_hp_color(be)
	_refresh_enemy_status_label(be)


# Updates the visible status label on an enemy's HP bar widget to
# reflect the current statuses array. Empty list = hidden.
func _refresh_enemy_status_label(be: BattleEnemy) -> void:
	if be.status_label == null:
		return
	if be.statuses.is_empty():
		be.status_label.text = ""
		be.status_label.visible = false
	else:
		be.status_label.text = "[%s]" % ", ".join(be.statuses)
		be.status_label.visible = true


# Updates an enemy's HP bar fill color based on current ratio.
# Mirrors battle_ui._update_bar_color but operates on a per-enemy bar.
func _refresh_enemy_hp_color(be: BattleEnemy) -> void:
	if be.hp_bar == null:
		return
	var ratio: float = float(be.hp_bar.value) / float(maxi(int(be.hp_bar.max_value), 1))
	var color: Color
	if ratio > 0.75:
		color = Color.GREEN
	elif ratio >= 0.30:
		color = Color.YELLOW
	else:
		color = Color.RED
	var style := StyleBoxFlat.new()
	style.bg_color = color
	be.hp_bar.add_theme_stylebox_override("fill", style)


# Animates an enemy's HP bar drain from current to target value, with
# the X / Y text overlay tracking. Mirrors battle_ui._animate_hp_bar
# but driven by the BattleEnemy's owned widgets.
func _animate_enemy_hp(be: BattleEnemy, target_value: int) -> void:
	if be.hp_bar == null:
		return
	var bar_max: int = int(be.hp_bar.max_value)
	var start: int = int(be.hp_bar.value)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(be.hp_bar, "value", target_value, 0.4)
	if be.hp_text != null:
		tween.tween_method(
			func(v: int) -> void:
				be.hp_text.text = "%d / %d" % [v, bar_max],
			start, target_value, 0.4)
	tween.set_parallel(false)
	tween.tween_callback(_refresh_enemy_hp_color.bind(be))


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
	# Target-select navigation has its own keyboard handling — Left/Right
	# to cycle living enemies, Enter to confirm, Backspace/Esc to cancel
	# back to the action menu. Handled BEFORE the dismiss-check so the
	# arrow keys don't accidentally dismiss anything.
	if current_state == BattleState.TARGET_SELECT:
		_handle_target_select_input(event)
		return

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


# Routes input while in TARGET_SELECT. Left/Right cycles through
# valid targets (living enemies, plus the player when an item is
# pending). Enter confirms, Backspace/Esc cancels. The cancel
# destination depends on context — if cancelling item targeting,
# back to the item menu; otherwise back to the action menu.
func _handle_target_select_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left"):
		_move_target(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_move_target(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		# Confirm — route based on whether we're targeting for an
		# attack or for an item.
		_confirm_target()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		# Cancel — destination depends on context.
		_cancel_target()
		get_viewport().set_input_as_handled()


# Confirm-target dispatcher. The status tick fires here (once per
# turn) — this is the real "commit" point where the player can no
# longer back out. Then dispatches to item use, spell cast, or
# regular attack based on which pending action is set.
func _confirm_target() -> void:
	_clear_target_indicators()
	battle_ui.hide_target_cancel_button()
	# Status tick fires AFTER target is confirmed. Bouncing around
	# the menus / picker / target select doesn't trigger poison
	# damage — only committing to an action does.
	await _tick_player_if_needed()
	if RPGState.hp <= 0:
		# Poison killed us. Whatever target was picked doesn't matter.
		_pending_item = null
		_pending_spell = null
		_change_state(BattleState.LOSE)
		return

	if _pending_spell != null:
		var spell: Spell = _pending_spell
		_pending_spell = null
		var target: int = _target_index
		# Same two-click protection as items.
		current_state = BattleState.PLAYER_ATTACK
		await _use_spell(spell, target)
	elif _pending_item != null:
		var item: Item = _pending_item
		_pending_item = null
		var target: int = _target_index
		# Exit TARGET_SELECT immediately so a stray double-click during
		# the item-use animation can't re-fire targeting. We assign
		# current_state directly (rather than _change_state) to avoid
		# running _run_player_attack — _use_item handles its own
		# transitions at the end.
		current_state = BattleState.PLAYER_ATTACK
		await _use_item(item, target)
	else:
		_change_state(BattleState.PLAYER_ATTACK)


# Cancel-target dispatcher. Routes back to whichever sub-menu was
# active before targeting started:
#   - pending item → back to item menu (pick a different item)
#   - pending spell → back to magic menu (pick a different spell)
#   - neither (regular attack) → back to the action menu
# Status tick has NOT fired yet, so cancelling is "free" — no poison
# damage for backing out.
func _cancel_target() -> void:
	# Guard against this firing when we're not actually in target
	# select (e.g. the Cancel button is hidden but a stray signal
	# arrives). Without this, cancelling from non-target states
	# could cause weird state transitions.
	if current_state != BattleState.TARGET_SELECT:
		return
	_clear_target_indicators()
	battle_ui.hide_target_cancel_button()
	if _pending_spell != null:
		_pending_spell = null
		_change_state(BattleState.MAGIC_SELECT)
	elif _pending_item != null:
		_pending_item = null
		_change_state(BattleState.ITEM_SELECT)
	else:
		_change_state(BattleState.PLAYER_MENU)


# Moves the target cursor by `delta` (-1 left, +1 right), wrapping
# around. Valid targets depend on whether we're in attack mode
# (enemies only) or item mode (enemies + the player).
func _move_target(delta: int) -> void:
	var targets: Array[int] = _valid_targets()
	if targets.is_empty():
		return
	# Find current position in the valid list (or pick first if cursor
	# is on a no-longer-valid target).
	var pos: int = targets.find(_target_index)
	if pos == -1:
		pos = 0
	pos = (pos + delta + targets.size()) % targets.size()
	_set_target(targets[pos])


# Returns the list of valid target indices for the current TARGET_SELECT
# context. Living enemies are always valid. The player is valid IFF
# an item OR a spell is pending — regular attacks can't target the self.
func _valid_targets() -> Array[int]:
	var targets: Array[int] = []
	for i in _enemies.size():
		if (_enemies[i] as BattleEnemy).is_alive():
			targets.append(i)
	if _pending_item != null or _pending_spell != null:
		targets.append(TARGET_INDEX_PLAYER)
	return targets


# Updates which target shows the ▼ indicator. `index` can be
# TARGET_INDEX_PLAYER (-1) for the player, or 0..N-1 for an enemy.
# Called whenever the cursor moves and at the start of TARGET_SELECT.
func _set_target(index: int) -> void:
	_target_index = index
	for i in _enemies.size():
		var be: BattleEnemy = _enemies[i]
		if be.target_indicator != null:
			be.target_indicator.visible = (i == index)
		# Tint the targeted enemy's sprite a warm gold so the cursor
		# is reinforced visually on the sprite, not just the bar. Skip
		# dead enemies — they keep their dim "defeated" modulate set
		# in _mark_enemy_defeated.
		if be.sprite != null and be.is_alive():
			be.sprite.modulate = TARGET_TINT if i == index else Color.WHITE
	# Player-side indicator + tint.
	if _player_target_indicator != null:
		_player_target_indicator.visible = (index == TARGET_INDEX_PLAYER)
	if player_sprite != null:
		player_sprite.modulate = TARGET_TINT if index == TARGET_INDEX_PLAYER else Color.WHITE


# Hides every target indicator and clears any sprite tint. Called
# when leaving TARGET_SELECT (confirm or cancel).
func _clear_target_indicators() -> void:
	for be_var in _enemies:
		var be: BattleEnemy = be_var
		if be.target_indicator != null:
			be.target_indicator.visible = false
		if be.sprite != null and be.is_alive():
			be.sprite.modulate = Color.WHITE
	if _player_target_indicator != null:
		_player_target_indicator.visible = false
	if player_sprite != null:
		player_sprite.modulate = Color.WHITE


# Mouse hover on an enemy's clickable area. During TARGET_SELECT it
# moves the cursor to that enemy (matches keyboard nav feel). No-op
# outside TARGET_SELECT or on dead enemies — the area still exists
# for them but their hover/click does nothing.
func _on_enemy_hovered(be: BattleEnemy) -> void:
	if current_state != BattleState.TARGET_SELECT:
		return
	if not be.is_alive():
		return
	var idx: int = _enemies.find(be)
	if idx >= 0:
		_set_target(idx)


# Mouse input on an enemy's clickable area. Left-click during
# TARGET_SELECT confirms the target — same code path as pressing
# Enter. Other inputs (motion, right-click, etc.) get ignored.
#
# Signature: input_event fires with (viewport, event, shape_idx)
# from the Area2D signal, plus the bound BattleEnemy at the end.
func _on_enemy_input_event(_viewport: Node, event: InputEvent, _shape_idx: int, be: BattleEnemy) -> void:
	if current_state != BattleState.TARGET_SELECT:
		return
	if not be.is_alive():
		return
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	var idx: int = _enemies.find(be)
	if idx < 0:
		return
	# Update target first so any "current target" UI snaps to the
	# clicked enemy before the attack/item animation starts.
	_set_target(idx)
	get_viewport().set_input_as_handled()
	_confirm_target()


# Mouse hover on the player's clickable area. Same role as the enemy
# version but for self-targeting items. Only meaningful when an item
# is pending — for regular attacks the player isn't a valid target.
func _on_player_hovered() -> void:
	if current_state != BattleState.TARGET_SELECT:
		return
	if _pending_item == null:
		return
	_set_target(TARGET_INDEX_PLAYER)


# Mouse click on the player's clickable area. Confirms self-target
# during item targeting; no-op outside that context.
func _on_player_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if current_state != BattleState.TARGET_SELECT:
		return
	if _pending_item == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	_set_target(TARGET_INDEX_PLAYER)
	get_viewport().set_input_as_handled()
	_confirm_target()


# Called when battle_ui's item menu fires item_selected. Stores the
# picked item as _pending_item and transitions to TARGET_SELECT so
# the player can choose where to apply it.
func _on_item_selected(item: Item) -> void:
	if current_state != BattleState.ITEM_SELECT:
		return
	if item == null:
		return
	battle_ui.hide_item_menu()
	_pending_item = item
	_change_state(BattleState.TARGET_SELECT)


# Called when battle_ui's item menu fires item_canceled. Returns to
# the action menu without consuming the turn (status tick stuck).
func _on_item_canceled() -> void:
	if current_state != BattleState.ITEM_SELECT:
		return
	battle_ui.hide_item_menu()
	_change_state(BattleState.PLAYER_MENU)


# Called when battle_ui's magic menu fires spell_selected. Validates
# MP one more time (the menu's dim state is informational — final
# authority is here). Insufficient MP shows an error and leaves the
# menu open so the player can pick a different spell. Sufficient MP
# stashes the spell as _pending_spell and routes to TARGET_SELECT.
func _on_spell_selected(spell: Spell) -> void:
	if current_state != BattleState.MAGIC_SELECT:
		return
	if spell == null:
		return
	if RPGState.mp < spell.mp_cost:
		battle_ui.set_message("Not enough MP!")
		return
	battle_ui.hide_magic_menu()
	_pending_spell = spell
	_change_state(BattleState.TARGET_SELECT)


# Called when battle_ui's magic menu fires magic_canceled. Returns to
# the action menu without consuming the turn (same as item cancel).
func _on_magic_canceled() -> void:
	if current_state != BattleState.MAGIC_SELECT:
		return
	battle_ui.hide_magic_menu()
	_change_state(BattleState.PLAYER_MENU)


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
		BattleState.ITEM_SELECT:
			_run_item_select()
		BattleState.MAGIC_SELECT:
			_run_magic_select()
		BattleState.TARGET_SELECT:
			_run_target_select()
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


# Entered after the player picks Attack OR picks an item. Default
# cursor placement depends on context:
#   - Attack (no pending item): first living enemy.
#   - Item with offensive effect (DAMAGE_FIXED): first living enemy.
#   - Item with beneficial effect (HEAL_*, CURE_STATUS): the player.
# In all cases the player can override via arrow keys or mouse click.
# Input is handled via _handle_target_select_input above.
func _run_target_select() -> void:
	var default_idx: int
	if _pending_spell != null:
		default_idx = _default_target_for_spell(_pending_spell)
	elif _pending_item != null:
		default_idx = _default_target_for_item(_pending_item)
	else:
		default_idx = _first_living_enemy_index()
		if default_idx == -1:
			# No living enemies — should already have transitioned to WIN.
			_change_state(BattleState.WIN)
			return
	_set_target(default_idx)
	battle_ui.set_message("Target?")
	# Surface the on-screen Cancel button so mouse users don't have to
	# reach for Esc. Hidden again in _confirm_target / _cancel_target.
	battle_ui.show_target_cancel_button()


# Returns the index of the first living enemy in _enemies, or -1 if
# none are alive. Used both to seed TARGET_SELECT cursor and to find
# the offensive-item default target.
func _first_living_enemy_index() -> int:
	for i in _enemies.size():
		if (_enemies[i] as BattleEnemy).is_alive():
			return i
	return -1


# Picks the default target index for a given item based on its
# effect_kind. Heals/cures default to the player (TARGET_INDEX_PLAYER);
# offensive items default to the first living enemy. Either default
# can be overridden by the player before confirming.
func _default_target_for_item(item: Item) -> int:
	match item.effect_kind:
		Item.EffectKind.DAMAGE_FIXED:
			var enemy_idx: int = _first_living_enemy_index()
			# Falls back to the player if all enemies are dead, which
			# shouldn't happen here but keeps the cursor on a valid target.
			return enemy_idx if enemy_idx != -1 else TARGET_INDEX_PLAYER
		_:
			return TARGET_INDEX_PLAYER


# Picks the default target index for a given spell. Damage spells
# default to the first living enemy; heals/cures default to the
# player. Reserved effect_kinds fall back to player so a misconfigured
# spell at least lands on a valid target rather than crashing.
func _default_target_for_spell(spell: Spell) -> int:
	match spell.effect_kind:
		Spell.EffectKind.DAMAGE:
			var enemy_idx: int = _first_living_enemy_index()
			return enemy_idx if enemy_idx != -1 else TARGET_INDEX_PLAYER
		_:
			return TARGET_INDEX_PLAYER


# Builds and shows the item picker. Reads RPGState.inventory and
# hands it to battle_ui to render. Cursor / confirm / cancel routes
# through item_selected / item_canceled signals (see _on_item_selected
# / _on_item_canceled handlers).
func _run_item_select() -> void:
	battle_ui.hide_menu()
	battle_ui.show_item_menu(RPGState.inventory)
	if RPGState.has_any_items():
		battle_ui.set_message("Use which item?")
	else:
		battle_ui.set_message("No items.")


# Builds and shows the magic picker. Hands battle_ui the available
# spell list + current MP so it can dim uncastable spells. Confirm /
# cancel routes through spell_selected / magic_canceled signals.
func _run_magic_select() -> void:
	battle_ui.hide_menu()
	battle_ui.show_magic_menu(_available_spells, RPGState.mp)
	if _available_spells.is_empty():
		battle_ui.set_message("No spells available.")
	else:
		battle_ui.set_message("Cast which spell?  (MP: %d)" % RPGState.mp)


# Scans res://resources/spells/ for .tres files at battle start.
# Anything that fails the Spell cast is logged but skipped so a
# malformed file doesn't break the magic menu entirely.
func _scan_spells_folder() -> Array[Spell]:
	var found: Array[Spell] = []
	var dir: DirAccess = DirAccess.open(SPELLS_FOLDER)
	if dir == null:
		# Folder doesn't exist yet — that's fine, just means no spells.
		return found
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var path: String = SPELLS_FOLDER + file_name
			var res: Resource = load(path)
			var spell: Spell = res as Spell
			if spell != null:
				found.append(spell)
			else:
				push_warning("battle: %s isn't a Spell" % path)
		file_name = dir.get_next()
	dir.list_dir_end()
	# Sort by name for stable menu order.
	found.sort_custom(func(a: Spell, b: Spell) -> bool:
		return a.spell_name < b.spell_name)
	return found


# Shows the opening message, waits a moment, then moves to the player's turn.
# With multiple enemies, the message lists all of them ("A GOBLIN, a SKELETON
# and a SLIME appeared!") rather than naming only the first.
func _run_intro() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message(_format_intro_message())
	# Pause for 1.5 seconds so the player has time to read the message.
	# "await" means: stop here and wait for the timer to finish before
	# continuing to the next line.
	await get_tree().create_timer(1.5).timeout
	_change_state(BattleState.PLAYER_MENU)


# Builds the intro string. One enemy: "A GOBLIN appeared!". Two: "A
# GOBLIN and a SKELETON appeared!". Three or more: "A GOBLIN, a
# SKELETON and a SLIME appeared!".
func _format_intro_message() -> String:
	if _enemies.is_empty():
		return "Battle start!"
	var names: Array[String] = []
	for be_var in _enemies:
		var be: BattleEnemy = be_var
		names.append("a " + be.name)
	if names.size() == 1:
		return "%s appeared!" % names[0].capitalize()
	if names.size() == 2:
		return "%s and %s appeared!" % [names[0].capitalize(), names[1]]
	# 3+: comma-separated, last joined with "and".
	var head: String = ", ".join(names.slice(0, names.size() - 1))
	return "%s and %s appeared!" % [head.capitalize(), names[-1]]


# Shows the action menu and prompts the player to choose what to do.
func _run_player_menu() -> void:
	battle_ui.set_message("What will you do?")
	battle_ui.show_menu()


# Called by the UI whenever the player confirms a menu choice.
# "action" will be a string like "attack", "cast", "item", or "run".
#
# Status effects tick AFTER action select, BEFORE the action runs.
# Poison damage from the tick can drop the player to 0 HP — in which
# case we transition straight to LOSE and skip the action entirely.
# `back` is a sub-menu cancel and doesn't burn a turn, so it skips
# the tick.
func _on_action_selected(action: String) -> void:
	if action == "back":
		_change_state(BattleState.PLAYER_MENU)
		return

	# Hide the menu before any subsequent UI (target picker, item
	# picker, status tick popup) shows. The downstream action handlers
	# also call hide_menu but that's now a redundant no-op.
	battle_ui.hide_menu()

	match action:
		"attack":
			# Multi-enemy: pick a target before resolving the attack.
			# Status tick fires AFTER target is confirmed — that's the
			# real "commit" point. Cancelling out of target select
			# means you haven't actually taken your turn yet.
			_change_state(BattleState.TARGET_SELECT)
		"item":
			# Show the inventory picker. _on_item_selected then routes
			# to TARGET_SELECT; status tick fires after target confirm.
			_change_state(BattleState.ITEM_SELECT)
		"magic":
			# Show the spell picker. _on_spell_selected handles MP
			# check, then routes through TARGET_SELECT like items.
			_change_state(BattleState.MAGIC_SELECT)
		"run":
			# Run has no target step, so the commit point is right here.
			# Tick before running away — escaping doesn't dodge poison.
			await _tick_player_if_needed()
			if RPGState.hp <= 0:
				_change_state(BattleState.LOSE)
				return
			_change_state(BattleState.ESCAPE)


# Fires the player's per-turn status tick, but only if it hasn't
# already happened this turn. The flag resets in _run_enemy_turn
# when a new player turn begins. Called from action commit points:
#   - _confirm_target (after target is locked in for attack or item)
#   - _on_action_selected on "run" (no target step, so commit happens here)
# If poison kills the player, caller is expected to transition to LOSE.
func _tick_player_if_needed() -> void:
	if _player_ticked_this_turn:
		return
	await _apply_status_tick("player")
	_player_ticked_this_turn = true


# Resolves the player's basic attack against the currently-targeted
# enemy (_target_index). After the attack, checks if any enemies are
# still alive — WIN if not, ENEMY_TURN if so.
func _run_player_attack() -> void:
	battle_ui.hide_menu()

	var target: BattleEnemy = _enemies[_target_index]

	# Effective stats include equipment bonuses (weapon power, +attack
	# from armor, etc.). Defender side is the raw enemy defense —
	# enemies don't have equipment in Phase 3.5.
	var roll: Dictionary = _calculate_damage(
		RPGState.get_effective_attack(),
		RPGState.get_effective_base_power(),
		RPGState.get_effective_luck(),
		target.defense)
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	target.hp = maxi(target.hp - damage, 0)

	# Lunge forward at the target enemy.
	await _lunge_at(player_sprite, target.sprite.global_position)

	# Hit effects on the target enemy.
	_hit_effect(target.sprite)
	DamagePopup.spawn(self, target.sprite.global_position + POPUP_OFFSET, damage, is_crit)
	_animate_enemy_hp(target, target.hp)
	_camera_shake(
		CAM_SHAKE_INTENSITY_CRIT if is_crit else CAM_SHAKE_INTENSITY_NORMAL,
		CAM_SHAKE_DURATION)
	if is_crit:
		_screen_flash(SCREEN_FLASH_COLOR, SCREEN_FLASH_DURATION)

	await _hit_pause(HIT_PAUSE_CRIT if is_crit else HIT_PAUSE_NORMAL)

	_lunge_back(player_sprite)

	var msg: String = "%s attacks %s!" % [RPGState.character_name, target.name]
	if is_crit:
		msg += " Critical hit!"
	battle_ui.set_message(msg)

	# Mark the target as defeated (dim sprite, hide bar) if they hit 0
	# so the read pause shows the death visually.
	if target.hp <= 0:
		_mark_enemy_defeated(target)

	await get_tree().create_timer(1.0).timeout

	if _all_enemies_defeated():
		_change_state(BattleState.WIN)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Returns true when no enemy in _enemies still has HP > 0.
func _all_enemies_defeated() -> bool:
	for be_var in _enemies:
		if (be_var as BattleEnemy).is_alive():
			return false
	return true


# Visually marks an enemy as defeated by fading the sprite and HP bar
# widget to transparent over DEATH_FADE_DURATION seconds, AFTER waiting
# DEATH_FADE_DELAY seconds so the HP bar finishes draining to 0 first.
# Fire-and-forget — the tween runs in parallel with the existing post-
# hit read pause (1.0s). With the default 0.4 delay + 0.8 fade, the
# tween finishes ~0.2s past the read pause but doesn't block the next
# turn (the dead enemy is skipped regardless of fade state).
# Stats stay on the BattleEnemy in case future "revive" mechanics want
# them; only the visuals disappear.
func _mark_enemy_defeated(be: BattleEnemy) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	if be.sprite != null:
		# set_delay holds the tween at its start value for that many
		# seconds before beginning, giving the HP drain time to finish.
		tween.tween_property(be.sprite, "modulate:a", 0.0, DEATH_FADE_DURATION) \
			.set_delay(DEATH_FADE_DELAY) \
			.set_trans(Tween.TRANS_QUAD) \
			.set_ease(Tween.EASE_OUT)
	if be.hp_bar_root != null:
		# modulate cascades to children (NameLabel, HPBar, HPText,
		# StatusLabel, TargetIndicator), so fading the root fades the
		# entire widget cluster in one tween. Same delay as the sprite
		# so the two start fading together.
		tween.tween_property(be.hp_bar_root, "modulate:a", 0.0, DEATH_FADE_DURATION) \
			.set_delay(DEATH_FADE_DELAY) \
			.set_trans(Tween.TRANS_QUAD) \
			.set_ease(Tween.EASE_OUT)


# Applies a picked Item's effect to the target identified by
# target_idx (TARGET_INDEX_PLAYER for the player, 0..N-1 for an
# enemy). Decrements inventory by 1, plays an appropriate popup,
# updates HP/MP bars, and transitions to ENEMY_TURN (or WIN/LOSE if
# the effect ended the fight).
#
# Items don't use the damage formula — DAMAGE_FIXED applies the flat
# `amount` value directly, no crit, no random roll. That's a design
# choice for clarity: items are predictable resources you can plan
# around, attacks are variable.
func _use_item(item: Item, target_idx: int) -> void:
	if item == null:
		_change_state(BattleState.ENEMY_TURN)
		return

	var msg: String = ""
	var target_is_player: bool = (target_idx == TARGET_INDEX_PLAYER)
	var target_enemy: BattleEnemy = null
	if not target_is_player:
		if target_idx < 0 or target_idx >= _enemies.size():
			# Target somehow invalid — bail to enemy turn so we don't soft-lock.
			RPGState.remove_from_inventory(item, 1)
			_change_state(BattleState.ENEMY_TURN)
			return
		target_enemy = _enemies[target_idx]

	match item.effect_kind:
		Item.EffectKind.HEAL_HP:
			msg = await _apply_item_heal_hp(item, target_is_player, target_enemy)
		Item.EffectKind.HEAL_MP:
			msg = _apply_item_heal_mp(item, target_is_player)
		Item.EffectKind.CURE_STATUS:
			msg = _apply_item_cure_status(item, target_is_player, target_enemy)
		Item.EffectKind.DAMAGE_FIXED:
			msg = await _apply_item_damage(item, target_is_player, target_enemy)

	# Consume one of the item.
	RPGState.remove_from_inventory(item, 1)

	battle_ui.set_message(msg)
	await get_tree().create_timer(1.2).timeout

	# Item use can end the fight in either direction.
	if _all_enemies_defeated():
		_change_state(BattleState.WIN)
	elif RPGState.hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Heal HP effect handler. Returns the message to display. Heals are
# capped at the target's max HP — overheal is wasted (consistent
# with most JRPGs). Async because we wait briefly so the HP bar drain
# animation plays before the message text is set.
func _apply_item_heal_hp(item: Item, target_is_player: bool, target_enemy: BattleEnemy) -> String:
	if target_is_player:
		var max_hp: int = RPGState.get_effective_max_hp()
		var before: int = RPGState.hp
		RPGState.hp = mini(RPGState.hp + item.amount, max_hp)
		var actual: int = RPGState.hp - before
		RPGState.stats_changed.emit()
		battle_ui.update_player_hp(RPGState.hp)
		DamagePopup.spawn_status(
			self, player_sprite.global_position + POPUP_OFFSET,
			actual, HEAL_HP_POPUP_COLOR)
		return "%s used %s and recovered %d HP!" % [
			RPGState.character_name, item.item_name, actual]
	# Heal on enemy.
	var before: int = target_enemy.hp
	target_enemy.hp = mini(target_enemy.hp + item.amount, target_enemy.max_hp)
	var actual: int = target_enemy.hp - before
	_animate_enemy_hp(target_enemy, target_enemy.hp)
	DamagePopup.spawn_status(
		self, target_enemy.sprite.global_position + POPUP_OFFSET,
		actual, HEAL_HP_POPUP_COLOR)
	return "%s used %s on %s. Recovered %d HP." % [
		RPGState.character_name, item.item_name, target_enemy.name, actual]


# Heal MP effect handler. Currently only meaningful on the player
# (enemies don't have MP). Returns the message.
func _apply_item_heal_mp(item: Item, target_is_player: bool) -> String:
	if not target_is_player:
		return "%s used %s — but it had no effect." % [
			RPGState.character_name, item.item_name]
	var max_mp: int = RPGState.get_effective_max_mp()
	var before: int = RPGState.mp
	RPGState.mp = mini(RPGState.mp + item.amount, max_mp)
	var actual: int = RPGState.mp - before
	RPGState.stats_changed.emit()
	DamagePopup.spawn_status(
		self, player_sprite.global_position + POPUP_OFFSET,
		actual, HEAL_MP_POPUP_COLOR)
	return "%s used %s and recovered %d MP!" % [
		RPGState.character_name, item.item_name, actual]


# Cure status effect handler. Removes `status_name` from the target's
# status list if present. Doesn't go through the immunity check —
# items that cure a status work on any combatant that has it.
func _apply_item_cure_status(item: Item, target_is_player: bool, target_enemy: BattleEnemy) -> String:
	if item.status_name == "":
		return "%s used %s — but it had no effect." % [
			RPGState.character_name, item.item_name]
	if target_is_player:
		if RPGState.has_status(item.status_name):
			RPGState.remove_status(item.status_name)
			return "%s used %s. %s cured!" % [
				RPGState.character_name, item.item_name, item.status_name]
		return "%s used %s — but it had no effect." % [
			RPGState.character_name, item.item_name]
	# Cure on enemy.
	if target_enemy.statuses.has(item.status_name):
		target_enemy.statuses.erase(item.status_name)
		_refresh_enemy_status_label(target_enemy)
		return "%s used %s on %s. %s cured!" % [
			RPGState.character_name, item.item_name, target_enemy.name, item.status_name]
	return "%s used %s on %s — no effect." % [
		RPGState.character_name, item.item_name, target_enemy.name]


# Fixed damage effect handler. No formula, no crit, no random roll —
# just deals `item.amount` damage to the target. Floors at 1 (can't
# heal something with a damage item). Triggers the enemy hit effect
# + camera shake so the visual impact roughly matches a normal hit.
func _apply_item_damage(item: Item, target_is_player: bool, target_enemy: BattleEnemy) -> String:
	var damage: int = maxi(1, item.amount)
	if target_is_player:
		RPGState.hp = maxi(RPGState.hp - damage, 0)
		RPGState.stats_changed.emit()
		battle_ui.update_player_hp(RPGState.hp)
		DamagePopup.spawn_status(
			self, player_sprite.global_position + POPUP_OFFSET,
			damage, ITEM_DAMAGE_POPUP_COLOR)
		_hit_effect(player_sprite)
		_camera_shake(CAM_SHAKE_INTENSITY_NORMAL, CAM_SHAKE_DURATION)
		return "%s used %s on themselves?! %d damage." % [
			RPGState.character_name, item.item_name, damage]
	# Damage on enemy.
	target_enemy.hp = maxi(target_enemy.hp - damage, 0)
	_animate_enemy_hp(target_enemy, target_enemy.hp)
	DamagePopup.spawn_status(
		self, target_enemy.sprite.global_position + POPUP_OFFSET,
		damage, ITEM_DAMAGE_POPUP_COLOR)
	_hit_effect(target_enemy.sprite)
	_camera_shake(CAM_SHAKE_INTENSITY_NORMAL, CAM_SHAKE_DURATION)
	if target_enemy.hp <= 0:
		_mark_enemy_defeated(target_enemy)
	return "%s used %s on %s! %d damage." % [
		RPGState.character_name, item.item_name, target_enemy.name, damage]


# Casts a spell at the given target. Mirrors _use_item's structure
# but uses MP cost instead of inventory consumption, and the damage
# formula instead of flat damage. _on_spell_selected already validated
# that the player has enough MP, but we re-check here as the final
# authority (in case stats changed between the menu and target confirm).
func _use_spell(spell: Spell, target_idx: int) -> void:
	if spell == null:
		_change_state(BattleState.ENEMY_TURN)
		return
	if RPGState.mp < spell.mp_cost:
		# Defensive fallback — shouldn't happen given the menu check.
		battle_ui.set_message("Not enough MP!")
		await get_tree().create_timer(1.0).timeout
		_change_state(BattleState.ENEMY_TURN)
		return

	# Resolve target (player vs enemy).
	var target_is_player: bool = (target_idx == TARGET_INDEX_PLAYER)
	var target_enemy: BattleEnemy = null
	if not target_is_player:
		if target_idx < 0 or target_idx >= _enemies.size():
			_change_state(BattleState.ENEMY_TURN)
			return
		target_enemy = _enemies[target_idx]

	# Pay MP up-front. Even if the effect misses or is no-op (e.g.
	# curing a status the target doesn't have), the spell still costs
	# its MP — that matches classic JRPG behavior.
	RPGState.mp = maxi(RPGState.mp - spell.mp_cost, 0)
	RPGState.stats_changed.emit()

	var msg: String = ""
	match spell.effect_kind:
		Spell.EffectKind.DAMAGE:
			msg = _apply_spell_damage(spell, target_is_player, target_enemy)
		Spell.EffectKind.HEAL_HP:
			# Reserved — not yet implemented. Show a placeholder.
			msg = "%s cast %s. (HEAL_HP not implemented yet)" % [
				RPGState.character_name, spell.spell_name]
		Spell.EffectKind.CURE_STATUS:
			# Reserved — not yet implemented.
			msg = "%s cast %s. (CURE_STATUS not implemented yet)" % [
				RPGState.character_name, spell.spell_name]

	battle_ui.set_message(msg)
	await get_tree().create_timer(1.2).timeout

	# Spell can end the fight in either direction.
	if _all_enemies_defeated():
		_change_state(BattleState.WIN)
	elif RPGState.hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Damage-spell effect: uses the standard damage formula but with
# INTELLIGENCE as the attacker stat (rather than attack). spell.power
# stacks onto intelligence the same way a weapon's power_bonus stacks
# onto attack. Crits still roll off luck.
func _apply_spell_damage(spell: Spell, target_is_player: bool, target_enemy: BattleEnemy) -> String:
	# Decide popup color — spell's own override if non-white, otherwise
	# the global magic-default magenta.
	var popup_color: Color = spell.popup_color
	if popup_color == Color.WHITE:
		popup_color = MAGIC_DAMAGE_DEFAULT_COLOR

	if target_is_player:
		# Magic damage on self (e.g. testing). Use the player's own
		# defense and luck.
		var roll: Dictionary = _calculate_damage(
			RPGState.get_effective_intelligence(),
			spell.power,
			RPGState.get_effective_luck(),
			RPGState.get_effective_defense())
		var damage: int = roll["damage"]
		var is_crit: bool = roll["crit"]
		RPGState.hp = maxi(RPGState.hp - damage, 0)
		RPGState.stats_changed.emit()
		battle_ui.update_player_hp(RPGState.hp)
		DamagePopup.spawn_status(
			self, player_sprite.global_position + POPUP_OFFSET,
			damage, popup_color)
		_hit_effect(player_sprite)
		_camera_shake(CAM_SHAKE_INTENSITY_NORMAL, CAM_SHAKE_DURATION)
		var crit_text: String = " Critical hit!" if is_crit else ""
		return "%s cast %s on themselves! %d damage.%s" % [
			RPGState.character_name, spell.spell_name, damage, crit_text]

	# Standard case: damage spell on an enemy.
	var roll: Dictionary = _calculate_damage(
		RPGState.get_effective_intelligence(),
		spell.power,
		RPGState.get_effective_luck(),
		target_enemy.defense)
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]
	target_enemy.hp = maxi(target_enemy.hp - damage, 0)
	_animate_enemy_hp(target_enemy, target_enemy.hp)
	DamagePopup.spawn_status(
		self, target_enemy.sprite.global_position + POPUP_OFFSET,
		damage, popup_color)
	_hit_effect(target_enemy.sprite)
	_camera_shake(
		CAM_SHAKE_INTENSITY_CRIT if is_crit else CAM_SHAKE_INTENSITY_NORMAL,
		CAM_SHAKE_DURATION)
	if is_crit:
		_screen_flash(SCREEN_FLASH_COLOR, SCREEN_FLASH_DURATION)
	if target_enemy.hp <= 0:
		_mark_enemy_defeated(target_enemy)
	var crit_text: String = " Critical hit!" if is_crit else ""
	return "%s cast %s on %s! %d damage.%s" % [
		RPGState.character_name, spell.spell_name, target_enemy.name, damage, crit_text]


# Each living enemy takes a turn in left-to-right order. Within a single
# enemy's turn:
#   1. Tick statuses (poison, etc.). If HP hits 0, skip the rest.
#   2. Lunge + hit + popup + drain the player's HP.
#   3. Pause for read time.
# If the player dies at any point, transition to LOSE immediately.
# After all enemies have acted, hand control back to the player.
func _run_enemy_turn() -> void:
	for be_var in _enemies:
		var be: BattleEnemy = be_var
		if not be.is_alive():
			continue
		await _take_enemy_turn(be)
		if RPGState.hp <= 0:
			_change_state(BattleState.LOSE)
			return
		# If the enemy killed itself via poison tick, skip cleanly.
		# All-dead check happens once at the end so multi-enemy fights
		# don't transition mid-loop.

	if _all_enemies_defeated():
		_change_state(BattleState.WIN)
	else:
		# New player turn begins — reset the per-turn tick flag so
		# their next action triggers a fresh status tick.
		_player_ticked_this_turn = false
		_change_state(BattleState.PLAYER_MENU)


# Single enemy's turn. Status tick → attack → animations.
# Returns when this enemy's whole turn has completed (or they died
# mid-tick and skipped attacking). Caller handles state transitions.
func _take_enemy_turn(be: BattleEnemy) -> void:
	# Tick this enemy's statuses first.
	await _apply_status_tick_for_enemy(be)
	if not be.is_alive():
		# Poison killed the enemy. Visually mark them defeated and bail.
		_mark_enemy_defeated(be)
		return

	var roll: Dictionary = _calculate_damage(
		be.attack, be.base_power, be.luck,
		RPGState.get_effective_defense())
	var damage: int = roll["damage"]
	var is_crit: bool = roll["crit"]

	RPGState.hp = maxi(RPGState.hp - damage, 0)
	RPGState.stats_changed.emit()

	await _lunge_at(be.sprite, player_sprite.global_position)
	_hit_effect(player_sprite)
	DamagePopup.spawn(self, player_sprite.global_position + POPUP_OFFSET, damage, is_crit)
	battle_ui.update_player_hp(RPGState.hp)
	_camera_shake(
		CAM_SHAKE_INTENSITY_CRIT if is_crit else CAM_SHAKE_INTENSITY_NORMAL,
		CAM_SHAKE_DURATION)
	if is_crit:
		_screen_flash(SCREEN_FLASH_COLOR, SCREEN_FLASH_DURATION)

	await _hit_pause(HIT_PAUSE_CRIT if is_crit else HIT_PAUSE_NORMAL)

	_lunge_back(be.sprite)

	var msg: String = "%s attacks!" % be.name
	if is_crit:
		msg += " Critical hit!"
	battle_ui.set_message(msg)
	await get_tree().create_timer(1.0).timeout


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


# Battle is over — player wins. Lists every defeated enemy by name so
# multi-enemy fights read clearly. "GOBLIN was defeated!" for one,
# "GOBLIN and SKELETON were defeated!" for two, "GOBLIN, SKELETON and
# SLIME were defeated!" for three+.
func _run_win() -> void:
	battle_ui.hide_menu()
	var names: Array[String] = []
	for be_var in _enemies:
		names.append((be_var as BattleEnemy).name)
	var msg: String
	if names.size() == 1:
		msg = "%s was defeated!" % names[0]
	elif names.size() == 2:
		msg = "%s and %s were defeated!" % [names[0], names[1]]
	else:
		var head: String = ", ".join(names.slice(0, names.size() - 1))
		msg = "%s and %s were defeated!" % [head, names[-1]]
	battle_ui.set_message(msg)


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


# --- Status effects ---
# All status-effect ticks run through this function so the visual
# treatment (popup, HP drain, message, pause) and the damage math
# stay in one place. Currently only "Poisoned" is wired; adding more
# is one new branch in the loop below.
#
# combatant: "player" or "enemy". Picks the right HP source / sprite
# / display name. Async because the tick takes ~1.2s of read time
# and the caller awaits before continuing the turn.
# Player tick. Iterates RPGState.status_effects and routes each known
# status to its handler. If a tick kills the player, stops processing
# (caller transitions to LOSE).
func _apply_status_tick(combatant: String) -> void:
	if combatant != "player":
		push_warning("battle._apply_status_tick: only 'player' supported here; use _apply_status_tick_for_enemy for enemies")
		return
	for status_name in RPGState.status_effects:
		match status_name:
			STATUS_POISONED:
				await _tick_poison_player()
				if RPGState.hp <= 0:
					return


# Per-enemy tick variant. Iterates the BattleEnemy's own status list
# and routes each known status to its handler. If a tick kills the
# enemy, stops processing.
func _apply_status_tick_for_enemy(be: BattleEnemy) -> void:
	if be.statuses.is_empty():
		return
	for status_name in be.statuses:
		match status_name:
			STATUS_POISONED:
				await _tick_poison_enemy(be)
				if not be.is_alive():
					return


# Player poison tick: 5% max HP damage, popup over player sprite, HP
# bar drain, message, pause for read.
func _tick_poison_player() -> void:
	var damage: int = maxi(1, int(float(RPGState.get_effective_max_hp()) * POISON_PERCENT_DAMAGE))
	RPGState.hp = maxi(RPGState.hp - damage, 0)
	RPGState.stats_changed.emit()
	DamagePopup.spawn_status(
		self,
		player_sprite.global_position + POPUP_OFFSET,
		damage,
		POISON_POPUP_COLOR)
	battle_ui.update_player_hp(RPGState.hp)
	battle_ui.set_message("%s is hurt by poison!" % RPGState.character_name)
	await get_tree().create_timer(STATUS_TICK_PAUSE).timeout


# Per-enemy poison tick. Same shape as _tick_poison_player but writes
# to the BattleEnemy's owned widgets.
func _tick_poison_enemy(be: BattleEnemy) -> void:
	var damage: int = maxi(1, int(float(be.max_hp) * POISON_PERCENT_DAMAGE))
	be.hp = maxi(be.hp - damage, 0)
	DamagePopup.spawn_status(
		self,
		be.sprite.global_position + POPUP_OFFSET,
		damage,
		POISON_POPUP_COLOR)
	_animate_enemy_hp(be, be.hp)
	battle_ui.set_message("%s is hurt by poison!" % be.name)
	await get_tree().create_timer(STATUS_TICK_PAUSE).timeout


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
