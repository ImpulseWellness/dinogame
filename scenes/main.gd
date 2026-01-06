extends Node

#preload obstacles
var stump_scene = preload("res://scenes/stump.tscn")
var rock_scene = preload("res://scenes/rock.tscn")
var barrel_scene = preload("res://scenes/barrel.tscn")
var bird_scene = preload("res://scenes/bird.tscn")
var obstacle_types := [stump_scene, rock_scene, barrel_scene]
var obstacles : Array
var bird_heights := [275, 390]

#game variables
const DINO_START_POS := Vector2i(150, 485)
const CAM_START_POS := Vector2i(576, 324)
var difficulty
const MAX_DIFFICULTY : int = 2
var score : int
const SCORE_MODIFIER : int = 10
var high_score : int
var speed : float 
const START_SPEED : float = 16
const MAX_SPEED : int = 16
const SPEED_MODIFIER : int = 2500
var screen_size : Vector2i
var ground_height : int
var game_running : bool
var last_obs

const CALIBRATION_DURATION : float = 3.0
var calibrating : bool = false
var calibration_elapsed : float = 0.0
var calibration_max_rms : float = 0.0
const COUNTDOWN_DURATION : float = 3.0
var countdown_active : bool = false
var countdown_remaining : float = 0.0


# Called when the node enters the scene tree for the first time.
func _ready():
	screen_size = get_window().size
	ground_height = $Ground.get_node("Sprite2D").texture.get_height()
	$GameOver.get_node("Button").pressed.connect(new_game)
	new_game()
	#$HTTPRequest.start()


func new_game():
	#reset variables
	score = 0
	show_score()
	game_running = false
	get_tree().paused = false
	difficulty = 1
	
	#delete all obstacles
	for obs in obstacles:
		obs.queue_free()
	obstacles.clear()
	
	#reset the nodes
	$Dino.position = DINO_START_POS
	$Dino.velocity = Vector2i(0, 0)
	$Camera2D.position = CAM_START_POS
	$Ground.position = Vector2i(0, 0)
	
	#reset hud and game over screen
	$HUD.get_node("StartLabel").hide()
	$HUD.get_node("CountdownLabel").hide()
	$GameOver.hide()
	start_calibration()

func start_calibration():
	calibrating = true
	calibration_elapsed = 0.0
	calibration_max_rms = 0.0
	countdown_active = false
	countdown_remaining = 0.0
	var overlay = $HUD.get_node("CalibrationOverlay")
	overlay.visible = true
	overlay.set_progress(0.0)
	overlay.set_spin(0.0)
	$HTTPRequest.rmsInstance.reset_all()
	
func start_countdown():
	countdown_active = true
	countdown_remaining = COUNTDOWN_DURATION
	var countdown_label = $HUD.get_node("CountdownLabel")
	countdown_label.text = str(int(COUNTDOWN_DURATION))
	countdown_label.show()

func update_rms_ui():
	var latest_rms = $HTTPRequest.rmsInstance.latest_rms_value()
	var target = $HTTPRequest.rmsInstance.threshold
	var label = $HUD.get_node("RMSPanel/RMSLabel")
	var bar = $HUD.get_node("RMSPanel/RMSBar")
	label.text = "RMS: " + str(snappedf(latest_rms, 0.01)) + " / Target: " + str(snappedf(target, 0.01))
	bar.max_value = max(0.01, target)
	bar.value = latest_rms

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	update_rms_ui()
	if calibrating:
		calibration_elapsed += delta
		var progress = min(calibration_elapsed / CALIBRATION_DURATION, 1.0)
		var overlay = $HUD.get_node("CalibrationOverlay")
		overlay.set_progress(progress)
		overlay.set_spin(progress * TAU)
		var latest_rms = $HTTPRequest.rmsInstance.latest_rms_value()
		if latest_rms > calibration_max_rms:
			calibration_max_rms = latest_rms

		if calibration_elapsed >= CALIBRATION_DURATION:
			calibrating = false
			overlay.visible = false
			if calibration_max_rms > 0.0:
				$HTTPRequest.rmsInstance.threshold = calibration_max_rms * 0.2
			start_countdown()
	elif countdown_active:
		countdown_remaining -= delta
		var display = max(1, int(ceil(countdown_remaining)))
		var countdown_label = $HUD.get_node("CountdownLabel")
		countdown_label.text = str(display)
		if countdown_remaining <= 0.0:
			countdown_active = false
			countdown_label.hide()
			game_running = true
			$HUD.get_node("StartLabel").hide()
	elif game_running:
		#speed up and adjust difficulty
		speed = START_SPEED + score / SPEED_MODIFIER
		if speed > MAX_SPEED:
			speed = MAX_SPEED
		adjust_difficulty()
		
		#generate obstacles
		generate_obs()
		
		#move dino and camera
		$Dino.position.x += speed
		$Camera2D.position.x += speed
		
		#update score
		score += speed
		show_score()
		
		#update ground position
		if $Camera2D.position.x - $Ground.position.x > screen_size.x * 1.5:
			$Ground.position.x += screen_size.x
				
		#remove obstacles that have gone off screen
		for obs in obstacles:
			if obs.position.x < ($Camera2D.position.x - screen_size.x):
				remove_obs(obs)
	else:
		pass

func generate_obs():
	#generate ground obstacles
	#if obstacles.is_empty() or last_obs.position.x < score + randi_range(300, 500):
	if obstacles.is_empty() or last_obs.position.x < score + randi_range(50, 300):

		var obs_type = obstacle_types[randi() % obstacle_types.size()]
		var obs
		var max_obs = difficulty + 1
		for i in range(randi() % max_obs + 1):
			obs = obs_type.instantiate()
			var obs_height = obs.get_node("Sprite2D").texture.get_height()
			var obs_scale = obs.get_node("Sprite2D").scale
			var obs_x : int = screen_size.x + score + 100 + (i * 100)
			var obs_y : int = screen_size.y - ground_height - (obs_height * obs_scale.y / 2) + 5
			last_obs = obs
			add_obs(obs, obs_x, obs_y)

func add_obs(obs, x, y):
	obs.position = Vector2i(x, y)
	obs.body_entered.connect(hit_obs)
	add_child(obs)
	obstacles.append(obs)

func remove_obs(obs):
	obs.queue_free()
	obstacles.erase(obs)
	
func hit_obs(body):
	if body.name == "Dino":
		game_over()

func show_score():
	$HUD.get_node("ScoreLabel").text = "SCORE: " + str(score / SCORE_MODIFIER)

func check_high_score():
	if score > high_score:
		high_score = score
		$HUD.get_node("HighScoreLabel").text = "HIGH SCORE: " + str(high_score / SCORE_MODIFIER)

func adjust_difficulty():
	difficulty = 1

func game_over():
	check_high_score()
	get_tree().paused = true
	game_running = false
	new_game()
