extends Node2D
## Game root: builds the scene, runs the fixed-step simulation and the round flow.
##
##   cfg.gd       tuning constants (gravity, thrust, bullets, colors, power-ups)
##   controls.gd  keyboard + gamepad bindings for 4 slots
##   terrain.gd   random map generator, collision queries, bot pathing
##   ship.gd      ship physics, landing/crashing, power-up effects, drawing
##   bot.gd       CPU pilot
##   fx.gd, bg.gd, hud.gd  visuals (hud also holds the clickable title menu)
##
## Run headless self-test:  godot --headless --path . -- --autotest
## Watch CPUs play:         godot --path . -- --demo   (add --teams for a team match)

const Cfg = preload("res://scripts/cfg.gd")
const Controls = preload("res://scripts/controls.gd")
const TerrainScript = preload("res://scripts/terrain.gd")
const ShipScript = preload("res://scripts/ship.gd")
const BotScript = preload("res://scripts/bot.gd")
const FxScript = preload("res://scripts/fx.gd")
const BgScript = preload("res://scripts/bg.gd")
const HudScript = preload("res://scripts/hud.gd")
const Hulls = preload("res://scripts/hulls.gd")
const NetScript = preload("res://scripts/net.gd")

const DT := 1.0 / 120.0

var font: SystemFont
var world: Node2D
var bg
var terrain
var fx
var hud
var ships := []
var bullets := []    # {p, v, owner, team, age, bounce}
var missiles := []   # {p, v, owner, team, age}
var pickups := []    # {p, kind, age}
var pu_timer := 0.0

# lobby settings
var slots := [
	{"type": "human", "color": 0, "team": 0, "hull": 0},
	{"type": "cpu", "color": 5, "team": 1, "hull": 5},
	{"type": "cpu", "color": 2, "team": 0, "hull": 7},
	{"type": "cpu", "color": 3, "team": 1, "hull": 3},
]
var teams := false
var powerups := true
var friendly_fire := false
var game_mode := "rounds"   # rounds: last ship standing per round · stock: lives + respawns · timed: most kills
var win_rounds := 5
var stock_lives := 3
var time_limit := 180.0
const GAME_MODES := ["rounds", "stock", "timed"]
const ROUND_OPTS := [3, 5, 7]
const STOCK_OPTS := [1, 3, 5, 10]
const TIME_OPTS := [60.0, 120.0, 180.0, 300.0]
const RESPAWN_DELAY := 2.0

# respawn-mode state
var lives := [0, 0, 0, 0]
var points := [0, 0, 0, 0]       # kills minus crashes / self-kills / team-kills
var respawn_t := [0.0, 0.0, 0.0, 0.0]
var match_t := 0.0
var overtime := false
var matches_done := 0

var state := "title"     # title, countdown, play, round_end, match_end
var timer := 0.0
var scores := [0, 0, 0, 0]
var team_scores := [0, 0]
var kills := [0, 0, 0, 0]
var round_n := 0
var round_t := 0.0
var msg := ""
var msg_col := Color.WHITE
var awarded := false
var timed_out := false
var shake := 0.0
var time := 0.0
var autotest := false
var demo := false
var rng := RandomNumberGenerator.new()
var stats := {}
var net
var ip_edit: LineEdit
var map_seed := 0
var map_pads := 0
var map_hash := 0
var next_id := 0
var autotest_bot = null   # --netjoin test: a CPU flies the client's ship


