extends Node2D

enum BattleState {
	INTRO,
	PLAYER_MENU,
	PLAYER_ATTACK,
	ENEMY_TURN,
	SUB_MENU,
	WIN,
	LOSE,
}

@export var player_max_hp: int = 10
@export var enemy_max_hp: int = 8
@export var player_atk_min: int = 1
@export var player_atk_max: int = 3
@export var enemy_atk_min: int = 1
@export var enemy_atk_max: int = 2

var player_hp: int
var enemy_hp: int
var current_state: BattleState

@onready var battle_ui: CanvasLayer = $BattleUI


func _ready() -> void:
	player_hp = player_max_hp
	enemy_hp = enemy_max_hp

	battle_ui.action_selected.connect(_on_action_selected)
	battle_ui.update_player_hp(player_hp)
	battle_ui.update_enemy_hp(enemy_hp)

	_change_state(BattleState.INTRO)


func _change_state(new_state: BattleState) -> void:
	current_state = new_state
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


func _run_intro() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("A GOBLIN appeared!")
	await get_tree().create_timer(1.5).timeout
	_change_state(BattleState.PLAYER_MENU)


func _run_player_menu() -> void:
	battle_ui.set_message("What will you do?")
	battle_ui.show_menu()


func _on_action_selected(action: String) -> void:
	match action:
		"attack":
			_change_state(BattleState.PLAYER_ATTACK)
		"cast", "item":
			_change_state(BattleState.SUB_MENU)
		"run":
			_run_escape()
		"back":
			_change_state(BattleState.PLAYER_MENU)


func _run_escape() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("Can't escape!")
	await get_tree().create_timer(1.0).timeout
	_change_state(BattleState.PLAYER_MENU)


func _run_player_attack() -> void:
	battle_ui.hide_menu()
	var damage := randi_range(player_atk_min, player_atk_max)
	enemy_hp = maxi(enemy_hp - damage, 0)
	battle_ui.update_enemy_hp(enemy_hp)
	battle_ui.set_message("HERO attacks! %d damage!" % damage)
	await get_tree().create_timer(1.5).timeout
	if enemy_hp <= 0:
		_change_state(BattleState.WIN)
	else:
		_change_state(BattleState.ENEMY_TURN)


func _run_enemy_turn() -> void:
	var damage := randi_range(enemy_atk_min, enemy_atk_max)
	player_hp = maxi(player_hp - damage, 0)
	battle_ui.update_player_hp(player_hp)
	battle_ui.set_message("GOBLIN attacks! %d damage!" % damage)
	await get_tree().create_timer(1.5).timeout
	if player_hp <= 0:
		_change_state(BattleState.LOSE)
	else:
		_change_state(BattleState.PLAYER_MENU)


func _run_sub_menu() -> void:
	battle_ui.enter_sub_menu()
	battle_ui.set_message("Nothing here...")


func _run_win() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("YOU WIN :)")


func _run_lose() -> void:
	battle_ui.hide_menu()
	battle_ui.set_message("YOU LOSE :(")
