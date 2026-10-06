extends Node

enum PlayState { PAUSED, RUNNING, GAME_OVER }

const DINO_START_POS: Vector2 = Vector2(150, 488)
const CAM_START_POS: Vector2 = Vector2(576, 324)
const SPEED: float = 960.0
const SCORE_MODIFIER: float = 10.0
const OBSTACLE_TYPES: Array = [preload("res://scenes/stump.tscn"), preload("res://scenes/rock.tscn"), preload("res://scenes/barrel.tscn")]

var play_state: PlayState = PlayState.PAUSED
var game_running: bool:
	get:
		return play_state == PlayState.RUNNING
var speed: float = SPEED
var score: float = 0.0
var high_score: float = 0.0
var obstacles: Array = []
var next_obstacle_x: float = 1200.0
var obstacles_enabled: bool = true
var resume_requested: bool = false
var pause_reason: String = "Connect your sensor and calibrate in the desktop host."
var keyboard_mode: bool = false
var input_adapter: Node
var keyboard_state: Dictionary = {"button_1": {"pressed": false, "value": 0}, "button_2": {"pressed": false, "value": 0}}
var keyboard_transitions: Array = []
var resume_button: Button
var status_label: Label
var pause_panel: PanelContainer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Dino.process_mode = Node.PROCESS_MODE_PAUSABLE
	$Bg.process_mode = Node.PROCESS_MODE_PAUSABLE
	$GameOver.get_node("Button").pressed.connect(new_game)
	keyboard_mode = OS.get_cmdline_user_args().has("--keyboard")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--jump-hold-seconds="):
			$Dino.max_jump_hold_seconds = clampf(argument.get_slice("=", 1).to_float(), 0.0, 0.5)
	_create_pause_ui()
	if not keyboard_mode:
		input_adapter = preload("res://data_process/controller_client.gd").new()
		input_adapter.availability_changed.connect(_availability_changed)
		add_child(input_adapter)
	new_game()

