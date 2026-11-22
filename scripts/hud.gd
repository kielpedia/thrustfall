extends Node2D
## Title menu (clickable), scoreboard, countdown and round messages.

const Cfg = preload("res://scripts/cfg.gd")
const Controls = preload("res://scripts/controls.gd")
const Hulls = preload("res://scripts/hulls.gd")
const Build = preload("res://scripts/build.gd")

var main
var buttons := []   # [Rect2, action] rebuilt every frame on the title screen
var held_t := [0.0, 0.0, 0.0, 0.0]   # how long each local seat has been holding thrust/turn


## align: 0 = center, -1 = left, 1 = right. pos.y is the vertical middle of the text.
func text(s: String, pos: Vector2, size: int, col := Color.WHITE, align := 0) -> void:
	var f: Font = main.font
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var x := pos.x - w / 2.0 if align == 0 else (pos.x if align < 0 else pos.x - w)
	var base := pos.y + size * 0.35
	draw_string(f, Vector2(x + 2, base + 3), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.6))
	draw_string(f, Vector2(x, base), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func button(r: Rect2, label: String, action: String, col := Color.WHITE, size := 18) -> void:
	var hover := r.has_point(get_local_mouse_position())
	draw_rect(r, Color(col, 0.22 if hover else 0.1))
	draw_rect(r, Color(col, 0.9 if hover else 0.5), false, 2.0)
	text(label, r.get_center(), size, col)
	buttons.append([r, action])


func _draw() -> void:
	buttons.clear()
	var st: String = main.state
	var cx := Cfg.W / 2.0

	if st == "title":
		_draw_title(cx)
		return

	if main.teams:
		_team_board(0, 20.0, -1)
		_team_board(1, Cfg.W - 20.0, 1)
	else:
		var x := 20.0
		for i in 4:
			if main.slots[i].type == "off":
				continue
			var s = main.ships[i]
			var label: String = s.cname + (" CPU" if s.is_cpu else "")
			text(label, Vector2(x, 18), 15, s.color if s.alive else s.color.darkened(0.55), -1)
			match main.game_mode:
				"rounds":
					for p in main.win_rounds:
						draw_circle(Vector2(x + 6 + p * 15, 38), 5, s.color if p < main.scores[i] else Color(1, 1, 1, 0.18))
				"stock":
					for p in main.lives[i]:
						Hulls.draw(self, s.hull, Vector2(x + 6 + p * 14, 39), s.color, 0.5)
				"timed":
					text("%d" % main.points[i], Vector2(x, 39), 20, s.color, -1)
			if s.alive:
				_effects(s, Vector2(x, 58), -1)
			else:
				_status(i, Vector2(x, 58), -1)
			x += 160.0

	if st != "countdown":
		text(main.world_label(), Vector2(Cfg.W - 14, Cfg.H - 12), 12, Color(1, 1, 1, 0.35), 1)

	if main.game_mode == "timed" and st != "countdown":
		var ot: bool = main.overtime
		text("OVERTIME" if ot else main.clock(main.match_t), Vector2(cx, 22), 26 if ot else 28,
				Color("ffd23f") if ot or main.match_t < 10.0 else Color.WHITE)

	match st:
		"countdown":
			text(main.msg, Vector2(cx, Cfg.H / 2.0 - 50), 56, Color.WHITE)
			text(main.world_label(), Vector2(cx, Cfg.H / 2.0 + 2), 18, Color("b07cff"))
			text("%d" % ceili(main.timer / 0.6), Vector2(cx, Cfg.H / 2.0 + 48), 40, Color("ffd23f"))
		"round_end":
			if main.awarded:
				text(main.msg, Vector2(cx, Cfg.H / 2.0), 52, main.msg_col)
		"match_end":
			draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), Color(0, 0, 0, 0.45))
			text(main.msg, Vector2(cx, Cfg.H / 2.0 - 30), 64, main.msg_col)
			text("waiting for the host...     ESC leave" if main.net.is_client() else "ENTER rematch     ESC menu",
					Vector2(cx, Cfg.H / 2.0 + 40), 22, Color.WHITE)
			text(Build.label(Cfg.VERSION), Vector2(Cfg.W - 14, Cfg.H - 12), 12, Color(1, 1, 1, 0.45), 1)
		"play":
			if main.round_t < 1.0:
				text("GO!", Vector2(cx, Cfg.H / 2.0), 64, Color(1, 1, 1, 1.0 - main.round_t))


