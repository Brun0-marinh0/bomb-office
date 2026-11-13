extends Control
## Controles de toque para celular: analógico virtual à esquerda,
## botões BOMBA e AÇÃO à direita.

signal bomb_pressed
signal action_pressed

const DEAD_ZONE := 18.0
const STICK_R := 70.0

var dir := Vector2i.ZERO
var _stick_index := -1
var _origin := Vector2.ZERO
var _knob := Vector2.ZERO
var _flash_bomb := 0.0
var _flash_action := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _bomb_center() -> Vector2:
	return Vector2(size.x - 120, size.y - 120)


func _action_center() -> Vector2:
	return Vector2(size.x - 270, size.y - 75)


func _default_stick() -> Vector2:
	return Vector2(150, size.y - 140)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var p: Vector2 = (make_input_local(event) as InputEventScreenTouch).position
		if event.pressed:
			if p.x < size.x * 0.45:
				_stick_index = event.index
				_origin = p
				_knob = p
				_update_dir()
			elif p.y > size.y * 0.3:
				if p.distance_to(_bomb_center()) <= p.distance_to(_action_center()):
					_flash_bomb = 0.15
					bomb_pressed.emit()
				else:
					_flash_action = 0.15
					action_pressed.emit()
		elif event.index == _stick_index:
			_stick_index = -1
			dir = Vector2i.ZERO
		queue_redraw()
	elif event is InputEventScreenDrag and event.index == _stick_index:
		_knob = (make_input_local(event) as InputEventScreenDrag).position
		_update_dir()
		queue_redraw()


func _update_dir() -> void:
	var v := _knob - _origin
	if v.length() < DEAD_ZONE:
		dir = Vector2i.ZERO
	elif absf(v.x) > absf(v.y):
		dir = Vector2i(int(signf(v.x)), 0)
	else:
		dir = Vector2i(0, int(signf(v.y)))


func _process(dt: float) -> void:
	if _flash_bomb > 0.0 or _flash_action > 0.0:
		_flash_bomb = maxf(0.0, _flash_bomb - dt)
		_flash_action = maxf(0.0, _flash_action - dt)
		queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var base := _origin if _stick_index >= 0 else _default_stick()
	draw_circle(base, STICK_R, Color(1, 1, 1, 0.12))
	draw_arc(base, STICK_R, 0, TAU, 48, Color(1, 1, 1, 0.35), 2.0)
	var knob := base
	if _stick_index >= 0:
		knob = base + (_knob - _origin).limit_length(STICK_R)
	draw_circle(knob, 30, Color(1, 1, 1, 0.35))
	var bc := _bomb_center()
	draw_circle(bc, 62, Color(0.95, 0.3, 0.25, 0.55 if _flash_bomb > 0 else 0.35))
	draw_string(font, bc + Vector2(-60, 7), "BOMBA", HORIZONTAL_ALIGNMENT_CENTER, 120, 20, Color.WHITE)
	var ac := _action_center()
	draw_circle(ac, 46, Color(0.3, 0.55, 1.0, 0.55 if _flash_action > 0 else 0.35))
	draw_string(font, ac + Vector2(-46, 6), "AÇÃO", HORIZONTAL_ALIGNMENT_CENTER, 92, 17, Color.WHITE)
