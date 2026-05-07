# battle.gd
# The brain of the battle system. Tracks HP, decides whose turn it is,
# calculates damage, and drives the state machine that controls the flow
# of the whole fight. Attached to the root Battle node in battle.tscn.
#
# Sub-phase 3c integration:
#   - Player stats come from the RPGState autoload (max_hp, hp, attack,
#     character_name) so HP carries over between battles and the player's
#     chosen name is used in messages.
#   - End-of-battle states (WIN / LOSE / ESCAPE) wait for the player to
#     press the interact key, then return to whatever location triggered
#     the battle (GameManager.rpg_battle_return_location — currently
#     OVERWORLD; later DUNGEON).
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
# Player stats now come from RPGState. Enemy stats stay @export so they
# can be tuned per-encounter once enemy variety lands. For Phase 3c every
# random encounter is a Goblin with these defaults.
@export var enemy_name: String = "GOBLIN"
@export var enemy_max_hp: int = 8     # Enemy starts with this much health
@export var enemy_atk_min: int = 1    # Minimum damage the enemy deals
@export var enemy_atk_max: int = 2    # Maximum damage the enemy deals

# How wide the variance is around the player's RPGState.attack value.
# damage = randi_range(attack - 1, attack + 2). Tuned to feel "punchy"
# at the level-1 default attack=8 → 7..10 damage per swing.
const PLAYER_ATK_LOW_OFFSET: int = -1
const PLAYER_ATK_HIGH_OFFSET: int = 2

# --- Runtime Variables ---
# These change during the battle as damage is dealt.
# The player's HP lives on RPGState directly — we read and write it
# there so the value persists across battles and the rest of the RPG
# (HUDs, save files, etc.) can read it without needing to know about
# this scene.
var enemy_hp: int
var current_state: BattleState  # Tracks which phase we're currently in

# "@onready" means this gets assigned as soon as the scene is ready to use.
# The "$BattleUI" is shorthand for "find the child node named BattleUI".
@onready var battle_ui: CanvasLayer = $BattleUI


# _ready is called once automatically when the scene first loads.
# We use it to set everything up before the battle begins.
func _ready() -> void:
	# Seed enemy HP from the @export defaults.
	enemy_hp = enemy_max_hp

	# Push player + enemy max HP / current HP to the UI. The bars in the
	# .tscn have placeholder max values (10/8) — these calls overwrite
	# them with the real stats so the fill ratio is correct from frame 1.
	battle_ui.set_player_name(RPGState.character_name)
	battle_ui.set_enemy_name(enemy_name)
	battle_ui.set_player_max_hp(RPGState.max_hp)
	battle_ui.set_enemy_max_hp(enemy_max_hp)
	battle_ui.update_player_hp(RPGState.hp)
	battle_ui.update_enemy_hp(enemy_hp)

	# "Connect" means: whenever the UI tells us the player picked an action,
	# automatically call our _on_action_selected function with that choice.
	# This keeps the UI and the game logic separate — the UI doesn't need to
	# know anything about damage calculations, and vice versa.
	battle_ui.action_selected.connect(_on_action_selected)

	# Kick off the battle with the intro sequence
	_change_state(BattleState.INTRO)


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
	battle_ui.set_message("A %s appeared!" % enemy_name)
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

	# Roll damage based on the Hero's RPGState.attack stat with a small
	# variance window around it. maxi() guards against weird negative
	# attack values producing 0-or-negative max bounds.
	var atk: int = RPGState.attack
	var low: int = maxi(1, atk + PLAYER_ATK_LOW_OFFSET)
	var high: int = maxi(low, atk + PLAYER_ATK_HIGH_OFFSET)
	var damage := randi_range(low, high)

	# Subtract damage from enemy HP, but don't let it go below 0.
	# "maxi" returns the larger of the two values — so if damage would push
	# HP to -2, we get max(-2, 0) = 0 instead.
	enemy_hp = maxi(enemy_hp - damage, 0)

	# Send the new HP to the UI so the health bar updates
	battle_ui.update_enemy_hp(enemy_hp)

	# Display the attack result. "%s" is a placeholder that gets replaced
	# by the player's chosen name (e.g. "ARTHUR attacks! 9 damage!").
	battle_ui.set_message("%s attacks! %d damage!" % [RPGState.character_name, damage])

	await get_tree().create_timer(1.5).timeout

	# Check if the enemy was knocked out
	if enemy_hp <= 0:
		_change_state(BattleState.WIN)
	else:
		_change_state(BattleState.ENEMY_TURN)


# Resolves the enemy's attack against the player.
# Works the same way as the player attack, just in reverse.
func _run_enemy_turn() -> void:
	var damage := randi_range(enemy_atk_min, enemy_atk_max)
	# Write damage straight into RPGState so the player's HP carries over
	# to the next battle. stats_changed.emit() lets any HUD listeners
	# (overworld pause menu, future status panels) refresh without polling.
	RPGState.hp = maxi(RPGState.hp - damage, 0)
	RPGState.stats_changed.emit()
	battle_ui.update_player_hp(RPGState.hp)
	battle_ui.set_message("%s attacks! %d damage!" % [enemy_name, damage])
	await get_tree().create_timer(1.5).timeout

	# Check if the player was knocked out
	if RPGState.hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.PLAYER_MENU)


# Handles the Cast and Item sub-menus.
# These are stubs for now — they show a message and wait for input to go back.
func _run_sub_menu() -> void:
	battle_ui.enter_sub_menu()
	battle_ui.set_message("Nothing here...")


# Battle is over — player wins. Shows the defeat message and waits for
# the player to press interact (handled in _unhandled_input).
func _run_win() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("%s was defeated!" % enemy_name)


# Battle is over — player loses. Shows the death message and waits for
# the player to press interact. _unhandled_input handles HP restoration
# and the return-to-overworld transition.
func _run_lose() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("%s has died." % RPGState.character_name)


# Player chose Run and got away. Shows the escape message and waits for
# the player to press interact before returning to the overworld.
func _run_escape_outcome() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("Got away safely!")


# Sends the player back to whichever RPG location triggered this battle
# (currently always OVERWORLD; dungeons will set DUNGEON later). main.gd
# picks up the rpg_location_changed signal and swaps the active scene.
func _finish_battle_and_return() -> void:
	GameManager.switch_rpg_location(GameManager.rpg_battle_return_location)
