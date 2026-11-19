extends Control
## Controles de toque para celular (visíveis e semitransparentes):
## direcional (cruz) fixo à esquerda, botões BOMBA e AÇÃO à direita.
## O direcional aceita arrastar o dedo entre as setas sem soltar.

signal bomb_pressed
signal action_pressed

const DEAD_ZONE := 18.0
const PAD_STEP := 74.0      # distância do centro do direcional até cada seta
const PAD_KEY := 68.0       # tamanho de cada seta
const BOMB_R := 66.0
const ACTION_R := 48.0
const MARGIN := 36.0
const LIFT := 80.0         # quanto os controles sobem em relação à borda de baixo

const FILL := Color(1, 1, 1, 0.16)
const FILL_ON := Color(1, 1, 1, 0.45)
const BORDER := Color(1, 1, 1, 0.55)
const ARROW := Color(1, 1, 1, 0.8)
const BOMB_FILL := Color(0.95, 0.3, 0.25, 0.32)
const BOMB_ON := Color(0.95, 0.3, 0.25, 0.65)
const ACTION_FILL := Color(0.3, 0.55, 1.0, 0.32)
const ACTION_ON := Color(0.3, 0.55, 1.0, 0.65)

const DIRS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

var dir := Vector2i.ZERO
var _pad_index := -1
var _flash_bomb := 0.0
var _flash_action := 0.0
var _key_style := StyleBoxFlat.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_style.set_corner_radius_all(14)
	_key_style.set_border_width_all(3)
	_key_style.border_color = BORDER
	_key_style.anti_aliasing = true


func _pad_center() -> Vector2:
	var r := PAD_STEP + PAD_KEY * 0.5
	return Vector2(MARGIN + r, size.y - MARGIN - LIFT - r)


func _bomb_center() -> Vector2:
	return Vector2(size.x - MARGIN - BOMB_R, size.y - MARGIN - LIFT - BOMB_R - 10)


func _action_center() -> Vector2:
	return _bomb_center() + Vector2(-BOMB_R - ACTION_R - 30, 40)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var p: Vector2 = (make_input_local(event) as InputEventScreenTouch).position
		if event.pressed:
			if p.x < size.x * 0.45 and p.y > size.y * 0.25:
				_pad_index = event.index
				_update_dir(p)
			elif p.x >= size.x * 0.45 and p.y > size.y * 0.3:
				if p.distance_to(_bomb_center()) <= p.distance_to(_action_center()):
					_flash_bomb = 0.15
					bomb_pressed.emit()
				else:
					_flash_action = 0.15
					action_pressed.emit()
		elif event.index == _pad_index:
			_pad_index = -1
			dir = Vector2i.ZERO
		queue_redraw()
	elif event is InputEventScreenDrag and event.index == _pad_index:
		_update_dir((make_input_local(event) as InputEventScreenDrag).position)
		queue_redraw()


func _update_dir(p: Vector2) -> void:
	var v := p - _pad_center()
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
	# direcional
	var c := _pad_center()
	draw_circle(c, PAD_STEP + PAD_KEY * 0.75, Color(0, 0, 0, 0.18))
	for d in DIRS:
		var kc: Vector2 = c + Vector2(d) * PAD_STEP
		_key_style.bg_color = FILL_ON if dir == d else FILL
		draw_style_box(_key_style, Rect2(kc - Vector2.ONE * PAD_KEY * 0.5, Vector2.ONE * PAD_KEY))
		var fwd := Vector2(d)
		var side := Vector2(-fwd.y, fwd.x)
		draw_colored_polygon(PackedVector2Array([
			kc + fwd * 16, kc - fwd * 10 + side * 16, kc - fwd * 10 - side * 16]), ARROW)
	# bomba
	var bc := _bomb_center()
	draw_circle(bc, BOMB_R, BOMB_ON if _flash_bomb > 0 else BOMB_FILL)
	draw_arc(bc, BOMB_R, 0, TAU, 64, BORDER, 3.0, true)
	draw_circle(bc + Vector2(0, -14), 17, Color(0.1, 0.1, 0.12, 0.85))
	draw_line(bc + Vector2(10, -29), bc + Vector2(18, -38), Color(1, 0.8, 0.3, 0.9), 3.0)
	draw_string(font, bc + Vector2(-BOMB_R, 28), "BOMBA", HORIZONTAL_ALIGNMENT_CENTER, BOMB_R * 2, 18, Color(1, 1, 1, 0.9))
	# ação
	var ac := _action_center()
	draw_circle(ac, ACTION_R, ACTION_ON if _flash_action > 0 else ACTION_FILL)
	draw_arc(ac, ACTION_R, 0, TAU, 48, BORDER, 3.0, true)
	draw_string(font, ac + Vector2(-ACTION_R, 6), "AÇÃO", HORIZONTAL_ALIGNMENT_CENTER, ACTION_R * 2, 17, Color(1, 1, 1, 0.9))
