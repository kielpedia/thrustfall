extends Node2D
## Draws bullets, missiles and pickups (owned by main), plus debris, exhaust, sparks,
## floating text and team tags.

const Cfg = preload("res://scripts/cfg.gd")

var main
var parts := []   # each: [pos, vel, life, max_life, color, size]
var rings := []   # each: [pos, age, color]
var texts := []   # each: [pos, text, life, color]


func clear() -> void:
	parts.clear()
	rings.clear()
	texts.clear()


func explode(p: Vector2, col: Color, n := 45) -> void:
	main.net.event(["explode", p, col, n])
	for k in n:
		var v := Vector2.RIGHT.rotated(randf() * TAU) * randf_range(30.0, 260.0)
		var c := col if randf() < 0.6 else Color(1.0, 0.85, 0.4)
		var life := randf_range(0.5, 1.4)
		parts.append([p, v, life, life, c, randf_range(2.0, 4.0)])
	rings.append([p, 0.0, col])


func exhaust(p: Vector2, v: Vector2) -> void:
	if parts.size() > 1500 or randf() < 0.4:
		return
	var life := randf_range(0.15, 0.35)
	parts.append([p, v + Vector2(randf_range(-25, 25), randf_range(-25, 25)), life, life, Color(1.0, 0.7, 0.3), 2.0])


func spark(p: Vector2, col: Color, n := 8) -> void:
	main.net.event(["spark", p, col, n])
	for k in n:
		var life := randf_range(0.15, 0.4)
		parts.append([p, Vector2.RIGHT.rotated(randf() * TAU) * randf_range(30, 120), life, life, col, 2.0])


func text(p: Vector2, s: String, col: Color) -> void:
	main.net.event(["text", p, s, col])
	texts.append([p, s, 1.3, col])


func update(dt: float) -> void:
	var keep := []
	for q in parts:
		q[2] -= dt
		if q[2] <= 0.0:
			continue
		q[1].y += main.gravity * 0.6 * dt
		q[1] *= 1.0 - 1.5 * dt
		q[0] += q[1] * dt
		keep.append(q)
	parts = keep
	var keep_r := []
	for r in rings:
		r[1] += dt
		if r[1] < 0.4:
			keep_r.append(r)
	rings = keep_r
	var keep_t := []
	for tx in texts:
		tx[2] -= dt
		tx[0].y -= 20.0 * dt
		if tx[2] > 0.0:
			keep_t.append(tx)
	texts = keep_t
	queue_redraw()


func _label(p: Vector2, s: String, size: int, col: Color) -> void:
	var f: Font = main.font
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(f, p + Vector2(-w / 2.0 + 1, size * 0.35 + 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, col.a * 0.7))
	draw_string(f, p + Vector2(-w / 2.0, size * 0.35), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw() -> void:
	var t: float = main.time
	# pickups: spinning hexagon with an icon letter, blinking before they fade
	for pk in main.pickups:
		var info: Dictionary = Cfg.PU[pk.kind]
		if pk.age > Cfg.PU_LIFE - 3.0 and fmod(pk.age, 0.25) < 0.1:
			continue
		var bob := Vector2(0, sin(t * 3.0 + pk.p.x) * 3.0)
		var c: Vector2 = pk.p + bob
		var hexa := PackedVector2Array()
		for k in 7:
			hexa.append(c + Vector2.RIGHT.rotated(t * 1.5 + k * TAU / 6.0) * 13.0)
		draw_circle(c, 18.0, Color(info.col, 0.12))
		draw_colored_polygon(hexa.slice(0, 6), Color(info.col.darkened(0.7), 0.85))
		draw_polyline(hexa, info.col, 2.0)
		_label(c, info.icon, 14, info.col.lightened(0.3))
	for b in main.bullets:
		var col: Color = main.ships[b.owner].color
		draw_line(b.p - b.v * 0.025, b.p, Color(col, 0.5), 2.0)
		draw_circle(b.p, 2.5, col.lightened(0.4) if b.bounce == 0 else Cfg.PU.bounce.col)
	for m in main.missiles:
		var d: Vector2 = m.v.normalized()
		var col: Color = main.ships[m.owner].color
		draw_line(m.p - d * 7.0, m.p + d * 5.0, col, 4.0)
		draw_circle(m.p + d * 5.0, 2.5, Cfg.PU.missile.col)
	for q in parts:
		var a: float = q[2] / q[3]
		var s: float = q[5]
		draw_rect(Rect2(q[0] - Vector2(s, s) * 0.5, Vector2(s, s)), Color(q[4], a))
	for r in rings:
		var k: float = r[1] / 0.4
		draw_arc(r[0], 8.0 + k * 50.0, 0, TAU, 32, Color(r[2], 1.0 - k), 3.0)
	# team tags above ships
	if main.teams and main.state != "title":
		for s in main.ships:
			if s.alive:
				var tc: Color = Cfg.TEAM_COLORS[s.team]
				_label(s.position + Vector2(0, -24), "AB"[s.team], 13, tc)
	# online guests: mark your own ship for a moment after it spawns
	var mine: int = main.net.my_slot()
	if mine >= 0 and main.state != "title" and main.ships[mine].alive and main.ships[mine].life_t < 2.5:
		var ms = main.ships[mine]
		_label(ms.position + ms.vis_off + Vector2(0, -36 if main.teams else -26), "YOU", 13, Color.WHITE)
	for tx in texts:
		_label(tx[0], tx[1], 14, Color(tx[3], minf(tx[2] * 1.5, 1.0)))
