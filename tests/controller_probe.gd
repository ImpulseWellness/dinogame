extends SceneTree

var game: Node
var started_at_us: int
var next_snapshot_us: int = 0
var plan: Dictionary = {"durationSeconds": 10.0, "steps": []}
var step_index: int = 0

func _initialize() -> void:
	_start.call_deferred()

func _start() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--probe-plan="):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(argument.trim_prefix("--probe-plan=")))
			if not parsed is Dictionary:
				push_error("Probe plan must be a JSON object")
				quit(2)
				return
			plan = parsed
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.obstacles_enabled = false
	started_at_us = Time.get_ticks_usec()
	process_frame.connect(_observe)
	print("DINO_PROBE_READY")

func _observe() -> void:
	var elapsed_us: int = Time.get_ticks_usec() - started_at_us
	var steps: Array = plan.get("steps", [])
	while step_index < steps.size() and elapsed_us >= int(float(steps[step_index]["atSeconds"]) * 1000000.0):
		var step: Dictionary = steps[step_index]
		match step["action"]:
			"resume":
				game.resume_game()
			"pause":
				game.pause_game()
			"retry":
				game.new_game()
		print("DINO_PROBE_ACTION " + JSON.stringify(step))
		step_index += 1
	if elapsed_us >= next_snapshot_us:
		var snapshot: Dictionary = game.get_snapshot()
		snapshot["elapsedUs"] = elapsed_us
		print("DINO_PROBE " + JSON.stringify(snapshot))
		next_snapshot_us = elapsed_us + 50000
	if elapsed_us >= int(float(plan.get("durationSeconds", 10.0)) * 1000000.0):
		quit()
