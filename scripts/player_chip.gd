extends Control
## Jogador no placar do topo: quadrado da cor + nome + vitórias.
## Morto: X vermelho sobre a cor, nome riscado e apagado (não depende só da opacidade).

const G = preload("res://scripts/g.gd")
const DEAD := Color(1.0, 0.3, 0.25)
const PX := 15

var color_idx := 0
var text := ""
var alive := true
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_resize()


func set_state(t: String, is_alive: bool, col: int) -> void:
	if t == text and is_alive == alive and col == color_idx:
		return
	text = t
	alive = is_alive
	color_idx = col
	_resize()
	queue_redraw()


func _resize() -> void:
	if _font == null:
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, PX).x
	custom_minimum_size = Vector2(16 + 6 + w, 20)


func _draw() -> void:
	var sw := Rect2(Vector2(0, 2), Vector2(16, 16))
	var col := G.player_color(color_idx)
	if not alive:
		col = col.darkened(0.55)
	draw_rect(sw, col)
	var tcol := Color.WHITE if alive else Color(0.65, 0.65, 0.65)
	var base := Vector2(22, 15)
	draw_string_outline(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, PX, 3, Color(0, 0, 0, 0.85))
	draw_string(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, PX, tcol)
	if not alive:
		# X sobre a cor e risco no nome
		draw_line(sw.position + Vector2(2, 2), sw.end - Vector2(2, 2), DEAD, 2.5)
		draw_line(Vector2(sw.position.x + 2, sw.end.y - 2), Vector2(sw.end.x - 2, sw.position.y + 2), DEAD, 2.5)
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, PX).x
		draw_line(Vector2(base.x - 1, 10), Vector2(base.x + w + 1, 10), DEAD, 2.0)