## Shown in place of power-ups while a ship is dead in stock / timed.
func _status(i: int, pos: Vector2, align: int) -> void:
	if main.game_mode == "rounds" or main.state != "play":
		return
	if main.respawn_t[i] > 0.0:
		text("BACK IN %.1f" % main.respawn_t[i], pos, 12, Color(1, 1, 1, 0.6), align)
	elif main.game_mode == "stock" and main.lives[i] <= 0:
		text("OUT", pos, 12, Color("ff4d5e"), align)


## Small icons for a ship's active power-ups.
func _effects(s, pos: Vector2, align: int) -> void:
	if not s.alive:
		return
	var icons := []
	if s.shield_up:
		icons.append(["S", Cfg.PU.shield.col])
	if s.missiles > 0:
		icons.append(["M%d" % s.missiles, Cfg.PU.missile.col])
	for k in s.effects:
		if s.effects[k] > 0.0:
			icons.append([Cfg.PU[k].icon, Cfg.PU[k].col])
	var x := pos.x
	for ic in icons:
		text(ic[0], Vector2(x, pos.y), 13, ic[1], align)
		x += 22.0 * (1 if align < 0 else -1)


func _team_board(t: int, x: float, align: int) -> void:
	var tc: Color = Cfg.TEAM_COLORS[t]
	text(Cfg.TEAM_NAMES[t], Vector2(x, 18), 17, tc, align)
	match main.game_mode:
		"rounds":
			for p in main.win_rounds:
				var px: float = x + 8 + p * 15 if align < 0 else x - 8 - p * 15
				draw_circle(Vector2(px, 40), 5, tc if p < main.team_scores[t] else Color(1, 1, 1, 0.18))
		"stock":
			var tl := 0
			for s in main.ships:
				if main.slots[s.idx].type != "off" and s.team == t:
					tl += main.lives[s.idx]
			text("%d LIVES LEFT" % tl, Vector2(x, 40), 14, tc, align)
		"timed":
			text("%d" % main.side_points().get(t, 0), Vector2(x, 40), 20, tc, align)
	var y := 60.0
	for s in main.ships:
		if main.slots[s.idx].type == "off" or s.team != t:
			continue
		var label: String = s.cname + (" CPU" if s.is_cpu else "")
		match main.game_mode:
			"stock":
				label += "  x%d" % main.lives[s.idx]
			"timed":
				label += "  %d" % main.points[s.idx]
		text(label, Vector2(x, y), 13, s.color if s.alive else s.color.darkened(0.55), align)
		var ex := Vector2(x + (140.0 if align < 0 else -140.0), y)
		if s.alive:
			_effects(s, ex, align)
		else:
			_status(s.idx, ex, align)
		y += 18.0


