extends RefCounted
## Ship hulls. Each hull's hitbox follows its drawn outline (see hit_data).
## Coordinates: ship points up, roughly x -10..10, y -13..9.
##   polys: filled + outlined shapes   lit: light-colored windows   dot: cockpit [center, radius]
##   lines: detail strokes [a, b] (solid only if "hit_lines")       flame: y where the booster flame starts

const HULLS := [
	{"name": "DART", "flame": 6.0, "dot": [Vector2(0, -2), 2.5],
		"polys": [[Vector2(0, -11), Vector2(8, 8), Vector2(0, 5), Vector2(-8, 8)]]},
	{"name": "DELTA", "flame": 7.0,
		"polys": [[Vector2(0, -12), Vector2(9, 7), Vector2(-9, 7)]],
		"lit": [[Vector2(0, -6), Vector2(2.5, 0), Vector2(-2.5, 0)]],
		"lines": [[Vector2(-5, 3), Vector2(5, 3)]]},
	{"name": "LANDER", "flame": 3.0, "hit_lines": true,
		"polys": [[Vector2(-5, -5), Vector2(5, -5), Vector2(7, 3), Vector2(-7, 3)],
			[Vector2(-4, -5), Vector2(-2.8, -8.5), Vector2(0, -10), Vector2(2.8, -8.5), Vector2(4, -5)]],
		"lines": [[Vector2(-6, 9), Vector2(-4, 3)], [Vector2(6, 9), Vector2(4, 3)],
			[Vector2(-8, 9), Vector2(-4, 9)], [Vector2(4, 9), Vector2(8, 9)]]},
	{"name": "TWIN POD", "flame": 6.0, "dot": [Vector2(0, -4), 2.0],
		"polys": [[Vector2(0, -12), Vector2(3, -3), Vector2(8, -1), Vector2(8, 9), Vector2(4, 6),
			Vector2(-4, 6), Vector2(-8, 9), Vector2(-8, -1), Vector2(-3, -3)]],
		"lines": [[Vector2(-6, 1), Vector2(-6, 6)], [Vector2(6, 1), Vector2(6, 6)]]},
	{"name": "NEEDLE", "flame": 6.0, "dot": [Vector2(0, -4), 1.6],
		"polys": [[Vector2(0, -13), Vector2(3, 0), Vector2(5, 9), Vector2(0, 6), Vector2(-5, 9), Vector2(-3, 0)]]},
	{"name": "BATWING", "flame": 5.0, "dot": [Vector2(0, -2), 2.0],
		"polys": [[Vector2(0, -10), Vector2(4, -2), Vector2(10, 4), Vector2(6, 9), Vector2(0, 5),
			Vector2(-6, 9), Vector2(-10, 4), Vector2(-4, -2)]]},
	{"name": "BRICK", "flame": 9.0,
		"polys": [[Vector2(-4, -10), Vector2(4, -10), Vector2(8, -2), Vector2(8, 6), Vector2(3, 9),
			Vector2(-3, 9), Vector2(-8, 6), Vector2(-8, -2)]],
		"lit": [[Vector2(-3, -7), Vector2(3, -7), Vector2(3, -3), Vector2(-3, -3)]],
		"lines": [[Vector2(-8, 2), Vector2(8, 2)]]},
	{"name": "MANTA", "flame": 4.0, "hit_lines": true, "dot": [Vector2(0, -2), 2.0],
		"polys": [[Vector2(0, -8), Vector2(4.4, -5.5), Vector2(7.5, -2), Vector2(9.4, 2.5), Vector2(10, 8),
			Vector2(0, 4), Vector2(-10, 8), Vector2(-9.4, 2.5), Vector2(-7.5, -2), Vector2(-4.4, -5.5)]],
		"lines": [[Vector2(-3, -11), Vector2(-1, -7)], [Vector2(3, -11), Vector2(1, -7)]]},
	{"name": "TRIDENT", "flame": 6.0, "dot": [Vector2(0, 0), 2.0],
		"polys": [[Vector2(0, -13), Vector2(2, -4), Vector2(6, -9), Vector2(6, 2), Vector2(8, 9),
			Vector2(0, 6), Vector2(-8, 9), Vector2(-6, 2), Vector2(-6, -9), Vector2(-2, -4)]]},
	{"name": "SAUCER", "flame": 6.0, "dot": [Vector2(0, -1), 2.2],
		"polys": [[Vector2(0, -12), Vector2(2, -5), Vector2(-2, -5)],
			[Vector2(-10, 2), Vector2(-5, -3.25), Vector2(0, -5), Vector2(5, -3.25), Vector2(10, 2),
			Vector2(6, 6), Vector2(-6, 6)]]},
]


# ------------------------------------------------------------------ collision
# Hitboxes follow the drawn outline: points every few px along every polygon edge
# (plus external details like the Lander's legs). The lowest points are the landing feet.

static var _cache := {}


## [points, is_foot, bottom_y, polys, segments] for hull i (built once).
static func hit_data(i: int) -> Array:
	if _cache.has(i):
		return _cache[i]
	var h: Dictionary = HULLS[i]
	var segs := []
	var polys := []
	for poly in h.polys:
		polys.append(PackedVector2Array(poly))
		for k in poly.size():
			segs.append([poly[k], poly[(k + 1) % poly.size()]])
	if h.get("hit_lines", false):
		for ln in h.lines:
			segs.append([ln[0], ln[1]])
	var pts := PackedVector2Array()
	for s in segs:
		var n := maxi(1, ceili(s[0].distance_to(s[1]) / 3.0))
		for j in n + 1:
			pts.append(s[0].lerp(s[1], float(j) / n))
	var bottom := -1e9
	for p in pts:
		bottom = maxf(bottom, p.y)
	var feet := PackedByteArray()
	for p in pts:
		feet.append(1 if p.y >= bottom - 1.5 else 0)
	_cache[i] = [pts, feet, bottom, polys, segs]
	return _cache[i]


## Lowest point of the hull (where it rests on the ground).
static func bottom(i: int) -> float:
	return hit_data(i)[2]


## Is a ship-local point inside hull i (or within margin px of its outline)?
static func contains(i: int, local: Vector2, margin: float) -> bool:
	var d := hit_data(i)
	for poly in d[3]:
		if Geometry2D.is_point_in_polygon(local, poly):
			return true
	if margin > 0.0:
		for s in d[4]:
			if local.distance_to(Geometry2D.get_closest_point_to_segment(local, s[0], s[1])) < margin:
				return true
	return false


static func count() -> int:
	return HULLS.size()


static func hull_name(i: int) -> String:
	return HULLS[i].name


static func flame_y(i: int) -> float:
	return HULLS[i].flame


## Draw hull i onto canvas item ci (call from inside ci's _draw).
static func draw(ci: CanvasItem, i: int, at: Vector2, col: Color, s := 1.0) -> void:
	var h: Dictionary = HULLS[i]
	var dark := col.darkened(0.55)
	var light := col.lightened(0.5)
	for poly in h.polys:
		var pts := PackedVector2Array()
		for p in poly:
			pts.append(at + p * s)
		ci.draw_colored_polygon(pts, dark)
		pts.append(pts[0])
		ci.draw_polyline(pts, col, 2.0)
	for ln in h.get("lines", []):
		ci.draw_line(at + ln[0] * s, at + ln[1] * s, col, 1.5)
	for poly in h.get("lit", []):
		var pts := PackedVector2Array()
		for p in poly:
			pts.append(at + p * s)
		ci.draw_colored_polygon(pts, light)
	if h.has("dot"):
		ci.draw_circle(at + h.dot[0] * s, h.dot[1] * s, light)