func _ready() -> void:
	Controls.setup()
	rng.randomize()
	_reset_stats()
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "Arial", "Sans-Serif"])
	font.font_weight = 800

	world = Node2D.new()
	add_child(world)
	bg = BgScript.new()
	world.add_child(bg)
	terrain = TerrainScript.new()
	world.add_child(terrain)
	for i in 4:
		var s = ShipScript.new()
		s.idx = i
		s.main = self
		s.visible = false
		world.add_child(s)
		ships.append(s)
	fx = FxScript.new()
	fx.main = self
	world.add_child(fx)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = HudScript.new()
	hud.main = self
	layer.add_child(hud)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "host address"
	ip_edit.position = Vector2(300, 515)
	ip_edit.size = Vector2(190, 54)
	ip_edit.add_theme_font_size_override("font_size", 18)
	ip_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(ip_edit)

	net = NetScript.new()
	net.name = "Net"
	net.main = self
	add_child(net)
	ip_edit.text = net.last_ip
	ip_edit.text_submitted.connect(func(t): ip_edit.release_focus(); net.join(t))

	var args := OS.get_cmdline_user_args()
	var li := args.find("--lag")
	if li >= 0 and li + 1 < args.size():
		net.lag = float(args[li + 1])
	if "--nethost" in args or "--netjoin" in args:
		_net_test(args)
	elif "--autotest" in args:
		_autotest()
	elif "--demo" in args or "--shot" in args:
		demo = true
		for s in slots:
			s.type = "cpu"
		teams = "--teams" in args
		for m in GAME_MODES:
			if ("--" + m) in args:
				game_mode = m
		if "--early" in args:
			for k in 4:
				slots[k].hull = [2, 6, 9, 4][k]   # lander, brick, saucer, needle
		if "--title" in args:
			slots[0].type = "human"
			_balance_teams()
			_new_map(4)
		else:
			start_match()
		if "--shot" in args:
			# save a screenshot a few seconds into a CPU match, then quit
			await get_tree().create_timer(1.0 if "--early" in args else 9.0).timeout
			get_viewport().get_texture().get_image().save_png("user://shot.png")
			print("SHOT ", ProjectSettings.globalize_path("user://shot.png"), " hulls=", slots.map(func(s): return s.hull))
			get_tree().quit()
	else:
		_new_map(4)


func _reset_stats() -> void:
	stats = {"rounds": 0, "wins": 0, "draws": 0, "timeouts": 0, "shot": 0, "crash": 0, "collide": 0,
			"map_fail": 0, "round_time": 0.0, "pickups": 0, "missile_kills": 0, "blocks": 0, "ricochets": 0}


func _physics_process(delta: float) -> void:
	if net.is_client():
		net.client_tick(delta)
	elif not autotest:
		step(delta)


func ip_has_focus() -> bool:
	return ip_edit.has_focus()


func _process(_delta: float) -> void:
	world.position = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake if shake > 0.3 else Vector2.ZERO
	ip_edit.visible = state == "title" and not net.online() and not autotest
	if state == "title" and not autotest and not ip_edit.has_focus():
		# players use their own turn keys to pick a color, fire to switch team
		for i in 4:
			var keys := i   # which local key set drives this seat
			if net.is_client():
				if i != net.my_slot():
					continue
				keys = 0     # online you always use the P1 keys / first pad
			elif slots[i].type != "human":
				continue
			if Input.is_action_just_pressed("p%d_left" % keys):
				menu_action("color:%d:-1" % i)
			if Input.is_action_just_pressed("p%d_right" % keys):
				menu_action("color:%d:1" % i)
			if Input.is_action_just_pressed("p%d_thrust" % keys):
				menu_action("hull:%d:1" % i)
			if teams and Input.is_action_just_pressed("p%d_fire" % keys):
				menu_action("team:%d" % i)
	hud.queue_redraw()


func _unhandled_input(e: InputEvent) -> void:
	if autotest:
		return
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		ip_edit.release_focus()
		var mp: Vector2 = hud.get_local_mouse_position()
		for b in hud.buttons:
			if b[0].has_point(mp):
				menu_action(b[1])
				return
		return
	if e.is_action_pressed("start"):
		if net.is_client():
			return
		if state == "title":
			menu_action("start")
		elif state == "match_end":
			start_match()
	elif e.is_action_pressed("back"):
		if net.is_client():
			net.leave("You left the game.")
		elif state != "title":
			go_title()
	elif state == "title":
		if e is InputEventKey and e.pressed and not e.echo:
			var k: int = e.physical_keycode
			if k >= KEY_1 and k <= KEY_4:
				menu_action("type:%d" % (k - KEY_1))
			elif k == KEY_T:
				menu_action("teams")
			elif k == KEY_M:
				menu_action("game")
			elif k == KEY_V:
				menu_action("value")
			elif k == KEY_P:
				menu_action("pu")
			elif k == KEY_F:
				menu_action("ff")
		elif e is InputEventJoypadButton and e.pressed and e.button_index == JOY_BUTTON_A and e.device < 4 and not net.is_client():
			if slots[e.device].type in ["cpu", "off"]:
				slots[e.device].type = "human"
				_fix_color(e.device)