func _draw_title(cx: float) -> void:
	draw_rect(Rect2(0, 0, Cfg.W, Cfg.H), Color(0.02, 0.02, 0.08, 0.72))
	text("THRUSTFALL", Vector2(cx, 70), 76, Color("ffd23f"))
	text(Build.label(Cfg.VERSION), Vector2(Cfg.W - 14, 16), 13, Color(1, 1, 1, 0.45), 1)
	text("Fight gravity. Don't touch the rock. One shot, one kill.", Vector2(cx, 125), 18, Color("c8c8e0"))

	# match options
	var bx := cx - 494.0
	var gold := Color("ffd23f")
	button(Rect2(bx, 148, 200, 38), "GAME: " + main.game_mode.to_upper(), "game", gold, 16)
	button(Rect2(bx + 212, 148, 150, 38), main.rule_label(), "value", gold, 16)
	button(Rect2(bx + 374, 148, 170, 38), "TEAMS: " + ("ON" if main.teams else "OFF"), "teams",
			Color("6ec3ff") if main.teams else Color(1, 1, 1, 0.5), 16)
	button(Rect2(bx + 556, 148, 200, 38), "POWER-UPS: " + ("ON" if main.powerups else "OFF"), "pu",
			Color("5ee87d") if main.powerups else Color(1, 1, 1, 0.5), 16)
	if main.teams:
		button(Rect2(bx + 768, 148, 220, 38), "FRIENDLY FIRE: " + ("ON" if main.friendly_fire else "OFF"), "ff",
				Color("ff6b6b") if main.friendly_fire else Color(1, 1, 1, 0.5), 16)
	# world: gravity + open space, fixed or rolled fresh every round
	var violet := Color("b07cff")
	button(Rect2(bx, 194, 362, 38), "GRAVITY: " + main.grav_label(main.gravity_opt), "grav", violet, 16)
	button(Rect2(bx + 374, 194, 382, 38), "OPEN SPACE: " + main.open_label(main.open_opt), "open", violet, 16)
	var rolls := []
	if main.gravity_opt < 0.0:
		rolls.append("gravity %s-%sx" % [main.GRAV_RANDOM[0], main.GRAV_RANDOM[1]])
	if main.open_opt < 0.0:
		rolls.append("open space %d-%d%%" % [main.OPEN_RANDOM[0] * 100, main.OPEN_RANDOM[1] * 100])
	text("rerolled each round: " + ", ".join(rolls) if rolls.size() > 0 else "same every round",
			Vector2(bx + 768, 213), 13, Color(violet, 0.85), -1)
	var desc: String = {
		"rounds": "Last ship standing wins the round. New map every round.",
		"stock": "Everyone gets %s and respawns on a pad. Last one with lives left wins." % main.rule_label().to_lower(),
		"timed": "Respawn until the clock runs out. Most kills wins; crashing or shooting yourself costs a point.",
	}[main.game_mode]
	text(desc, Vector2(cx, 250), 14, Color("c8c8e0"))

	# player slots
	for i in 4:
		var y := 270.0 + i * 60.0
		var sl: Dictionary = main.slots[i]
		var on: bool = sl.type != "off"
		var col: Color = Cfg.PALETTE[sl.color] if on else Color(1, 1, 1, 0.3)
		text("P%d" % (i + 1), Vector2(110, y + 22), 20, Color(1, 1, 1, 0.5))
		var tlabel: String = "ONLINE" if sl.type == "net" else sl.type.to_upper()
		if main.net.is_client() and i == main.net.my_slot():
			tlabel = "YOU"
		elif main.net.is_client() and sl.type == "human":
			tlabel = "HOST"
		button(Rect2(145, y, 120, 44), tlabel, "type:%d" % i, col if on else Color(1, 1, 1, 0.4))
		if on:
			# color picker
			button(Rect2(278, y, 34, 44), "<", "color:%d:-1" % i, col, 22)
			draw_rect(Rect2(316, y, 110, 44), Color(col, 0.25))
			text(Cfg.PNAMES[sl.color], Vector2(371, y + 22), 17, col)
			button(Rect2(430, y, 34, 44), ">", "color:%d:1" % i, col, 22)
			# hull picker
			button(Rect2(476, y, 34, 44), "<", "hull:%d:-1" % i, col, 22)
			draw_rect(Rect2(514, y, 140, 44), Color(1, 1, 1, 0.06))
			Hulls.draw(self, sl.hull, Vector2(538, y + 23), col, 1.3)
			text(Hulls.hull_name(sl.hull), Vector2(603, y + 22), 15, Color(1, 1, 1, 0.85))
			button(Rect2(658, y, 34, 44), ">", "hull:%d:1" % i, col, 22)
			var help_x := 706.0
			if main.teams:
				var tc: Color = Cfg.TEAM_COLORS[sl.team]
				button(Rect2(706, y, 110, 44), Cfg.TEAM_NAMES[sl.team], "team:%d" % i, tc, 16)
				help_x = 828.0
			var help := ""
			if main.net.is_client():
				if i == main.net.my_slot():
					help = Controls.HELP[0] + "  · pad 1"
				elif sl.type in ["human", "net"]:
					help = "online player"
			elif sl.type == "human":
				help = Controls.HELP[i] + "  · pad %d" % (i + 1)
			elif sl.type == "net":
				help = "online player (they pick their own color / ship)"
			# a seat that "holds" thrust or turn for seconds on the menu = stuck controller
			var keys := -1
			if main.net.is_client():
				keys = 0 if i == main.net.my_slot() else -1
			elif sl.type == "human":
				keys = i
			var stuck := false
			if keys >= 0:
				var inp: Dictionary = Controls.read(keys)
				held_t[i] = held_t[i] + get_process_delta_time() if inp.thrust or absf(inp.turn) > 0.5 else 0.0
				stuck = held_t[i] > 2.0
			if stuck:
				text("INPUT HELD DOWN: check this player's keys / controller (pad %d)" % (keys + 1),
						Vector2(help_x, y + 22), 13, Color("ff4d5e"), -1)
			elif help != "":
				text(help, Vector2(help_x, y + 22), 13 if main.teams else 14, Color(1, 1, 1, 0.7), -1)

	var net = main.net
	var problem: String = main.start_problem()
	if net.is_client():
		draw_rect(Rect2(cx - 120, 515, 240, 54), Color(1, 1, 1, 0.06))
		text("HOST STARTS", Vector2(cx, 542), 22, Color(1, 1, 1, 0.5))
	else:
		button(Rect2(cx - 120, 515, 240, 54), "LAUNCH", "start", Color("ffd23f") if problem == "" else Color(1, 1, 1, 0.3), 26)
		if problem != "":
			text(problem, Vector2(cx, 584), 15, Color("ff4d5e"))
	_draw_net(cx)
	text("Click, or: 1-4 player · turn keys = color · thrust = ship · fire = team · M game · V setting · T teams · P power-ups · G gravity · O open · ENTER",
			Vector2(cx, 632), 14, Color("9fa3c8"))
	text("Land gently and upright to rest. Hit rock fast or sideways and you explode.",
			Vector2(cx, 654), 14, Color("9fa3c8"))
	if main.powerups:
		var x := cx - 470.0
		for k in Cfg.PU_KINDS:
			var info: Dictionary = Cfg.PU[k]
			text(info.icon, Vector2(x, 690), 15, info.col, -1)
			text(info.name, Vector2(x + 18, 690), 13, Color(1, 1, 1, 0.7), -1)
			x += 160.0


