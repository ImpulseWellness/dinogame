extends CharacterBody2D

enum JumpIntent { RELEASED, GROUND_PENDING, USED, IGNORED_AIRBORNE }

@export_range(0.0, 0.5, 0.01) var max_jump_hold_seconds: float = 0.22
@export var jump_speed: float = -1200.0
@export var gravity: float = 7000.0
@export var held_jump_gravity: float = 2200.0

var jump_intent: JumpIntent = JumpIntent.RELEASED
var jump_held: bool = false
var duck_held: bool = false
var jump_hold_elapsed: float = 0.0
var jump_count: int = 0
var ducking: bool = false
var jump_extension_active: bool = false

func reset_controls() -> void:
	jump_intent = JumpIntent.RELEASED
	jump_held = false
	duck_held = false
	jump_hold_elapsed = 0.0
	jump_count = 0
	jump_extension_active = false
	velocity = Vector2.ZERO
	_update_pose(false)

func synchronize_controls(state: Dictionary) -> void:
	jump_held = state.get("button_1", {}).get("pressed", false)
	duck_held = state.get("button_2", {}).get("pressed", false)
	if jump_held:
		jump_intent = JumpIntent.GROUND_PENDING if is_on_floor() else JumpIntent.IGNORED_AIRBORNE
	else:
		jump_intent = JumpIntent.RELEASED
	_try_jump()
	_update_pose(true)

func apply_controller_frame(state: Dictionary, transitions: Array) -> void:
	for event: Dictionary in transitions:
		var pressed: bool = event["pressed"]
		match event["inputId"]:
			"button_1":
				jump_held = pressed
				if pressed:
					jump_intent = JumpIntent.GROUND_PENDING if is_on_floor() and velocity.y >= 0 else JumpIntent.IGNORED_AIRBORNE
				else:
					jump_intent = JumpIntent.RELEASED
					jump_extension_active = false
			"button_2":
				duck_held = pressed
		_try_jump()
	jump_held = state["button_1"]["pressed"]
	duck_held = state["button_2"]["pressed"]
	_try_jump()

func _try_jump() -> void:
	if jump_intent != JumpIntent.GROUND_PENDING or duck_held or not is_on_floor():
		return
	jump_intent = JumpIntent.USED
	jump_hold_elapsed = 0.0
	jump_extension_active = true
	velocity.y = jump_speed
	jump_count += 1

func advance(delta: float, running: bool) -> void:
	if running:
		_try_jump()
	var acceleration: float = gravity
	if running and jump_extension_active and jump_held and velocity.y < 0.0 and jump_hold_elapsed < max_jump_hold_seconds:
		var held_time: float = minf(delta, max_jump_hold_seconds - jump_hold_elapsed)
		acceleration = (held_jump_gravity * held_time + gravity * (delta - held_time)) / delta
		jump_hold_elapsed += held_time
	velocity.y += acceleration * delta
	move_and_slide()
	_update_pose(running)

func _update_pose(running: bool) -> void:
	ducking = running and is_on_floor() and duck_held and velocity.y >= 0.0
	$RunCol.disabled = ducking
	$DuckCol.disabled = not ducking
	if not running:
		$AnimatedSprite2D.play("idle")
	elif not is_on_floor() or velocity.y < 0.0:
		$AnimatedSprite2D.play("jump")
	elif ducking:
		$AnimatedSprite2D.play("duck")
	else:
		$AnimatedSprite2D.play("run")
