extends SceneTree

var game: Node
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.max_fps = 0
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.obstacles_enabled = false
	await _reset()
	var short_height: float = await _jump_height(1)
	await _reset()
	var long_height: float = await _jump_height(-1)
	_check(long_height > short_height + 60.0, "Longer contraction increases actual jump height", {"short": short_height, "long": long_height})
	_check(game.get_node("Dino").jump_count == 1, "Holding through landing cannot repeat a jump")
	_check(absf(game.get_snapshot()["jumpHoldSeconds"] - 0.22) < 0.0001, "Long contraction reaches the configured hold limit")

	await _reset()
	_button("ui_down", true)
	await _ticks(1)
	_button("ui_accept", true)
	await _ticks(20)
	_check(game.get_snapshot()["ducking"] and game.get_snapshot()["jumpCount"] == 0, "Duck blocks a held jump on the ground")
	_button("ui_down", false)
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 1 and game.get_snapshot()["velocityY"] < -1000.0, "Releasing duck launches the unused held jump")
	_check(game.get_snapshot()["jumpHoldSeconds"] <= 0.034, "Deferred jump hold timer starts at takeoff")
	await _ticks(90)
	_check(game.get_snapshot()["jumpCount"] == 1, "Deferred held jump does not repeat after landing")

	await _reset()
	_button("ui_down", true)
	_button("ui_accept", true)
	_button("ui_accept", false)
	await _ticks(1)
	_button("ui_down", false)
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 0 and game.get_snapshot()["grounded"], "A released jump blocked by duck cannot launch later")

	await _reset()
	_button("ui_accept", true)
	await _ticks(3)
	_button("ui_accept", false)
	await _ticks(2)
	_button("ui_accept", true)
	await _ticks(90)
	_check(game.get_snapshot()["grounded"] and game.get_snapshot()["jumpCount"] == 1, "A new airborne press cannot jump on landing")
	_button("ui_accept", false)
	await _ticks(1)
	_button("ui_accept", true)
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 2, "A fresh grounded press can jump after the ignored airborne press")

	await _reset()
	var flight_without_duck: Array = await _flight(false, false)
	await _reset()
	var flight_with_duck: Array = await _flight(true, false)
	_check(flight_with_duck == flight_without_duck, "Airborne duck leaves the entire jump trajectory unchanged")
	_check(game.get_snapshot()["ducking"], "Held airborne duck applies on landing")
	await _reset()
	await _flight(true, true)
	_check(not game.get_snapshot()["ducking"] and game.get_snapshot()["grounded"], "Released airborne duck lands running")

	await _reset()
	_button("ui_accept", true)
	_button("ui_accept", false)
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 1 and game.get_snapshot()["velocityY"] < -1000.0, "A press and release between physics frames still jumps")

	await _reset()
	game.pause_game("Input unavailable. disconnected.")
	var paused_x: float = game.get_snapshot()["x"]
	var paused_score: float = game.score
	_button("ui_accept", true)
	await _ticks(10)
	_check(game.get_snapshot()["x"] == paused_x and game.score == paused_score and game.get_snapshot()["jumpCount"] == 0, "Input loss pauses motion and discards paused button history")
	game.resume_game()
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 1 and game.game_running, "Manual resume applies current held jump immediately")
	game.pause_game()
	var held_seconds: float = game.get_snapshot()["jumpHoldSeconds"]
	await _ticks(30)
	_check(game.get_snapshot()["jumpHoldSeconds"] == held_seconds, "Pause duration cannot extend the jump hold timer")
	await _reset()
	game.pause_game()
	_button("ui_down", true)
	_button("ui_accept", true)
	await _ticks(2)
	game.resume_game()
	await _ticks(1)
	_check(game.get_snapshot()["ducking"] and game.get_snapshot()["jumpCount"] == 0, "Manual resume applies held duck with jump still pending")
	_button("ui_down", false)
	await _ticks(1)
	_check(game.get_snapshot()["jumpCount"] == 1, "A resume-time held jump launches after duck releases")

	await _reset()
	game.set_physics_process(false)
	var start_x: float = game.get_snapshot()["x"]
	for step in range(30):
		game.advance_game(1.0 / 30.0)
	var at_30: float = game.get_snapshot()["x"] - start_x
	game.new_game()
	game.resume_game()
	start_x = game.get_snapshot()["x"]
	for step in range(60):
		game.advance_game(1.0 / 60.0)
	var at_60: float = game.get_snapshot()["x"] - start_x
	_check(absf(at_30 - 960.0) < 0.01 and absf(at_60 - 960.0) < 0.01 and absf(game.score - 960.0) < 0.01, "Horizontal motion and score use elapsed gameplay time", {"30hz": at_30, "60hz": at_60, "score": game.score})
	print("DINO_GAMEPLAY_RESULT " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _reset() -> void:
	_button("ui_accept", false)
	_button("ui_down", false)
	await _ticks(1)
	game.new_game()
	game.resume_game()
	await _ticks(2)

func _button(action: String, pressed: bool) -> void:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)

func _ticks(count: int) -> void:
	for frame in range(count):
		await physics_frame
		await process_frame

func _jump_height(held_frames: int) -> float:
	var initial_y: float = game.get_snapshot()["y"]
	var min_y: float = initial_y
	_button("ui_accept", true)
	for frame in range(90):
		if frame == held_frames:
			_button("ui_accept", false)
		await _ticks(1)
		min_y = minf(min_y, game.get_snapshot()["y"])
	return initial_y - min_y

func _flight(duck: bool, release_duck: bool) -> Array:
	_button("ui_accept", true)
	var positions: Array = []
	for frame in range(60):
		if frame == 6 and duck:
			_button("ui_down", true)
		if frame == 9:
			_button("ui_accept", false)
		if frame == 12 and release_duck:
			_button("ui_down", false)
		await _ticks(1)
		positions.append(snappedf(game.get_snapshot()["y"], 0.001))
	return positions

func _check(passed: bool, message: String, detail: Dictionary = {}) -> void:
	checks += 1
	print(("PASS " if passed else "FAIL ") + message + (" " + JSON.stringify(detail) if not detail.is_empty() else ""))
	if not passed:
		failures.append(message)