# ---------------------------------------------------------------- lobby

## remote = the host is applying a request from an online player (already checked).
func menu_action(a: String, remote := false) -> void:
	var p := a.split(":")
	if p[0] in ["host", "join", "leave"]:
		match p[0]:
			"host":
				net.host()
			"join":
				net.join(ip_edit.text)
			"leave":
				net.leave("")
		return
	if net.is_client():
		# online guests may only change their own color / ship / team; the host does the rest
		if p.size() >= 2 and p[0] in ["color", "hull", "team"] and int(p[1]) == net.my_slot():
			net.request(a)
		return
	if not remote and p.size() >= 2 and p[0] in ["color", "hull", "team", "type"] and slots[int(p[1])].type == "net":
		return   # that seat belongs to an online player
	match p[0]:
		"type":
			var i := int(p[1])
			slots[i].type = {"human": "cpu", "cpu": "off", "off": "human"}[slots[i].type]
			if slots[i].type != "off":
				_fix_color(i)
		"color":
			_cycle_color(int(p[1]), int(p[2]))
		"hull":
			var i := int(p[1])
			slots[i].hull = posmod(slots[i].hull + int(p[2]), Hulls.count())
		"team":
			var i := int(p[1])
			slots[i].team = 1 - slots[i].team
		"game":
			game_mode = GAME_MODES[(GAME_MODES.find(game_mode) + 1) % GAME_MODES.size()]
		"value":
			match game_mode:
				"rounds":
					win_rounds = ROUND_OPTS[(ROUND_OPTS.find(win_rounds) + 1) % ROUND_OPTS.size()]
				"stock":
					stock_lives = STOCK_OPTS[(STOCK_OPTS.find(stock_lives) + 1) % STOCK_OPTS.size()]
				"timed":
					time_limit = TIME_OPTS[(TIME_OPTS.find(time_limit) + 1) % TIME_OPTS.size()]
		"teams":
			teams = not teams
			if teams:
				_balance_teams()
		"pu":
			powerups = not powerups
		"ff":
			friendly_fire = not friendly_fire
		"start":
			if start_problem() == "":
				start_match()


func _color_taken(c: int, i: int) -> bool:
	for j in 4:
		if j != i and slots[j].type != "off" and slots[j].color == c:
			return true
	return false


func _cycle_color(i: int, d: int) -> void:
	var n := Cfg.PALETTE.size()
	var c: int = slots[i].color
	for k in n:
		c = posmod(c + d, n)
		if not _color_taken(c, i):
			slots[i].color = c
			return


func _fix_color(i: int) -> void:
	if _color_taken(slots[i].color, i):
		_cycle_color(i, 1)


func _balance_teams() -> void:
	var count := [0, 0]
	for s in slots:
		if s.type != "off":
			count[s.team] += 1
	if count[0] == 0 or count[1] == 0:
		var t := 0
		for s in slots:
			if s.type != "off":
				s.team = t
				t = 1 - t


func active_count() -> int:
	var n := 0
	for s in slots:
		if s.type != "off":
			n += 1
	return n


## Why the match can't start yet, or "" if it can.
func start_problem() -> String:
	if active_count() < 2:
		return "Need at least 2 ships"
	if teams:
		var count := [0, 0]
		for s in slots:
			if s.type != "off":
				count[s.team] += 1
		if count[0] == 0 or count[1] == 0:
			return "Both teams need a ship"
	return ""


## Short text for the current mode's setting, e.g. "FIRST TO 5", "3 LIVES", "3:00".
func rule_label() -> String:
	match game_mode:
		"stock":
			return "1 LIFE" if stock_lives == 1 else "%d LIVES" % stock_lives
		"timed":
			return clock(time_limit)
	return "FIRST TO %d" % win_rounds


func clock(sec: float) -> String:
	var t := ceili(maxf(sec, 0.0))
	return "%d:%02d" % [t / 60, t % 60]


func is_enemy(a, b) -> bool:
	return a != b and (not teams or a.team != b.team)


# ---------------------------------------------------------------- round flow

func go_title() -> void:
	state = "title"
	msg = ""
	bullets.clear()
	missiles.clear()
	pickups.clear()
	fx.clear()
	for s in ships:
		s.alive = false
		s.visible = false
	_new_map(4)
	if net.is_host():
		net.seat_waiting()


