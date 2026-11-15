extends Node2D
## Starfield behind the map; re-rolled with each map.

const Cfg = preload("res://scripts/cfg.gd")

var stars := []


func regen(seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	stars.clear()
	for k in 180:
		stars.append([Vector2(rng.randf() * Cfg.W, rng.randf() * Cfg.H), rng.randf_range(0.5, 1.8), rng.randf_range(0.2, 0.9)])
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), Color("070818"))
	for s in stars:
		draw_circle(s[0], s[1], Color(0.8, 0.85, 1.0, s[2]))
