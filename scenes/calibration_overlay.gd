extends Control

@export var radius: float = 120.0
@export var thickness: float = 16.0
@export var segments: int = 60
@export var background_color: Color = Color(0.0, 0.0, 0.0, 0.25)

var progress: float = 0.0
var spin: float = 0.0

func set_progress(value: float) -> void:
	progress = clamp(value, 0.0, 1.0)
	queue_redraw()

func set_spin(value: float) -> void:
	spin = value
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	if radius <= 0.0:
		return

	draw_arc(center, radius, 0.0, TAU, 64, background_color, thickness)

	var total_angle := TAU * progress
	if total_angle <= 0.0:
		return

	var start_angle := -PI * 0.5 + spin
	var segs: int = max(1, segments)
	for i in range(segs):
		var t0 := float(i) / float(segs)
		var t1 := float(i + 1) / float(segs)
		var a0 := start_angle + total_angle * t0
		var a1 := start_angle + total_angle * t1
		var hue := 0.33 * t1
		var col := Color.from_hsv(hue, 0.9, 0.95)
		draw_arc(center, radius, a0, a1, 8, col, thickness)