func start_match() -> void:
	scores = [0, 0, 0, 0]
	team_scores = [0, 0]
	kills = [0, 0, 0, 0]
	lives = [stock_lives, stock_lives, stock_lives, stock_lives]
	points = [0, 0, 0, 0]
	respawn_t = [0.0, 0.0, 0.0, 0.0]
	match_t = time_limit
	overtime = false
	round_n = 0
	_next_round()


func _new_map(n: int) -> void:
	var seed := rng.randi()
	if not terrain.generate(seed, maxi(n, 2)):
		stats.map_fail += 1
	bg.regen(seed)
	map_seed = seed
	map_pads = maxi(n, 2)
	if net.is_host():
		map_hash = hash(terrain.field)


func _next_round() -> void:
	round_n += 1
	bullets.clear()
	missiles.clear()
	pickups.clear()
	pu_timer = 4.0
	fx.clear()
	var active := []
	for i in 4:
		if slots[i].type != "off":
			active.append(i)
	# respawn modes keep spare pads to come back on
	_new_map(active.size() if game_mode == "rounds" else 4)
	var order := range(active.size())
	order.shuffle()
	for s in ships:
		s.alive = false
		s.visible = false
	for k in active.size():
		var s = ships[active[k]]
		var sl: Dictionary = slots[s.idx]
		if autotest:
			sl.hull = rng.randi() % Hulls.count()   # exercise every hull shape
		s.is_cpu = sl.type == "cpu"
		s.color = Cfg.PALETTE[sl.color]
		s.cname = Cfg.PNAMES[sl.color]
		s.hull = sl.hull
		s.team = sl.team if teams else s.idx
		s.bot = BotScript.new(s, self) if s.is_cpu else null
		s.spawn(terrain.pad_spawn(order[k] % terrain.pads.size()))
	state = "countdown"
	timer = 1.8
	round_t = 0.0
	match game_mode:
		"rounds":
			msg = "ROUND %d" % round_n
		"stock":
			msg = "STOCK · " + rule_label()
		"timed":
			msg = "TIMED · %s" % rule_label()
	msg_col = Color.WHITE


func step(dt: float) -> void:
	time += dt
	shake *= exp(-dt * 10.0)
	fx.update(dt)
	match state:
		"countdown":
			timer -= dt
			if timer <= 0.0:
				state = "play"
				msg = ""
		"play":
			_sim(dt)
			round_t += dt
			if game_mode != "rounds":
				_respawns(dt)
				_check_finish(dt)
			elif _sides() <= 1 or round_t > Cfg.ROUND_LIMIT:
				timed_out = round_t > Cfg.ROUND_LIMIT
				state = "round_end"
				timer = 2.8
				awarded = false
		"round_end":
			_sim(dt)
			timer -= dt
			if not awarded and timer < 2.0:
				_award()
			if timer <= 0.0:
				var sc: Array = team_scores if teams else scores
				var best: int = sc.max()
				if best >= win_rounds:
					state = "match_end"
					matches_done += 1
					var w: int = sc.find(best)
					msg = "%s WINS THE MATCH!" % (Cfg.TEAM_NAMES[w] if teams else ships[w].cname)
					msg_col = Cfg.TEAM_COLORS[w] if teams else ships[w].color
				else:
					_next_round()
		"match_end":
			_sim(dt)


func _alive() -> Array:
	var a := []
	for s in ships:
		if s.alive:
			a.append(s)
	return a


# ---------------------------------------------------------------- stock / timed

func _respawns(dt: float) -> void:
	for s in ships:
		if s.alive or slots[s.idx].type == "off" or respawn_t[s.idx] <= 0.0:
			continue
		respawn_t[s.idx] -= dt
		if respawn_t[s.idx] <= 0.0:
			var pad := _free_pad(s)
			if pad < 0:
				respawn_t[s.idx] = 0.25   # every pad busy, try again shortly
			else:
				s.spawn(terrain.pad_spawn(pad))
				s.invuln = 1.5


