extends Node
## Online play over ENet (UDP). The host runs the real game; everyone else is a client.
##
##   client -> host   input every tick (turn/thrust/fire + sequence number), lobby requests
##   host -> client   a snapshot of the whole game 40x a second, plus reliable fx events
##
## Clients draw other ships slightly in the past, smoothly interpolated between snapshots.
## Their own ship is predicted locally (same ship physics, same map from the same seed)
## and corrected against the host's snapshot, so steering feels instant.

const Cfg = preload("res://scripts/cfg.gd")
const Controls = preload("res://scripts/controls.gd")
const BotScript = preload("res://scripts/bot.gd")

const PORT := 7777
const SEND_EVERY := 3            # physics ticks between snapshots (120/3 = 40 per second)
const INTERP_DELAY := 0.075      # seconds clients draw remote things in the past
const CFG_PATH := "user://net.cfg"

var main
var peer: ENetMultiplayerPeer
var mode := ""                   # "", "host", "client"
var status := ""                 # one line for the title screen
var status_col := Color.WHITE
var last_ip := "127.0.0.1"
var lag := 0.0                   # --lag ms: fake round-trip delay (testing)

# host side
var inputs := {}                 # slot -> {q: [[seq, inp]...], cur: inp, last: seq, ack: seq}
var waiting := []                # peers that joined mid-match, seated at the next title screen
var events := []
var tick := 0
var host_t := 0.0
var stat_inputs := 0
var stat_max_bytes := 0

# client side
var my_id := 0
var seq := 0
var pending := []                # [seq, inp] not yet confirmed by the host
var snaps := []                  # recent snapshots, oldest first
var rt := -1.0                   # render time on the host clock
var ev_queue := []               # [host_t, event]
var map_seed := -1
var later := []                  # [due_ms, Callable] for --lag
var stat := {"snaps": 0, "events": 0, "maps": 0, "map_mismatch": 0, "corr_sum": 0.0, "corr_n": 0, "corr_max": 0.0}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		last_ip = cf.get_value("net", "ip", last_ip)


func is_host() -> bool:
	return mode == "host"


func is_client() -> bool:
	return mode == "client"


func online() -> bool:
	return mode != ""


# ---------------------------------------------------------------- connect / disconnect

func host() -> void:
	leave()
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 7)
	if err != OK:
		_say("Couldn't host on port %d (already in use?)" % PORT, Color("ff4d5e"))
		peer = null
		return
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	mode = "host"
	inputs.clear()
	waiting.clear()
	_say("Hosting on port %d. Waiting for friends..." % PORT, Color("5ee87d"))


func join(addr: String) -> void:
	leave()
	addr = addr.strip_edges()
	if addr == "":
		_say("Type the host's address first", Color("ff4d5e"))
		return
	var port := PORT
	if addr.count(":") == 1:
		port = int(addr.get_slice(":", 1))
		addr = addr.get_slice(":", 0)
	last_ip = addr if port == PORT else "%s:%d" % [addr, port]
	var cf := ConfigFile.new()
	cf.set_value("net", "ip", last_ip)
	cf.save(CFG_PATH)
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port)
	if err != OK:
		_say("Bad address: " + addr, Color("ff4d5e"))
		peer = null
		return
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	mode = "client"
	snaps.clear()
	pending.clear()
	ev_queue.clear()
	rt = -1.0
	map_seed = -1
	_say("Connecting to %s:%d ..." % [addr, port], Color("ffd23f"))


func leave(reason := "") -> void:
	var was_client := is_client()
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = null
	peer = null
	mode = ""
	later.clear()
	_say(reason, Color("ff9f1c"))
	# back to an offline lobby: online seats become CPUs again
	for s in main.slots:
		if s.type == "net":
			s.type = "cpu"
		s.erase("peer")
	if was_client:
		main.slots[0].type = "human"
		main.go_title()


func _say(s: String, col := Color.WHITE) -> void:
	status = s
	status_col = col


func _on_peer_connected(id: int) -> void:
	if is_host():
		_say("Friend connected (id %d)" % id, Color("5ee87d"))


