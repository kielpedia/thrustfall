extends RefCounted
## CPU pilot. Follows a flow field toward the nearest enemy, pushes away from walls,
## and switches to a short "aim" burst when it has a clear shot.

const Cfg = preload("res://scripts/cfg.gd")

var ship
var main
var rng := RandomNumberGenerator.new()
var flow := PackedInt32Array()
var flow_t := 0.0
var target = null
var goal_pickup = null      # pickup we're detouring for, if any
var mode := "fly"
var mode_t := 0.0
var aim_noise := 0.0
var noise_t := 0.0


func _init(s, m) -> void:
	ship = s
	main = m
	rng.randomize()
	mode_t = rng.randf_range(0.3, 1.0)


func think(dt: float) -> Dictionary:
	var out := {"turn": 0.0, "thrust": false, "fire": false}
	var t = main.terrain
	var pos: Vector2 = ship.position

	flow_t -= dt
	if flow_t <= 0.0 or target == null or not target.alive:
		target = _pick_target()
		goal_pickup = _near_pickup(pos)
		if goal_pickup != null and target != null and pos.distance_to(goal_pickup.p) > pos.distance_to(target.position) * 0.8:
			goal_pickup = null
		if goal_pickup != null:
			flow = t.flow_to(goal_pickup.p)
		elif target != null:
			flow = t.flow_to(target.position)
		flow_t = rng.randf_range(0.25, 0.4)
	if goal_pickup != null and not main.pickups.has(goal_pickup):
		goal_pickup = null
		flow_t = 0.0

	mode_t -= dt
	var los: bool = target != null and t.clear_line(pos, target.position)
	var dist: float = pos.distance_to(target.position) if target != null else 1e9
	var safe := _safe()
	if mode == "fly":
		if mode_t <= 0.0 and los and dist < 480.0 and safe:
			mode = "aim"
			mode_t = rng.randf_range(0.6, 1.1)
	elif mode_t <= 0.0 or not los or not safe:
		mode = "fly"
		mode_t = rng.randf_range(0.3, 0.7)

	if mode == "aim":
		_aim(out, dt)
	else:
		_fly(out, los, dist)
	return out


func _pick_target():
	var best = null
	var bd := 1e9
	for s in main.ships:
		if not s.alive or not main.is_enemy(ship, s):
			continue
		var d: float = ship.position.distance_to(s.position)
		if d < bd:
			bd = d
			best = s
	return best


func _near_pickup(pos: Vector2):
	var best = null
	var bd := 380.0
	for pk in main.pickups:
		var d := pos.distance_to(pk.p)
		if d < bd:
			bd = d
			best = pk
	return best


func _safe() -> bool:
	var t = main.terrain
	var v: Vector2 = ship.vel
	if v.y > 80.0 or v.length() > 200.0 or ship.landed:
		return false
	if t.clearance_at(ship.position) < 3:
		return false
	if t.ray_dist(ship.position, Vector2.DOWN, 70.0) < 70.0:
		return false
	if v.length() > 10.0:
		var look := v.length() * 0.7 + 20.0
		if t.ray_dist(ship.position, v.normalized(), look) < look:
			return false
	return true


func _fly(out: Dictionary, los: bool, dist: float) -> void:
	var t = main.terrain
	var pos: Vector2 = ship.position
	var vel: Vector2 = ship.vel
	var vd := Vector2.ZERO
	if goal_pickup != null and flow.size() > 0:
		var gp: Vector2 = goal_pickup.p
		var wp: Vector2 = gp if pos.distance_to(gp) < 120.0 and t.clear_line(pos, gp) else t.flow_waypoint(pos, flow, 4)
		if wp.distance_to(pos) > 1.0:
			vd = (wp - pos).normalized() * 150.0
	elif target != null and flow.size() > 0:
		if los and dist < 240.0:
			vd = (pos - target.position).normalized() * 50.0   # too close, back off a little
		else:
			var wp: Vector2 = t.flow_waypoint(pos, flow, 4)
			if wp.distance_to(pos) > 1.0:
				vd = (wp - pos).normalized() * 150.0
	# keep clear of other ships (teammates especially)
	for s in main.ships:
		if s != ship and s.alive:
			var off: Vector2 = pos - s.position
			if off.length() < 70.0:
				vd += off.normalized() * (70.0 - off.length()) * 3.0
	# push away from nearby rock
	var rep := Vector2.ZERO
	for k in 12:
		var d := Vector2.RIGHT.rotated(TAU * k / 12.0)
		var h: float = t.ray_dist(pos, d, 70.0)
		if h < 70.0:
			rep -= d * (1.0 - h / 70.0)
	vd += rep * 220.0
	# never climb faster than gravity can stop us before the rock overhead
	# (straight up only: angled rays would hit the sides of every vertical shaft)
	# Only matters in low gravity; at normal gravity the old, bolder climbing is fine.
	if ship.grav() < Cfg.GRAVITY * 0.9:
		var head: float = t.ray_dist(pos, Vector2.UP, 240.0)
		var max_up := sqrt(2.0 * ship.grav() * maxf(head - 28.0, 0.0)) + 25.0
		vd.y = maxf(vd.y, -max_up)
	# about to hit something: brake
	if vel.length() > 10.0:
		var look := vel.length() * 0.8 + 20.0
		if vel.y < 0.0:
			# rising: in low gravity it takes much longer to stop, so look further up
			look = maxf(look, vel.y * vel.y / (2.0 * ship.grav()) + 25.0)
		if t.ray_dist(pos, vel.normalized(), look) < look:
			vd -= vel * 0.8
	_steer(out, vd)


## Turn and thrust so velocity moves toward vd, fighting gravity.
func _steer(out: Dictionary, vd: Vector2) -> void:
	var a: Vector2 = (vd - ship.vel) * 2.2
	var g: float = ship.grav()
	a.y -= g
	# point the nose as if gravity were near normal: in low gravity this stops the
	# bot tipping far over (and scraping rock) to chase small sideways corrections
	var want := a
	var g_feel := maxf(g, Cfg.GRAVITY * 0.8)
	want.y -= g_feel - g
	if a.y > 0.0:
		# wants to go down faster than gravity alone: just coast upright-ish
		want = Vector2(a.x * 0.3, -60.0)
	var ta := atan2(want.x, -want.y)
	var err := wrapf(ta - ship.rotation, -PI, PI)
	out.turn = clampf(err * 5.0, -1.0, 1.0)
	out.thrust = a.y <= 0.0 and absf(err) < 0.6 and ship.fwd().dot(a) > g_feel * 0.6


func _aim(out: Dictionary, dt: float) -> void:
	var pos: Vector2 = ship.position
	var vel: Vector2 = ship.vel
	var tp: Vector2 = target.position
	var tt := pos.distance_to(tp) / Cfg.BULLET_SPEED
	var aim: Vector2 = tp + target.vel * tt - vel * tt
	aim.y -= 0.5 * main.gravity * Cfg.BULLET_GRAV * tt * tt
	noise_t -= dt
	if noise_t <= 0.0:
		aim_noise = rng.randf_range(-0.07, 0.07)
		noise_t = 0.4
	var ta := atan2(aim.x - pos.x, -(aim.y - pos.y)) + aim_noise
	var err := wrapf(ta - ship.rotation, -PI, PI)
	out.turn = clampf(err * 6.0, -1.0, 1.0)
	out.thrust = vel.y > 30.0 and ship.fwd().y < -0.5
	out.fire = absf(err) < 0.1 and main.terrain.clear_line(pos + ship.fwd() * 14.0, tp)