## Empty pad farthest from enemies, or -1.
func _free_pad(s) -> int:
	var best := -1
	var best_d := -1.0
	for k in terrain.pads.size():
		var p: Vector2 = terrain.pad_spawn(k)
		var d := 1e4
		var busy := false
		for o in ships:
			if o.alive and o != s:
				var od: float = o.position.distance_to(p)
				if od < 60.0:
					busy = true
				if is_enemy(s, o):
					d = minf(d, od)
		if not busy and d > best_d:
			best_d = d
			best = k
	return best


## Score per side (team in team mode, player in FFA).
func side_points() -> Dictionary:
	var tot := {}
	for s in ships:
		if slots[s.idx].type != "off":
			tot[s.team] = tot.get(s.team, 0) + points[s.idx]
	return tot


func _check_finish(dt: float) -> void:
	if game_mode == "stock":
		var left := {}
		for s in ships:
			if slots[s.idx].type != "off" and (s.alive or lives[s.idx] > 0):
				left[s.team] = true
		if left.size() <= 1:
			_finish(left.keys()[0] if left.size() == 1 else -1)
		return
	match_t -= dt
	if match_t > 0.0:
		return
	# time's up: highest score wins; a tie goes to overtime (next point wins)
	var tot := side_points()
	var best := -999999
	var lead := -1
	for k in tot:
		if tot[k] > best:
			best = tot[k]
			lead = k
		elif tot[k] == best:
			lead = -1
	if lead >= 0:
		_finish(lead)
	elif not overtime:
		overtime = true
		fx.text(Vector2(Cfg.W / 2.0, Cfg.H / 2.0), "OVERTIME - NEXT POINT WINS", Color("ffd23f"))


func _finish(side: int) -> void:
	state = "match_end"
	matches_done += 1
	stats.rounds += 1
	stats.round_time += round_t
	if side < 0:
		msg = "DRAW!"
		msg_col = Color.WHITE
		stats.draws += 1
	else:
		stats.wins += 1
		msg = "%s WINS!" % (Cfg.TEAM_NAMES[side] if teams else ships[side].cname)
		msg_col = Cfg.TEAM_COLORS[side] if teams else ships[side].color


## Number of players (FFA) or teams still in the fight.
func _sides() -> int:
	var seen := {}
	for s in _alive():
		seen[s.team] = true
	return seen.size()


func _award() -> void:
	awarded = true
	var a := _alive()
	stats.rounds += 1
	stats.round_time += round_t
	if a.size() > 0 and _sides() == 1 and not timed_out:
		stats.wins += 1
		if teams:
			team_scores[a[0].team] += 1
			msg = "%s WINS THE ROUND" % Cfg.TEAM_NAMES[a[0].team]
			msg_col = Cfg.TEAM_COLORS[a[0].team]
		else:
			scores[a[0].idx] += 1
			msg = "%s WINS THE ROUND" % a[0].cname
			msg_col = a[0].color
	else:
		msg = "TIME'S UP - DRAW" if timed_out else "DRAW"
		msg_col = Color.WHITE
		stats.draws += 1
		if timed_out:
			stats.timeouts += 1


# ---------------------------------------------------------------- simulation

func _sim(dt: float) -> void:
	for s in ships:
		if s.alive:
			var inp: Dictionary
			if s.is_cpu:
				inp = s.bot.think(dt)
			elif slots[s.idx].type == "net":
				inp = net.input_for(s.idx)
			else:
				inp = Controls.read(s.idx)
			s.step(dt, inp)
	_update_bullets(dt)
	_update_missiles(dt)
	if powerups:
		_update_pickups(dt)
	# ship vs ship: both explode
	for i in 4:
		for j in range(i + 1, 4):
			var a = ships[i]
			var b = ships[j]
			if a.alive and b.alive and a.position.distance_to(b.position) < 30.0 and _ships_touch(a, b):
				stats.collide += 1
				kill(a, -1)
				kill(b, -1)


## Do the two ship outlines overlap?
func _ships_touch(a, b) -> bool:
	for p in a.world_points():
		if b.contains(p):
			return true
	for p in b.world_points():
		if a.contains(p):
			return true
	return false


## Can a projectile from owner/team hit ship s?
func _can_hit(s, owner: int, team: int, age: float, grace: float) -> bool:
	if not s.alive or s.invuln > 0.0:
		return false
	if s.idx == owner:
		return age >= grace
	if teams and not friendly_fire and s.team == team:
		return false
	return true


