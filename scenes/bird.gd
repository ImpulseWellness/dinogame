extends Area2D


func _physics_process(delta):
	if get_parent().game_running:
		position.x -= get_parent().speed * delta / 2.0
