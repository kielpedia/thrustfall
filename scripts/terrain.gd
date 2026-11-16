extends Node2D
## Random cave/asteroid map. The world is a grid of density values (0 = open, 1 = rock).
## Rock is wherever the bilinear-interpolated density is >= 0.5, drawn with marching squares.

const Cfg = preload("res://scripts/cfg.gd")

const NB := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]
const NB4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var field := PackedFloat32Array()
var clearance := PackedInt32Array()   # grid steps to the nearest rock node
var pads: Array[Vector2i] = []        # landing pads (open node just above a flat floor)
var rock_col := Color("2b2445")
var edge_col := Color("9d86ff")
var pad_col := Color("5ef2ff")
var open_frac := 0.0                  # share of the map that is open space


func i_of(x: int, y: int) -> int:
	return y * Cfg.GW + x


func val(x: int, y: int) -> float:
	if x < 0 or y < 0 or x >= Cfg.GW or y >= Cfg.GH:
		return 1.0
	return field[y * Cfg.GW + x]


func solid_at(p: Vector2) -> bool:
	var fx := p.x / Cfg.CELL
	var fy := p.y / Cfg.CELL
	if fx <= 0.0 or fy <= 0.0 or fx >= Cfg.GW - 1 or fy >= Cfg.GH - 1:
		return true
	var x0 := int(fx)
	var y0 := int(fy)
	var tx := fx - x0
	var ty := fy - y0
	var i := y0 * Cfg.GW + x0
	var top := lerpf(field[i], field[i + 1], tx)
	var bot := lerpf(field[i + Cfg.GW], field[i + Cfg.GW + 1], tx)
	return lerpf(top, bot, ty) >= 0.5


## Distance along dir until rock, capped at max_d.
func ray_dist(p: Vector2, dir: Vector2, max_d: float) -> float:
	var d := 5.0
	while d < max_d:
		if solid_at(p + dir * d):
			return d
		d += 5.0
	return max_d


func clear_line(a: Vector2, b: Vector2) -> bool:
	var n := int(a.distance_to(b) / 5.0) + 1
	for k in n:
		if solid_at(a.lerp(b, float(k) / n)):
			return false
	return true


func node_at(p: Vector2) -> int:
	var x := clampi(roundi(p.x / Cfg.CELL), 0, Cfg.GW - 1)
	var y := clampi(roundi(p.y / Cfg.CELL), 0, Cfg.GH - 1)
	return i_of(x, y)


func node_pos(i: int) -> Vector2:
	return Vector2(i % Cfg.GW, i / Cfg.GW) * Cfg.CELL


func clearance_at(p: Vector2) -> int:
	return clearance[node_at(p)]


func pad_spawn(k: int) -> Vector2:
	var n := pads[k]
	return Vector2(n.x * Cfg.CELL, (n.y + 0.5) * Cfg.CELL)   # pad surface


# ------------------------------------------------------------------ pathing for bots

## BFS distance (grid steps) from p over nodes with enough room to fly. -1 = unreachable.
func flow_to(p: Vector2, min_clear := 2) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(Cfg.GW * Cfg.GH)
	dist.fill(-1)
	var start := node_at(p)
	dist[start] = 0
	var q := PackedInt32Array([start])
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		var cx := c % Cfg.GW
		var cy := c / Cfg.GW
		for d in NB:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= Cfg.GW or ny >= Cfg.GH:
				continue
			var ni := ny * Cfg.GW + nx
			if dist[ni] == -1 and clearance[ni] >= min_clear:
				dist[ni] = dist[c] + 1
				q.append(ni)
	return dist


## Follow the flow field downhill a few steps from p and return that point.
func flow_waypoint(p: Vector2, dist: PackedInt32Array, steps: int) -> Vector2:
	var c := node_at(p)
	if dist[c] < 0:
		# off the flyable area: hop to the best nearby flyable node
		var best := -1
		var best_score := 1e9
		var cx := c % Cfg.GW
		var cy := c / Cfg.GW
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				var nx := cx + dx
				var ny := cy + dy
				if nx < 0 or ny < 0 or nx >= Cfg.GW or ny >= Cfg.GH:
					continue
				var ni := i_of(nx, ny)
				if dist[ni] >= 0:
					var s := dist[ni] + 2.0 * sqrt(dx * dx + dy * dy)
					if s < best_score:
						best_score = s
						best = ni
		if best < 0:
			return p
		c = best
	for k in steps:
		var cx := c % Cfg.GW
		var cy := c / Cfg.GW
		var nxt := c
		for d in NB:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= Cfg.GW or ny >= Cfg.GH:
				continue
			var ni := ny * Cfg.GW + nx
			if dist[ni] >= 0 and dist[ni] < dist[nxt]:
				nxt = ni
		if nxt == c:
			break
		c = nxt
	return node_pos(c)