func _update_bullets(dt: float) -> void:
	var keep := []
	for b in bullets:
		b.age += dt
		b.v.y += Cfg.GRAVITY * Cfg.BULLET_GRAV * dt
		var prev: Vector2 = b.p
		b.p += b.v * dt
		if b.age > Cfg.BULLET_LIFE:
			continue
		if terrain.solid_at(b.p):
			if b.bounce > 0:
				# ricochet: flip whichever axis ran into rock
				b.bounce -= 1
				stats.ricochets += 1
				var fx_x: bool = terrain.solid_at(Vector2(b.p.x, prev.y))
				var fx_y: bool = terrain.solid_at(Vector2(prev.x, b.p.y))
				if fx_x or not fx_y:
					b.v.x = -b.v.x
				if fx_y or not fx_x:
					b.v.y = -b.v.y
				b.v *= 0.9
				b.p = prev
				fx.spark(b.p, Cfg.PU.bounce.col, 3)
			else:
				fx.spark(b.p, ships[b.owner].color)
				continue
		var hit := false
		for s in ships:
			if _can_hit(s, b.owner, b.team, b.age, 0.3) and s.position.distance_to(b.p) < 22.0 and s.contains(b.p, 2.0):
				damage(s, b.owner, "bullet")
				hit = true
				break
		if not hit:
			keep.append(b)
	bullets = keep


func _update_missiles(dt: float) -> void:
	var keep := []
	for m in missiles:
		m.age += dt
		# steer toward the nearest enemy of the shooter
		var shooter = ships[m.owner]
		var best = null
		var bd := 1e9
		for s in ships:
			if s.alive and is_enemy(shooter, s):
				var d: float = m.p.distance_to(s.position)
				if d < bd:
					bd = d
					best = s
		var speed: float = minf(m.v.length() + 300.0 * dt, Cfg.MISSILE_SPEED)
		var ang: float = m.v.angle()
		if best != null:
			var want: float = (best.position - m.p).angle()
			ang += clampf(wrapf(want - ang, -PI, PI), -Cfg.MISSILE_TURN * dt, Cfg.MISSILE_TURN * dt)
		m.v = Vector2.RIGHT.rotated(ang) * speed
		m.p += m.v * dt
		if randf() < 0.6:
			fx.exhaust(m.p - m.v.normalized() * 6.0, -m.v * 0.3)
		if m.age > Cfg.MISSILE_LIFE or terrain.solid_at(m.p):
			fx.explode(m.p, Cfg.PU.missile.col, 14)
			continue
		var hit := false
		for s in ships:
			if _can_hit(s, m.owner, m.team, m.age, 0.8) and s.position.distance_to(m.p) < 24.0 and s.contains(m.p, 3.0):
				damage(s, m.owner, "missile")
				hit = true
				break
		if not hit:
			keep.append(m)
	missiles = keep


func _update_pickups(dt: float) -> void:
	if state == "play":
		pu_timer -= dt
		if pu_timer <= 0.0:
			pu_timer = Cfg.PU_EVERY * rng.randf_range(0.7, 1.3)
			if pickups.size() < Cfg.PU_MAX:
				_spawn_pickup()
	var keep := []
	for pk in pickups:
		pk.age += dt
		if pk.age > Cfg.PU_LIFE:
			continue
		var taken := false
		for s in ships:
			if s.alive and s.position.distance_to(pk.p) < 22.0:
				s.give(pk.kind)
				stats.pickups += 1
				fx.text(s.position + Vector2(0, -28), Cfg.PU[pk.kind].name, Cfg.PU[pk.kind].col)
				fx.spark(pk.p, Cfg.PU[pk.kind].col, 12)
				taken = true
				break
		if not taken:
			keep.append(pk)
	pickups = keep


func _spawn_pickup() -> void:
	for attempt in 60:
		var n := rng.randi_range(0, Cfg.GW * Cfg.GH - 1)
		if terrain.clearance[n] < 3:
			continue
		var p: Vector2 = terrain.node_pos(n)
		var ok := true
		for s in ships:
			if s.alive and s.position.distance_to(p) < 140.0:
				ok = false
		for o in pickups:
			if o.p.distance_to(p) < 160.0:
				ok = false
		if ok:
			pickups.append({"p": p, "kind": Cfg.PU_KINDS[rng.randi() % Cfg.PU_KINDS.size()], "age": 0.0})
			return