## Online row: JOIN + address box on the left, HOST on the right, status underneath.
func _draw_net(cx: float) -> void:
	var net = main.net
	var green := Color("5ee87d")
	var blue := Color("6ec3ff")
	if not net.online():
		button(Rect2(145, 515, 145, 54), "JOIN", "join", blue, 20)
		# the address box (a LineEdit) sits at x 300-490
		draw_rect(Rect2(298, 513, 194, 58), Color(blue, 0.35), false, 2.0)
		button(Rect2(cx + 150, 515, 200, 54), "HOST ONLINE", "host", green, 20)
	elif net.is_host():
		button(Rect2(145, 515, 345, 54), "STOP HOSTING", "leave", Color("ff9f1c"), 18)
		var addrs: Array = net.local_addresses()
		text("ONLINE · %d friend%s connected" % [net.peer_count(), "" if net.peer_count() == 1 else "s"],
				Vector2(cx + 150, 526), 16, green, -1)
		text("They join: " + (" / ".join(addrs.slice(0, 3)) if addrs.size() > 0 else "your IP"),
				Vector2(cx + 150, 552), 14, Color(1, 1, 1, 0.8), -1)
	else:
		button(Rect2(145, 515, 345, 54), "LEAVE", "leave", Color("ff9f1c"), 18)
		text("ONLINE · " + ("seat P%d" % (net.my_slot() + 1) if net.my_slot() >= 0 else "spectating"),
				Vector2(cx + 150, 540), 16, green, -1)
	if net.status != "":
		text(net.status, Vector2(cx, 606), 15, net.status_col)