# ------------------------------------------------------------------ generation

## Builds a new map with n_pads spread-out landing pads. Returns false if it had to give up.
## open = fraction of the map that should be open space (0.4-0.85), or < 0 for anything 50-85%.
func generate(seed: int, n_pads: int, open := -1.0) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var ok := false
	for attempt in 60:
		if _try(rng, n_pads, open):
			ok = true
			break
	if not ok and open > 0.0:
		# couldn't hit that exact size: settle for any good map rather than a broken one
		for attempt in 60:
			if _try(rng, n_pads, -1.0):
				ok = true
				break
	var hue := rng.randf()
	rock_col = Color.from_hsv(hue, 0.45, 0.24)
	edge_col = Color.from_hsv(hue, 0.5, 0.95)
	pad_col = Color.from_hsv(fmod(hue + 0.5, 1.0), 0.6, 1.0)
	queue_redraw()
	return ok


func _try(rng: RandomNumberGenerator, n_pads: int, want: float) -> bool:
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = rng.randf_range(0.045, 0.075)
	noise.fractal_octaves = 3
	var edge := FastNoiseLite.new()
	edge.seed = rng.randi()
	edge.frequency = 0.1
	var thr := rng.randf_range(0.1, 0.24)
	var floor_h := rng.randf_range(2.0, 4.5)
	# very open maps need thinner border walls to have room
	var wall_k := clampf((0.86 - want) / 0.16, 0.35, 1.0) if want > 0.0 else 1.0

	field.resize(Cfg.GW * Cfg.GH)
	var raw := PackedFloat32Array()
	raw.resize(field.size())
	var wall := PackedFloat32Array()
	wall.resize(field.size())
	var inner := PackedFloat32Array()   # noise values where the border walls leave room
	for y in Cfg.GH:
		for x in Cfg.GW:
			var i := i_of(x, y)
			var e := (edge.get_noise_2d(x, y) + 1.0) * 0.5
			var side := mini(mini(x, Cfg.GW - 1 - x), y)
			var v_side := (1.2 + e * 2.5 * wall_k - side) * 0.7 + 0.5
			var v_floor := (floor_h * wall_k + e * 4.0 * wall_k - (Cfg.GH - 1 - y)) * 0.7 + 0.5
			raw[i] = noise.get_noise_2d(x, y)
			wall[i] = 1.0 if x == 0 or y == 0 or x == Cfg.GW - 1 or y == Cfg.GH - 1 else maxf(v_side, v_floor)
			if wall[i] < 0.5:
				inner.append(raw[i])
	if want > 0.0:
		# pick the rock threshold that opens up the wanted share of the map
		# (+1% because sealed pockets and pad shelves get filled in afterwards)
		inner.sort()
		var k := int((want + 0.01) * field.size())
		if k >= inner.size():
			return false   # these border walls leave too little room; try another layout
		thr = inner[k]
	for i in field.size():
		field[i] = clampf(maxf((raw[i] - thr) * 4.0 + 0.5, wall[i]), 0.0, 1.0)

	_remove_specks()
	_keep_main_cave()
	var open := 0
	for v in field:
		if v < 0.5:
			open += 1
	var frac := float(open) / field.size()
	if want > 0.0:
		if absf(frac - want) > 0.05:
			return false
	elif frac < 0.5 or frac > 0.85:
		return false
	open_frac = frac
	if not _place_pads(rng, n_pads):
		return false
	_keep_main_cave()
	_compute_clearance()
	# every pad must be reachable by flying from the first one
	var f := flow_to(node_pos(i_of(pads[0].x, pads[0].y - 2)))
	for p in pads:
		if f[i_of(p.x, p.y - 2)] < 0:
			return false
	return true


func _region(start: int, solid: bool, seen: PackedByteArray) -> PackedInt32Array:
	var q := PackedInt32Array([start])
	seen[start] = 1
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		var cx := c % Cfg.GW
		var cy := c / Cfg.GW
		for d in NB4:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= Cfg.GW or ny >= Cfg.GH:
				continue
			var ni := ny * Cfg.GW + nx
			if seen[ni] == 0 and (field[ni] >= 0.5) == solid:
				seen[ni] = 1
				q.append(ni)
	return q


## Tiny floating rocks are just annoying; dissolve them.
func _remove_specks() -> void:
	var seen := PackedByteArray()
	seen.resize(field.size())
	for i in field.size():
		if seen[i] == 0 and field[i] >= 0.5:
			var r := _region(i, true, seen)
			if r.size() < 6:
				for c in r:
					field[c] = 0.0