func fire(s) -> void:
	var f: Vector2 = s.fwd()
	if s.missiles > 0:
		s.missiles -= 1
		next_id += 1
		missiles.append({"id": next_id, "p": s.position + f * 14.0, "v": f * 160.0 + s.vel * 0.5, "owner": s.idx, "team": s.team, "age": 0.0})
		return
	var spread := [-0.17, 0.0, 0.17] if s.has_fx("triple") else [0.0]
	for a in spread:
		var d: Vector2 = f.rotated(a)
		next_id += 1
		bullets.append({"id": next_id, "p": s.position + d * 13.0, "v": d * Cfg.BULLET_SPEED + s.vel, "owner": s.idx,
				"team": s.team, "age": 0.0, "bounce": 3 if s.has_fx("bounce") else 0})


## A projectile reached ship s. Shields soak one hit.
func damage(s, owner: int, weapon: String) -> void:
	if s.shield_up:
		s.shield_up = false
		s.invuln = 0.5
		stats.blocks += 1
		fx.spark(s.position, Cfg.PU.shield.col, 16)
		fx.text(s.position + Vector2(0, -28), "BLOCKED", Cfg.PU.shield.col)
		return
	if weapon == "missile":
		stats.missile_kills += 1
	kill(s, owner)


## killer = index of the shooter, or -1 for crashes.
func kill(s, killer: int) -> void:
	if not s.alive:
		return
	s.alive = false
	s.visible = false
	fx.explode(s.position, s.color)
	shake = 7.0
	if game_mode != "rounds":
		if killer >= 0 and killer != s.idx:
			points[killer] += 1 if is_enemy(ships[killer], s) else -1   # team-kills cost a point
		else:
			points[s.idx] -= 1   # crashed or shot yourself
		if game_mode == "timed" or lives[s.idx] > 1:
			respawn_t[s.idx] = RESPAWN_DELAY
		if game_mode == "stock":
			lives[s.idx] -= 1
	if killer >= 0:
		stats.shot += 1
		if killer != s.idx:
			kills[killer] += 1
	else:
		stats.crash += 1
		var b := "early" if s.life_t < 3.0 else ("mid" if s.life_t < 10.0 else "late")
		stats[b] = stats.get(b, 0) + 1


# ---------------------------------------------------------------- online self-test
# Terminal 1:  godot --headless --path . -- --nethost
# Terminal 2:  godot --headless --path . -- --netjoin 127.0.0.1 --lag 120
# The host plays a 60 s timed match with CPUs plus the guest; a CPU pilot flies the
# guest's ship through the real client path (input sending, prediction, interpolation).

func _net_test(args: PackedStringArray) -> void:
	var t0 := Time.get_ticks_msec()
	if "--nethost" in args:
		net.host()
		slots = [
			{"type": "cpu", "color": 0, "team": 0, "hull": 0},
			{"type": "off", "color": 5, "team": 1, "hull": 5},
			{"type": "cpu", "color": 2, "team": 0, "hull": 7},
			{"type": "off", "color": 3, "team": 1, "hull": 3},
		]
		game_mode = "timed"
		time_limit = 45.0
		_new_map(4)
		while not slots.any(func(s): return s.type == "net"):
			await get_tree().process_frame
			if Time.get_ticks_msec() - t0 > 30000:
				print("NETHOST no guest joined")
				get_tree().quit(1)
				return
		print("NETHOST guest seated: ", slots.map(func(s): return s.type))
		await get_tree().create_timer(1.0).timeout
		start_match()
		while state != "match_end":
			await get_tree().process_frame
		print("NETHOST match over: %s pts=%s kills=%s inputs_rcvd=%d max_snap=%dB ack=%s" % [msg, str(points), str(kills),
				net.stat_inputs, net.stat_max_bytes, str(net.inputs.values().map(func(d): return d.ack))])
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()
	else:
		var ai := args.find("--netjoin")
		net.join(args[ai + 1] if ai + 1 < args.size() else "127.0.0.1")
		var bot_for := -1
		var seen_play := false
		var mine_alive := 0
		while net.online() or Time.get_ticks_msec() - t0 < 3000:
			await get_tree().physics_frame
			var k: int = net.my_slot()
			if k >= 0 and k != bot_for:
				bot_for = k
				autotest_bot = BotScript.new(ships[k], self)
			if state == "play":
				seen_play = true
				if k >= 0 and ships[k].alive:
					mine_alive += 1
			if Time.get_ticks_msec() - t0 > 120000:
				break
			if "--shot" in args and Time.get_ticks_msec() - t0 > 9000:
				get_viewport().get_texture().get_image().save_png("user://shot.png")
				print("SHOT ", ProjectSettings.globalize_path("user://shot.png"))
				break
		var st: Dictionary = net.stat
		print("NETJOIN snaps=%d events=%d maps=%d map_mismatch=%d saw_play=%s my_alive_ticks=%d corr_avg=%.2fpx corr_max=%.1fpx status='%s'" % [
				st.snaps, st.events, st.maps, st.map_mismatch, seen_play, mine_alive,
				st.corr_sum / maxf(st.corr_n, 1), st.corr_max, net.status])
		get_tree().quit()


