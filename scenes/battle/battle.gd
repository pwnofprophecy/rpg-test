# battle.gd
# The brain of the battle system. Tracks HP, decides whose turn it is,
# calculates damage, and drives the state machine that controls the flow
# of the whole fight. Attached to the root Battle node in battle.tscn.

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
	WIN,           # The enemy has been defeated
	LOSE,          # The player has been defeated
}

# --- Tunable Combat Values ---
# These are all marked with "@export" so you can adjust them directly in the
# Godot editor inspector without digging into the code.
@export var player_max_hp: int = 10   # Player starts with this much health
@export var enemy_max_hp: int = 8     # Enemy starts with this much health
@export var player_atk_min: int = 1   # Minimum damage the player deals
@export var player_atk_max: int = 3   # Maximum damage the player deals
@export var enemy_atk_min: int = 1    # Minimum damage the enemy deals
@export var enemy_atk_max: int = 2    # Maximum damage the enemy deals

# --- Runtime Variables ---
# These change during the battle as damage is dealt.
var player_hp: int
var enemy_hp: int
var current_state: BattleState  # Tracks which phase we're currently in

# "@onready" means this gets assigned as soon as the scene is ready to use.
# The "$BattleUI" is shorthand for "find the child node named BattleUI".
@onready var battle_ui: CanvasLayer = $BattleUI


# _ready is called once automatically when the scene first loads.
# We use it to set everything up before the battle begins.
func _ready() -> void:
	# Set current HP to their starting (max) values
	player_hp = player_max_hp
	enemy_hp = enemy_max_hp

	# "Connect" means: whenever the UI tells us the player picked an action,
	# automatically call our _on_action_selected function with that choice.
	# This keeps the UI and the game logic separate — the UI doesn't need to
	# know anything about damage calculations, and vice versa.
	battle_ui.action_selected.connect(_on_action_selected)

	# Push the starting HP values to the UI so the health bars display correctly
	battle_ui.update_player_hp(player_hp)
	battle_ui.update_enemy_hp(enemy_hp)

	# Kick off the battle with the intro sequence
	_change_state(BattleState.INTRO)


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


# Shows the opening message, waits a moment, then moves to the player's turn.
func _run_intro() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("A GOBLIN appeared!")
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
			_run_escape()
		"back":
			# Player pressed back from a sub-menu, return to the action menu
			_change_state(BattleState.PLAYER_MENU)


# Handles the player trying to flee the battle (always fails for now).
func _run_escape() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("Can't escape!")
	await get_tree().create_timer(1.0).timeout
	_change_state(BattleState.PLAYER_MENU)


# Resolves the player's basic attack against the enemy.
func _run_player_attack() -> void:
	battle_ui.hide_menu()

	# Roll a random number between the min and max attack values (inclusive).
	var damage := randi_range(player_atk_min, player_atk_max)

	# Subtract damage from enemy HP, but don't let it go below 0.
	# "maxi" returns the larger of the two values — so if damage would push
	# HP to -2, we get max(-2, 0) = 0 instead.
	enemy_hp = maxi(enemy_hp - damage, 0)

	# Send the new HP to the UI so the health bar updates
	battle_ui.update_enemy_hp(enemy_hp)

	# Display the attack result. "%d" is a placeholder that gets replaced
	# by the value of "damage" at runtime (e.g. "HERO attacks! 3 damage!")
	battle_ui.set_message("HERO attacks! %d damage!" % damage)

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
	player_hp = maxi(player_hp - damage, 0)
	battle_ui.update_player_hp(player_hp)
	battle_ui.set_message("GOBLIN attacks! %d damage!" % damage)
	await get_tree().create_timer(1.5).timeout

	# Check if the player was knocked out
	if player_hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.PLAYER_MENU)


# Handles the Cast and Item sub-menus.
# These are stubs for now — they show a message and wait for input to go back.
func _run_sub_menu() -> void:
	battle_ui.enter_sub_menu()
	battle_ui.set_message("Nothing here...")


# Battle is over — player wins.
func _run_win() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("YOU WIN :)")


# Battle is over — player loses.
func _run_lose() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("YOU LOSE :(")
