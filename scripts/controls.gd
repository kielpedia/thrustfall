extends RefCounted
## Registers all input actions at startup. Slot i also listens to gamepad i.

#            left        right        thrust     fire
const KEYS := [
	[[KEY_A], [KEY_D], [KEY_W], [KEY_S, KEY_SPACE]],
	[[KEY_LEFT], [KEY_RIGHT], [KEY_UP], [KEY_DOWN, KEY_SLASH]],
	[[KEY_J], [KEY_L], [KEY_I], [KEY_K, KEY_H]],
	[[KEY_KP_4], [KEY_KP_6], [KEY_KP_8], [KEY_KP_5, KEY_KP_0]],
]
const HELP := ["W thrust  A/D turn  S/Space fire", "Up thrust  Left/Right turn  Down fire",
		"I thrust  J/L turn  K fire", "Num8 thrust  Num4/6 turn  Num5 fire"]
const ACTS := ["left", "right", "thrust", "fire"]
const PAD_BUTTONS := [[JOY_BUTTON_DPAD_LEFT], [JOY_BUTTON_DPAD_RIGHT], [JOY_BUTTON_A],
		[JOY_BUTTON_X, JOY_BUTTON_B, JOY_BUTTON_RIGHT_SHOULDER]]
# Stick turning and trigger thrust are read by hand in read(), not through the InputMap:
# some pads (unknown models, DS4Windows / Steam Input doubles) report a trigger or
# stick as fully pressed while it rests, which used to fly the ship into the rock.
# An axis only counts once it has been seen near rest.
const STICK_DEAD := 0.3
const TRIGGER_ON := 0.5
const REST := 0.2

static var _armed := {}       # "device:pad guid:axis" -> true once seen at rest


static func setup() -> void:
	for i in 4:
		for a in 4:
			var name := "p%d_%s" % [i, ACTS[a]]
			_ensure(name)
			for k in KEYS[i][a]:
				var e := InputEventKey.new()
				e.physical_keycode = k
				InputMap.action_add_event(name, e)
			for b in PAD_BUTTONS[a]:
				var e := InputEventJoypadButton.new()
				e.device = i
				e.button_index = b
				InputMap.action_add_event(name, e)
	_ensure("start")
	for k in [KEY_ENTER, KEY_KP_ENTER]:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event("start", e)
	var s := InputEventJoypadButton.new()
	s.device = -1
	s.button_index = JOY_BUTTON_START
	InputMap.action_add_event("start", s)
	_ensure("back")
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	InputMap.action_add_event("back", esc)
	var bk := InputEventJoypadButton.new()
	bk.device = -1
	bk.button_index = JOY_BUTTON_BACK
	InputMap.action_add_event("back", bk)


static func _ensure(name: String) -> void:
	if not InputMap.has_action(name):
		InputMap.add_action(name, 0.3)


## Value of a pad axis, or 0 until that axis has been seen resting near 0.
static func _axis(dev: int, axis: int) -> float:
	var v := Input.get_joy_axis(dev, axis)
	# keyed by the pad's id too, so a different pad plugged into this slot starts unarmed
	var guid := Input.get_joy_guid(dev) if Input.get_connected_joypads().has(dev) else "-"
	var key := "%d:%s:%d" % [dev, guid, axis]
	if absf(v) < REST:
		_armed[key] = true
	return v if _armed.get(key, false) else 0.0


static func read(i: int) -> Dictionary:
	var turn := Input.get_axis("p%d_left" % i, "p%d_right" % i)
	var stick := _axis(i, JOY_AXIS_LEFT_X)
	if absf(stick) > STICK_DEAD:
		turn = clampf(turn + stick, -1.0, 1.0)
	return {
		"turn": turn,
		"thrust": Input.is_action_pressed("p%d_thrust" % i) or _axis(i, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER_ON,
		"fire": Input.is_action_pressed("p%d_fire" % i),
	}
