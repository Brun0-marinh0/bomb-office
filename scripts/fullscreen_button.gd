extends Button
## Botão de tela cheia para celular (some a barra de endereço do navegador).
## Semitransparente, fica no canto superior direito.

const SIZE := 56.0

var _on := false
var _poll := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Tela cheia"
	for st in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.45 if st == "pressed" else 0.3)
		sb.border_color = Color(1, 1, 1, 0.5)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(12)
		add_theme_stylebox_override(st, sb)
	pressed.connect(func():
		Net.set_fullscreen(not Net.is_fullscreen())
		_poll = 0.0)


func _process(dt: float) -> void:
	_poll -= dt
	if _poll > 0.0:
		return
	_poll = 0.4
	var on := Net.is_fullscreen()
	if on != _on:
		_on = on
		queue_redraw()


func _draw() -> void:
	# quatro cantos: para fora = entrar em tela cheia, para dentro = sair
	var col := Color(1, 1, 1, 0.85)
	var s := size
	var a := 14.0    # recuo da borda
	var l := 10.0    # tamanho do traço
	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var sx := 1.0 if corner.x == 0 else -1.0
		var sy := 1.0 if corner.y == 0 else -1.0
		var p := Vector2(a if corner.x == 0 else s.x - a, a if corner.y == 0 else s.y - a)
		if _on:
			p += Vector2(sx, sy) * l
			draw_line(p, p - Vector2(sx * l, 0), col, 3.0)
			draw_line(p, p - Vector2(0, sy * l), col, 3.0)
		else:
			draw_line(p, p + Vector2(sx * l, 0), col, 3.0)
			draw_line(p, p + Vector2(0, sy * l), col, 3.0)
