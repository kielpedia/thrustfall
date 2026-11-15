extends Node2D
## A player ship: one rear booster, rotate left/right, fire. Gravity always pulls down.
## Touching rock kills you unless you land gently, upright, feet first.

const Cfg = preload("res://scripts/cfg.gd")
const Hulls = preload("res://scripts/hulls.gd")

var idx := 0
var hull := 0                # cosmetic hull design (hulls.gd)
var main
var color := Color.WHITE
var cname := ""
var team := 0
var vel := Vector2.ZERO
var alive := false
var landed := false
var thrusting := false
var cd := 0.0
var invuln := 0.0            # spawn / just-blocked protection
var shield_up := false       # power-up: absorbs one hit
var missiles := 0            # power-up: next shots are homing missiles
var effects := {}            # timed power-ups: kind -> seconds left
var is_cpu := false
var bot
var t := 0.0
var life_t := 0.0            # seconds since spawn
var sim_only := false        # online guest predicting its own ship: never kills or fires
var quiet := false           # replaying inputs: no exhaust particles
var vis_off := Vector2.ZERO  # drawn offset that smooths out prediction corrections


func fwd() -> Vector2:
	return Vector2(sin(rotation), -cos(rotation))


func has_fx(kind: String) -> bool:
	return effects.get(kind, 0.0) > 0.0


func grav() -> float:
	return Cfg.GRAVITY * (0.3 if has_fx("feather") else 1.0)


## ground = the pad surface point; the ship is placed resting on it.
func spawn(ground: Vector2) -> void:
	position = ground - Vector2(0, Hulls.bottom(hull) + 1.5)
	rotation = 0.0
	vel = Vector2.ZERO
	alive = true
	life_t = 0.0
	landed = true
	thrusting = false
	cd = 0.3
	invuln = Cfg.SPAWN_SHIELD
	shield_up = false
	missiles = 0
	effects.clear()
	visible = true
	queue_redraw()


func give(kind: String) -> void:
	match kind:
		"shield":
			shield_up = true
		"missile":
			missiles = 2
		_:
			effects[kind] = Cfg.PU[kind].time


## Rock contact at position p / rotation r: 0 = none, 1 = only the landing feet, 2 = body.
func hits_at(p: Vector2, r: float) -> int:
	var d := Hulls.hit_data(hull)
	var pts: PackedVector2Array = d[0]
	var feet: PackedByteArray = d[1]
	var res := 0
	for k in pts.size():
		if main.terrain.solid_at(p + pts[k].rotated(r)):
			if feet[k] == 0:
				return 2
			res = 1
	return res


## Does this ship's shape cover world point p (within margin px)?
func contains(p: Vector2, margin := 0.0) -> bool:
	return Hulls.contains(hull, (p - position).rotated(-rotation), margin)


## Outline points in world space.
func world_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in Hulls.hit_data(hull)[0]:
		out.append(position + q.rotated(rotation))
	return out


func step(dt: float, inp: Dictionary) -> void:
	if not alive:
		return
	t += dt
	life_t += dt
	cd -= dt
	invuln -= dt
	for k in effects:
		effects[k] -= dt
	thrusting = inp.thrust
	if landed:
		if thrusting:
			landed = false
		else:
			vel = Vector2.ZERO
			_try_fire(inp)
			queue_redraw()
			return
	rotation = wrapf(rotation + clampf(inp.turn, -1.0, 1.0) * Cfg.TURN * dt, -PI, PI)
	var acc := Vector2(0, grav())
	if thrusting:
		acc += fwd() * Cfg.THRUST
	vel += acc * dt
	vel *= 1.0 - Cfg.DRAG * dt
	if vel.length() > Cfg.MAX_SPEED:
		vel = vel.normalized() * Cfg.MAX_SPEED
	var prev := position
	position += vel * dt
	var hit := hits_at(position, rotation)
	if hit != 0:
		if hit == 1 and vel.length() < Cfg.LAND_SPEED and absf(rotation) < Cfg.LAND_ANGLE:
			_settle(prev)
		elif sim_only:
			position = prev   # the host decides whether we crashed
			vel = Vector2.ZERO
			return
		else:
			main.kill(self, -1)
			return
	_try_fire(inp)
	if thrusting and not quiet:
		main.fx.exhaust(position - fwd() * 9.0, vel - fwd() * 120.0)
	queue_redraw()


## Touched down softly: back off to the last free spot and park there.
func _settle(prev: Vector2) -> void:
	var lo := prev
	var hi := position
	var k := 0
	while hits_at(lo, rotation) != 0 and k < 10:
		lo.y -= 1.0
		k += 1
	for i in 8:
		var mid := lo.lerp(hi, 0.5)
		if hits_at(mid, rotation) != 0:
			hi = mid
		else:
			lo = mid
	position = lo
	vel = Vector2.ZERO
	landed = true


func _try_fire(inp: Dictionary) -> void:
	if sim_only:
		return
	if inp.fire and cd <= 0.0:
		cd = Cfg.FIRE_CD * (0.35 if has_fx("rapid") else 1.0)
		main.fire(self)


func _draw() -> void:
	if vis_off != Vector2.ZERO:
		draw_set_transform(vis_off.rotated(-rotation))
	if thrusting:
		var fy := Hulls.flame_y(hull)
		var L := 10.0 + 4.0 * sin(t * 60.0) + randf() * 3.0
		draw_colored_polygon(PackedVector2Array([Vector2(-4, fy), Vector2(4, fy), Vector2(0, fy + L)]), Color(1.0, 0.6, 0.15))
		draw_colored_polygon(PackedVector2Array([Vector2(-2, fy), Vector2(2, fy), Vector2(0, fy + L * 0.6)]), Color(1.0, 0.95, 0.6))
	Hulls.draw(self, hull, Vector2.ZERO, color)
	if missiles > 0:
		draw_line(Vector2(-10, 2), Vector2(-10, 9), Cfg.PU.missile.col, 2.0)
		draw_line(Vector2(10, 2), Vector2(10, 9), Cfg.PU.missile.col, 2.0)
	if shield_up:
		draw_arc(Vector2.ZERO, 16.0, 0, TAU, 28, Color(Cfg.PU.shield.col, 0.55 + 0.25 * sin(t * 6.0)), 2.0)
	if invuln > 0.0 and fmod(invuln, 0.2) < 0.12:
		draw_arc(Vector2.ZERO, 15.0, 0, TAU, 24, Color(color, 0.7), 1.5)