func _on_peer_disconnected(id: int) -> void:
	if not is_host():
		return
	waiting.erase(id)
	var k := slot_of(id)
	if k < 0:
		return
	inputs.erase(k)
	main.slots[k].erase("peer")
	if main.state == "title":
		main.slots[k].type = "off"
	else:
		# mid-match: a CPU takes over their ship
		main.slots[k].type = "cpu"
		var s = main.ships[k]
		s.is_cpu = true
		s.bot = BotScript.new(s, main)
	main.fx.text(Vector2(Cfg.W / 2.0, Cfg.H - 60.0), "%s LEFT THE GAME" % Cfg.PNAMES[main.slots[k].color], Color("ff9f1c"))
	_say("A friend disconnected", Color("ff9f1c"))


func _on_connected() -> void:
	my_id = multiplayer.get_unique_id()
	_say("Connected! Waiting for the host's lobby...", Color("5ee87d"))
	_hello.rpc_id(1, Cfg.VERSION)


func _on_failed() -> void:
	leave("Couldn't reach the host. Check the address, and that they're hosting.")


func _on_server_gone() -> void:
	leave("The host closed the game.")


## Which lobby slot belongs to network peer id (-1 = none).
func slot_of(id: int) -> int:
	for k in 4:
		if main.slots[k].get("peer", 0) == id:
			return k
	return -1


func my_slot() -> int:
	return slot_of(my_id) if is_client() else -1


func peer_count() -> int:
	return multiplayer.get_peers().size() if is_host() else 0


## Host: give a peer a seat (an empty one first, then a CPU's).
func _seat(id: int) -> bool:
	var pick := -1
	for k in 4:
		if main.slots[k].type == "off":
			pick = k
			break
	if pick < 0:
		for k in range(3, -1, -1):
			if main.slots[k].type == "cpu":
				pick = k
				break
	if pick < 0:
		return false
	main.slots[pick].type = "net"
	main.slots[pick].peer = id
	main._fix_color(pick)
	if main.teams:
		main._balance_teams()
	inputs[pick] = {"q": [], "cur": _idle(), "last": 0, "ack": 0}
	return true


## Host: called on the title screen; seats anyone who joined mid-match.
func seat_waiting() -> void:
	for id in waiting.duplicate():
		waiting.erase(id)
		if not _seat(id):
			_kick.rpc_id(id, "The lobby is full (4 players).")


static func _idle() -> Dictionary:
	return {"turn": 0.0, "thrust": false, "fire": false}


# ---------------------------------------------------------------- rpcs: client -> host