# ---------------------------------------------------------------- headless self-test
# Plays CPU-only rounds as fast as possible (FFA, then teams) and prints stats.

func _autotest() -> void:
	autotest = true
	for s in slots:
		s.type = "cpu"
	var t0 := Time.get_ticks_msec()
	var fails := 0
	for k in 100:
		if not terrain.generate(k * 7919 + 1, 4):
			fails += 1
	print("MAPGEN 100 maps, failures=%d, %d ms" % [fails, Time.get_ticks_msec() - t0])
	# every hull must spawn clear of rock and survive a gentle drop onto its pad
	var s0 = ships[0]
	var hull_report := []
	for h in Hulls.count():
		terrain.generate(1234 + h, 2)
		s0.hull = h
		s0.spawn(terrain.pad_spawn(0))
		var clear: bool = s0.hits_at(s0.position, s0.rotation) == 0
		s0.position.y -= 25.0
		s0.landed = false
		for k in 240:
			s0.step(DT, {"turn": 0.0, "thrust": false, "fire": false})
		hull_report.append("%s:%s" % [Hulls.hull_name(h), "ok" if clear and s0.alive and s0.landed else "FAIL(clear=%s alive=%s landed=%s)" % [clear, s0.alive, s0.landed]])
	print("HULLS ", ", ".join(hull_report))
	s0.alive = false
	var configs := [["rounds", false, 20], ["rounds", true, 20], ["stock", false, 3], ["stock", true, 3], ["timed", false, 3], ["timed", true, 3]]
	time_limit = 60.0
	for c in configs:
		game_mode = c[0]
		teams = c[1]
		if teams:
			for k in 4:
				slots[k].team = k % 2
		_reset_stats()
		matches_done = 0
		var results := []
		start_match()
		var steps := 0
		var target: int = c[2]
		while (stats.rounds < target if game_mode == "rounds" else matches_done < target) and steps < 120 * 60 * 30:
			step(DT)
			steps += 1
			if state == "match_end":
				results.append(msg + (" pts=%s" % str(side_points()) if game_mode == "timed" else "") + (" lives=%s" % str(lives) if game_mode == "stock" else ""))
				start_match()
			for s in ships:
				if s.alive and s.hits_at(s.position, s.rotation) != 0:
					print("STUCK ship %d at %s" % [s.idx, s.position])
		var r: int = maxi(stats.rounds, 1)
		print("AUTOTEST %s%s %s=%d wins=%d draws=%d avg_len=%.1fs shot_kills=%d crashes=%d collisions=%d pickups=%d missile_kills=%d blocks=%d ricochets=%d map_fail=%d sim=%ds" % [
			game_mode, " teams" if teams else "", "rounds" if game_mode == "rounds" else "matches", stats.rounds, stats.wins, stats.draws,
			stats.round_time / r, stats.shot, stats.crash, stats.collide, stats.pickups, stats.missile_kills, stats.blocks,
			stats.ricochets, stats.map_fail, steps / 120])
		print("    crash age: <3s=%d 3-10s=%d >10s=%d" % [stats.get("early", 0), stats.get("mid", 0), stats.get("late", 0)])
		if results.size() > 0 and game_mode != "rounds":
			print("    results: ", " | ".join(results))
	print("AUTOTEST done in %d ms" % (Time.get_ticks_msec() - t0))
	get_tree().quit()