func _create_pause_ui() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.position = Vector2(276, 150)
	pause_panel.custom_minimum_size = Vector2(600, 260)
	$HUD.add_child(pause_panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	pause_panel.add_child(column)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(560, 75)
	status_label.add_theme_font_size_override("font_size", 22)
	column.add_child(status_label)
	resume_button = Button.new()
	resume_button.text = "Resume"
	resume_button.pressed.connect(resume_game)
	column.add_child(resume_button)
	if not keyboard_mode:
		var tune_button: Button = Button.new()
		tune_button.text = "Calibration & tuning"
		tune_button.pressed.connect(func(): OS.shell_open(input_adapter.base_url + "/controller/tuning"))
		column.add_child(tune_button)
	var quit_button: Button = Button.new()
	quit_button.text = "Quit"
	quit_button.pressed.connect(func(): get_tree().quit())
	column.add_child(quit_button)

func new_game() -> void:
	play_state = PlayState.PAUSED
	resume_requested = false
	score = 0.0
	next_obstacle_x = 1200.0
	for obstacle: Node in obstacles:
		obstacle.queue_free()
	obstacles.clear()
	$Dino.position = DINO_START_POS
	$Dino.reset_controls()
	$Camera2D.position = CAM_START_POS
	$Ground.position = Vector2.ZERO
	$GameOver.hide()
	get_tree().paused = false
	$Dino.advance(1.0 / 60.0, false)
	get_tree().paused = true
	if keyboard_mode:
		pause_reason = "Keyboard play test. Space jumps. Down ducks. Escape pauses."
	_update_ui()

func pause_game(reason: String = "Paused. Resume when ready.") -> void:
	if play_state == PlayState.GAME_OVER:
		return
	play_state = PlayState.PAUSED
	resume_requested = false
	pause_reason = reason
	get_tree().paused = true
	_update_ui()

func resume_game() -> void:
	if play_state == PlayState.GAME_OVER:
		return
	if keyboard_mode:
		keyboard_transitions.clear()
		_begin_play(keyboard_state)
	elif input_adapter.available and input_adapter.has_current_frame:
		resume_requested = true
		input_adapter.request_resynchronize()
		pause_reason = "Synchronizing current controls..."
	_update_ui()

func _begin_play(state: Dictionary) -> void:
	resume_requested = false
	play_state = PlayState.RUNNING
	get_tree().paused = false
	$Dino.synchronize_controls(state)
	_update_ui()

func _availability_changed(available: bool, reason: String) -> void:
	if not available:
		pause_game("Input unavailable. " + reason.replace("_", " ") + ".")
	else:
		pause_reason = "Controller ready. Choose Resume to play."
	_update_ui()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if game_running:
			pause_game()
		elif play_state == PlayState.PAUSED:
			resume_game()
	if not keyboard_mode or (event is InputEventKey and event.echo):
		return
	for action: String in ["ui_accept", "ui_down"]:
		if not event.is_action(action):
			continue
		var input_id: String = "button_1" if action == "ui_accept" else "button_2"
		var pressed: bool = event.is_pressed()
		if keyboard_state[input_id]["pressed"] != pressed:
			keyboard_state[input_id] = {"pressed": pressed, "value": int(pressed)}
			keyboard_transitions.append({"inputId": input_id, "pressed": pressed, "atUs": Time.get_ticks_usec()})

func _physics_process(delta: float) -> void:
	if not keyboard_mode:
		input_adapter.poll_socket()
		for frame: Dictionary in input_adapter.take_frames():
			if resume_requested and frame["resynchronize"] and frame["available"]:
				_begin_play(frame["state"])
			elif game_running:
				if frame["resynchronize"]:
					pause_game("Controller changed. Choose Resume to synchronize.")
				else:
					$Dino.apply_controller_frame(frame["state"], frame["transitions"])
		input_adapter.request_frame()
	elif game_running:
		$Dino.apply_controller_frame(keyboard_state, keyboard_transitions)
	keyboard_transitions.clear()
	if not game_running:
		_update_ui()
		return
	advance_game(delta)

func advance_game(delta: float) -> void:
	$Dino.advance(delta, true)
	$Dino.position.x += SPEED * delta
	$Camera2D.position.x += SPEED * delta
	score += SPEED * delta
	if $Camera2D.position.x - $Ground.position.x > 1152.0 * 1.5:
		$Ground.position.x += 1152.0
	if obstacles_enabled:
		_generate_obstacles()
	for obstacle: Node2D in obstacles.duplicate():
		if obstacle.position.x < $Camera2D.position.x - 1152.0:
			obstacle.queue_free()
			obstacles.erase(obstacle)
	_update_ui()

func _generate_obstacles() -> void:
	if $Dino.position.x + 1152.0 < next_obstacle_x:
		return
	var obstacle: Area2D = OBSTACLE_TYPES.pick_random().instantiate()
	var sprite: Sprite2D = obstacle.get_node("Sprite2D")
	obstacle.position = Vector2(next_obstacle_x, 552.0 - sprite.texture.get_height() * sprite.scale.y / 2.0 + 5.0)
	obstacle.body_entered.connect(_hit_obstacle)
	add_child(obstacle)
	obstacles.append(obstacle)
	next_obstacle_x += randf_range(600.0, 950.0)

func _hit_obstacle(body: Node) -> void:
	if body != $Dino:
		return
	high_score = maxf(high_score, score)
	play_state = PlayState.GAME_OVER
	get_tree().paused = true
	$GameOver.show()
	pause_panel.hide()

func _update_ui() -> void:
	$HUD/ScoreLabel.text = "SCORE: " + str(int(score / SCORE_MODIFIER))
	$HUD/HighScoreLabel.text = "HIGH SCORE: " + str(int(high_score / SCORE_MODIFIER))
	pause_panel.visible = play_state == PlayState.PAUSED
	status_label.text = pause_reason
	resume_button.disabled = resume_requested or (not keyboard_mode and (not input_adapter.available or not input_adapter.has_current_frame))

func get_snapshot() -> Dictionary:
	var snapshot: Dictionary = {"running": game_running, "paused": get_tree().paused, "resumeRequested": resume_requested, "reason": pause_reason, "score": score, "x": $Dino.position.x, "y": $Dino.position.y, "velocityY": $Dino.velocity.y, "grounded": $Dino.is_on_floor(), "ducking": $Dino.ducking, "jumpHeld": $Dino.jump_held, "duckHeld": $Dino.duck_held, "jumpCount": $Dino.jump_count, "jumpHoldSeconds": $Dino.jump_hold_elapsed}
	if not keyboard_mode:
		snapshot["controller"] = input_adapter.get_snapshot()
	return snapshot