@rpc("any_peer", "call_remote", "reliable")
func _hello(version: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if version != Cfg.VERSION:
		_kick.rpc_id(id, "Version mismatch: host has v%s, you have v%s. Get the same build." % [Cfg.VERSION, version])
		return
	if main.state != "title":
		waiting.append(id)
		return
	if not _seat(id):
		_kick.rpc_id(id, "The lobby is full (4 players).")


@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _rpc_input(batch: Array) -> void:
	if not is_host():
		return
	var k := slot_of(multiplayer.get_remote_sender_id())
	if k < 0 or not inputs.has(k):
		return
	var d: Dictionary = inputs[k]
	# batch = the last few inputs, oldest first, each [seq, turn, thrust, fire]
	for e in batch:
		if e[0] > d.last:
			d.last = e[0]
			d.q.append([e[0], {"turn": clampf(e[1], -1.0, 1.0), "thrust": bool(e[2]), "fire": bool(e[3])}])
	stat_inputs += 1
	if d.q.size() > 8:
		d.q = d.q.slice(d.q.size() - 3)   # fell behind after a hiccup: catch up


## Host: the input to use for net slot k this tick.
func input_for(k: int) -> Dictionary:
	var d: Dictionary = inputs.get(k, {})
	if d.is_empty():
		return _idle()
	if d.q.size() > 0:
		var e: Array = d.q.pop_front()
		d.ack = e[0]
		d.cur = e[1]
	return d.cur


@rpc("any_peer", "call_remote", "reliable")
func _rpc_action(a: String) -> void:
	if not is_host() or main.state != "title":
		return
	var k := slot_of(multiplayer.get_remote_sender_id())
	var p := a.split(":")
	if k < 0 or p.size() < 2 or int(p[1]) != k or not p[0] in ["color", "hull", "team"]:
		return
	main.menu_action(a, true)


## Client: ask the host to change something about our own seat.
func request(a: String) -> void:
	_send(func(): _rpc_action.rpc_id(1, a))


# ---------------------------------------------------------------- rpcs: host -> client

@rpc("authority", "call_remote", "reliable")
func _kick(reason: String) -> void:
	leave(reason)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _snap(data: PackedByteArray) -> void:
	_recv(func(): _on_snap(bytes_to_var(data.decompress_dynamic(1 << 20, FileAccess.COMPRESSION_DEFLATE))))


@rpc("authority", "call_remote", "reliable")
func _events(t: float, ev: Array) -> void:
	_recv(func():
		for e in ev:
			ev_queue.append([t, e]))


# ---------------------------------------------------------------- host: sending

func event(e: Array) -> void:
	if is_host() and peer_count() > 0:
		events.append(e)


func _physics_process(_dt: float) -> void:
	_run_later()
	if not is_host():
		return
	host_t += main.DT
	tick += 1
	if tick % SEND_EVERY != 0 or peer_count() == 0:
		return
	var data := var_to_bytes(_pack()).compress(FileAccess.COMPRESSION_DEFLATE)
	stat_max_bytes = maxi(stat_max_bytes, data.size())
	_snap.rpc(data)
	if events.size() > 0:
		_events.rpc(host_t, events)
		events = []


func _pack() -> Dictionary:
	var m = main
	var sh := []
	for s in m.ships:
		var ack: int = inputs[s.idx].ack if inputs.has(s.idx) else 0
		sh.append([s.alive, s.position, s.rotation, s.vel, s.thrusting, s.landed, s.invuln, s.shield_up,
				s.missiles, s.effects, s.hull, 0, 0, s.team, s.is_cpu, ack, s.life_t, s.cd])
	var bl := []
	for b in m.bullets:
		bl.append([b.id, b.p, b.v, b.owner, b.bounce])
	var ms := []
	for x in m.missiles:
		ms.append([x.id, x.p, x.v, x.owner])
	var pk := []
	for x in m.pickups:
		pk.append([x.p, x.kind, x.age])
	var d := {"t": host_t, "st": m.state, "tm": m.timer, "msg": m.msg, "mc": m.msg_col, "rn": m.round_n,
		"rt": m.round_t, "sc": m.scores, "ts": m.team_scores, "lv": m.lives, "pt": m.points,
		"rs": m.respawn_t, "mt": m.match_t, "ot": m.overtime, "aw": m.awarded, "sk": m.shake,
		"seed": m.map_seed, "np": m.map_pads, "op": m.map_open, "g": m.gravity, "th": m.map_hash, "ships": sh, "b": bl, "m": ms, "pk": pk}
	# the lobby rarely changes mid-match: send it every snapshot on the title screen, else now and then
	if m.state == "title" or tick % 30 == 0:
		var lobby := []
		for s in m.slots:
			lobby.append([s.type, s.color, s.team, s.hull, s.get("peer", 0)])
		d.lobby = [lobby, m.teams, m.powerups, m.friendly_fire, m.game_mode, m.win_rounds, m.stock_lives, m.time_limit,
				m.gravity_opt, m.open_opt]
	return d


# ---------------------------------------------------------------- client: receiving

func _on_snap(s: Dictionary) -> void:
	if not is_client():
		return
	stat.snaps += 1
	if snaps.size() > 0 and s.t <= snaps[-1].t:
		return
	snaps.append(s)
	if snaps.size() > 40:
		snaps.pop_front()
	if rt < 0.0:
		rt = s.t - INTERP_DELAY
	var m = main
	# lobby + match state: always the newest
	if s.has("lobby"):
		var lb: Array = s.lobby
		for k in 4:
			var e: Array = lb[0][k]
			m.slots[k] = {"type": e[0], "color": e[1], "team": e[2], "hull": e[3], "peer": e[4]}
		m.teams = lb[1]
		m.powerups = lb[2]
		m.friendly_fire = lb[3]
		m.game_mode = lb[4]
		m.win_rounds = lb[5]
		m.stock_lives = lb[6]
		m.time_limit = lb[7]
		m.gravity_opt = lb[8]
		m.open_opt = lb[9]
	if my_slot() >= 0 and status.begins_with("Connected"):
		_say("You're in! The host starts the match.", Color("5ee87d"))
	if s.seed != map_seed:
		map_seed = s.seed
		m.map_open = s.op
		m.terrain.generate(s.seed, s.np, s.op)
		m.bg.regen(s.seed)
		m.map_seed = s.seed
		stat.maps += 1
		if hash(m.terrain.field) != s.th:
			stat.map_mismatch += 1
			push_warning("map differs from the host's")
	m.gravity = s.g   # before replaying our ship's inputs
	var prev_state: String = m.state
	m.state = s.st
	if m.state == "title" and prev_state != "title":
		m.bullets.clear()
		m.missiles.clear()
		m.pickups.clear()
	m.timer = s.tm
	m.msg = s.msg
	m.msg_col = s.mc
	m.round_n = s.rn
	m.round_t = s.rt
	m.scores = s.sc
	m.team_scores = s.ts
	m.lives = s.lv
	m.points = s.pt
	m.respawn_t = s.rs
	m.match_t = s.mt
	m.overtime = s.ot
	m.awarded = s.aw
	m.shake = maxf(m.shake, s.sk)
	var pk := []
	for x in s.pk:
		pk.append({"p": x[0], "kind": x[1], "age": x[2]})
	m.pickups = pk
	_reconcile(s)


## Our own ship: take the host's version, then replay the inputs it hasn't seen yet.
func _reconcile(s: Dictionary) -> void:
	var k := my_slot()
	if k < 0:
		return
	var e: Array = s.ships[k]
	var ship = main.ships[k]
	_apply_static(ship, e)
	if not e[0]:
		ship.alive = false
		ship.visible = false
		pending.clear()
		return
	var was_alive: bool = ship.alive
	var before: Vector2 = ship.position
	var ack: int = e[15]
	while pending.size() > 0 and pending[0][0] <= ack:
		pending.pop_front()
	ship.alive = true
	ship.visible = true
	ship.position = e[1]
	ship.rotation = e[2]
	ship.vel = e[3]
	ship.landed = e[5]
	ship.invuln = e[6]
	ship.effects = e[9].duplicate()
	ship.life_t = e[16]
	ship.cd = e[17]
	if not was_alive:
		pending.clear()   # fresh spawn: nothing to replay
	ship.sim_only = true
	ship.quiet = true
	if _simulating():
		for p in pending:
			ship.step(main.DT, p[1])
	ship.quiet = false
	if was_alive:
		var err: Vector2 = before + ship.vis_off - ship.position
		var d := err.length()
		stat.corr_sum += before.distance_to(ship.position)
		stat.corr_n += 1
		stat.corr_max = maxf(stat.corr_max, before.distance_to(ship.position))
		ship.vis_off = err if d < 60.0 else Vector2.ZERO


func _apply_static(ship, e: Array) -> void:
	ship.thrusting = e[4]
	ship.shield_up = e[7]
	ship.missiles = e[8]
	ship.hull = e[10]
	var c: int = main.slots[ship.idx].color
	ship.color = Cfg.PALETTE[c]
	ship.cname = Cfg.PNAMES[c]
	ship.team = e[13]
	ship.is_cpu = e[14]


func _simulating() -> bool:
	return main.state in ["play", "round_end", "match_end"]


## Client per physics tick: send input, predict our ship, place everything else.
func client_tick(dt: float) -> void:
	var m = main
	m.time += dt
	m.shake *= exp(-dt * 10.0)
	m.fx.update(dt)
	if snaps.is_empty():
		return
	# render clock follows the host clock, INTERP_DELAY behind
	rt += dt
	var target: float = snaps[-1].t - INTERP_DELAY
	if absf(target - rt) > 0.3:
		rt = target
	else:
		rt += (target - rt) * 0.02
	# our own ship
	var k := my_slot()
	if k >= 0 and m.ships[k].alive and _simulating():
		var ship = m.ships[k]
		var inp: Dictionary = Controls.read(0)
		if m.autotest_bot != null:
			inp = m.autotest_bot.think(dt)
		if m.ip_has_focus():
			inp = _idle()
		seq += 1
		pending.append([seq, inp])
		if pending.size() > 240:
			pending.pop_front()
		var batch := []
		for p in pending.slice(maxi(0, pending.size() - 4)):
			batch.append([p[0], p[1].turn, p[1].thrust, p[1].fire])
		_send(func(): _rpc_input.rpc_id(1, batch))
		ship.sim_only = true
		ship.step(dt, inp)
		ship.vis_off *= exp(-dt * 12.0)
	# fx events, in step with the interpolated picture
	while ev_queue.size() > 0 and ev_queue[0][0] <= rt:
		_play(ev_queue.pop_front()[1])
	_interpolate(k)


func _interpolate(mine: int) -> void:
	var m = main
	var a: Dictionary = snaps[0]
	var b: Dictionary = snaps[-1]
	for i in range(snaps.size() - 1, -1, -1):
		if snaps[i].t <= rt:
			a = snaps[i]
			b = snaps[mini(i + 1, snaps.size() - 1)]
			break
	var f := 0.0
	if b.t > a.t:
		f = clampf((rt - a.t) / (b.t - a.t), 0.0, 1.0)
	var ahead := maxf(0.0, rt - b.t)   # past the newest snapshot: extrapolate a little
	ahead = minf(ahead, 0.1)
	for i in 4:
		if i == mine:
			continue
		var s = m.ships[i]
		var ea: Array = a.ships[i]
		var eb: Array = b.ships[i]
		_apply_static(s, eb)
		var on: bool = eb[0] and ea[0]
		if eb[0] and not ea[0]:
			on = f > 0.5   # just respawned
		s.alive = on
		s.visible = on
		if not on:
			continue
		s.position = ea[1].lerp(eb[1], f) + eb[3] * ahead
		s.rotation = lerp_angle(ea[2], eb[2], f)
		s.vel = eb[3]
		s.landed = eb[5]
		s.invuln = eb[6]
		s.effects = eb[9]
		s.life_t = eb[16]
		s.t += m.DT
		if s.thrusting:
			m.fx.exhaust(s.position - s.fwd() * 9.0, s.vel - s.fwd() * 120.0)
		s.queue_redraw()
	if mine >= 0:
		m.ships[mine].queue_redraw()
	# projectiles: match by id across the two snapshots
	var old := {}
	for x in a.b:
		old[x[0]] = x
	var bl := []
	for x in b.b:
		var p: Vector2 = x[1]
		if old.has(x[0]):
			p = old[x[0]][1].lerp(x[1], f)
		bl.append({"id": x[0], "p": p + x[2] * ahead, "v": x[2], "owner": x[3], "bounce": x[4]})
	m.bullets = bl
	var oldm := {}
	for x in a.m:
		oldm[x[0]] = x
	var ms := []
	for x in b.m:
		var p: Vector2 = x[1]
		if oldm.has(x[0]):
			p = oldm[x[0]][1].lerp(x[1], f)
		ms.append({"id": x[0], "p": p, "v": x[2], "owner": x[3]})
		if randf() < 0.6:
			m.fx.exhaust(p - x[2].normalized() * 6.0, -x[2] * 0.3)
	m.missiles = ms


func _play(e: Array) -> void:
	stat.events += 1
	var fx = main.fx
	match e[0]:
		"explode":
			fx.explode(e[1], e[2], e[3])
		"spark":
			fx.spark(e[1], e[2], e[3])
		"text":
			fx.text(e[1], e[2], e[3])


# ---------------------------------------------------------------- fake lag (testing)

func _send(f: Callable) -> void:
	if peer == null:
		return
	if lag > 0.0:
		later.append([Time.get_ticks_msec() + lag * 0.5, f])
	else:
		f.call()


func _recv(f: Callable) -> void:
	_send(f)


func _run_later() -> void:
	var now := Time.get_ticks_msec()
	while later.size() > 0 and later[0][0] <= now:
		later.pop_front()[1].call()


## Addresses friends can type to reach this PC (LAN and Tailscale/ZeroTier style ones first).
static func local_addresses() -> Array:
	var out := []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	out.sort_custom(func(x, y): return x.begins_with("100.") and not y.begins_with("100."))
	return out