## Fill every sealed-off pocket so the open area is one connected cave.
func _keep_main_cave() -> void:
	var seen := PackedByteArray()
	seen.resize(field.size())
	var regions := []
	for i in field.size():
		if seen[i] == 0 and field[i] < 0.5:
			regions.append(_region(i, false, seen))
	regions.sort_custom(func(a, b): return a.size() > b.size())
	for k in range(1, regions.size()):
		for c in regions[k]:
			field[c] = 1.0


func _compute_clearance() -> void:
	clearance.resize(field.size())
	clearance.fill(-1)
	var q := PackedInt32Array()
	for i in field.size():
		if field[i] >= 0.5:
			clearance[i] = 0
			q.append(i)
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		var cx := c % Cfg.GW
		var cy := c / Cfg.GW
		for d in NB:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= Cfg.GW or ny >= Cfg.GH:
				continue
			var ni := ny * Cfg.GW + nx
			if clearance[ni] == -1:
				clearance[ni] = clearance[c] + 1
				q.append(ni)


func _place_pads(rng: RandomNumberGenerator, n: int) -> bool:
	var cands: Array[Vector2i] = []
	for y in range(5, Cfg.GH - 3):
		for x in range(4, Cfg.GW - 4):
			var good := true
			var open_above := 0
			for dx in range(-2, 3):
				if val(x + dx, y) >= 0.5:
					good = false
					break
				if val(x + dx, y + 1) < 0.5 and val(x + dx, y + 2) < 0.5:
					good = false
					break
				for dy in range(1, 5):
					if val(x + dx, y - dy) < 0.5:
						open_above += 1
			if good and open_above >= 17:
				cands.append(Vector2i(x, y))
	if cands.size() < n:
		return false
	pads.clear()
	pads.append(cands[rng.randi() % cands.size()])
	while pads.size() < n:
		var best := Vector2i(-1, -1)
		var best_d := -1.0
		for c in cands:
			var md := 1e9
			for p in pads:
				md = minf(md, Vector2(c - p).length())
			if md > best_d:
				best_d = md
				best = c
		if best_d < 14.0:
			return false
		pads.append(best)
	# flatten each pad: solid floor below, open space above
	for p in pads:
		for dx in range(-2, 3):
			field[i_of(p.x + dx, p.y + 1)] = 1.0
			field[i_of(p.x + dx, p.y + 2)] = 1.0
		for dx in range(-3, 4):
			for dy in range(0, 5):
				var x := p.x + dx
				var y := p.y - dy
				if x > 0 and x < Cfg.GW - 1 and y > 0 and not (absi(dx) == 3 and dy == 0):
					field[i_of(x, y)] = 0.0
	return true


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	if field.is_empty():
		return
	var C := float(Cfg.CELL)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var edges := PackedVector2Array()
	for cy in Cfg.GH - 1:
		for cx in Cfg.GW - 1:
			var vals := [field[i_of(cx, cy)], field[i_of(cx + 1, cy)], field[i_of(cx + 1, cy + 1)], field[i_of(cx, cy + 1)]]
			var n_solid := 0
			for v in vals:
				if v >= 0.5:
					n_solid += 1
			if n_solid == 0:
				continue
			var base := Vector2(cx, cy) * C
			if n_solid == 4:
				draw_rect(Rect2(base, Vector2(C, C)), rock_col)
				continue
			# walk the square's corners, emitting rock corners and edge crossings
			var poly := PackedVector2Array()
			var cross := []   # [point, is_exit]
			for k in 4:
				var a: float = vals[k]
				var b: float = vals[(k + 1) % 4]
				var pa: Vector2 = base + corners[k] * C
				var pb: Vector2 = base + corners[(k + 1) % 4] * C
				if a >= 0.5:
					poly.append(pa)
				if (a >= 0.5) != (b >= 0.5):
					var pt := pa.lerp(pb, clampf((0.5 - a) / (b - a), 0.03, 0.97))
					poly.append(pt)
					cross.append([pt, a >= 0.5])
			if poly.size() >= 3:
				draw_colored_polygon(poly, rock_col)
			# pair each exit (rock -> air) with the next entry (air -> rock)
			for k in cross.size():
				if cross[k][1]:
					edges.append(cross[k][0])
					edges.append(cross[(k + 1) % cross.size()][0])
	if edges.size() > 0:
		draw_multiline(edges, edge_col, 2.0)
	for p in pads:
		var y := (p.y + 0.5) * C
		var x0 := (p.x - 2) * C
		var x1 := (p.x + 2) * C
		draw_line(Vector2(x0, y), Vector2(x1, y), pad_col, 3.0)
		draw_circle(Vector2(x0, y), 3.0, pad_col)
		draw_circle(Vector2(x1, y), 3.0, pad_col)
