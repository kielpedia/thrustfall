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
const PAD_AXES := [[JOY_AXIS_LEFT_X, -1.0], [JOY_AXIS_LEFT_X, 1.0], [JOY_AXIS_TRIGGER_RIGHT, 1.0], []]


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
			if PAD_AXES[a].size() > 0:
				var e := InputEventJoypadMotion.new()
				e.device = i
				e.axis = PAD_AXES[a][0]
				e.axis_value = PAD_AXES[a][1]
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


static func read(i: int) -> Dictionary:
	return {
		"turn": Input.get_axis("p%d_left" % i, "p%d_right" % i),
		"thrust": Input.is_action_pressed("p%d_thrust" % i),
		"fire": Input.is_action_pressed("p%d_fire" % i),
	}
