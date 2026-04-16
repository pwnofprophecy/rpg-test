extends CanvasLayer

signal action_selected(action: String)

@onready var text_label: Label = $TextBox/MarginContainer/TextLabel
@onready var menu_box: PanelContainer = $MenuBox
@onready var player_hp_bar: ProgressBar = $PlayerHealthBar/HPBar
@onready var enemy_hp_bar: ProgressBar = $EnemyHealthBar/HPBar
@onready var menu_labels: Array[Label] = [
	$MenuBox/MenuGrid/AttackLabel,
	$MenuBox/MenuGrid/CastLabel,
	$MenuBox/MenuGrid/ItemLabel,
	$MenuBox/MenuGrid/RunLabel,
]

var cursor_index: int = 0
var menu_active: bool = false
var sub_menu_active: bool = false

const ACTIONS: Array[String] = ["attack", "cast", "item", "run"]


func _unhandled_input(event: InputEvent) -> void:
	if sub_menu_active:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
			sub_menu_active = false
			action_selected.emit("back")
			get_viewport().set_input_as_handled()
		return

	if not menu_active:
		return

	var handled := true
	if event.is_action_pressed("ui_right") and cursor_index % 2 == 0:
		cursor_index += 1
	elif event.is_action_pressed("ui_left") and cursor_index % 2 == 1:
		cursor_index -= 1
	elif event.is_action_pressed("ui_down") and cursor_index < 2:
		cursor_index += 2
	elif event.is_action_pressed("ui_up") and cursor_index >= 2:
		cursor_index -= 2
	elif event.is_action_pressed("ui_accept"):
		menu_active = false
		action_selected.emit(ACTIONS[cursor_index])
	else:
		handled = false

	if handled:
		_update_cursor()
		get_viewport().set_input_as_handled()


func _update_cursor() -> void:
	for i in menu_labels.size():
		if i == cursor_index:
			menu_labels[i].text = "> " + ACTIONS[i].capitalize()
		else:
			menu_labels[i].text = "  " + ACTIONS[i].capitalize()


func set_message(text: String) -> void:
	text_label.text = text


func update_player_hp(value: int) -> void:
	player_hp_bar.value = value


func update_enemy_hp(value: int) -> void:
	enemy_hp_bar.value = value


func show_menu() -> void:
	menu_box.visible = true
	menu_active = true
	cursor_index = 0
	_update_cursor()


func hide_menu() -> void:
	menu_box.visible = false
	menu_active = false


func enter_sub_menu() -> void:
	menu_box.visible = false
	menu_active = false
	sub_menu_active = true
