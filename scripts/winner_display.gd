extends Control
## Vencedor no modal de fim de rodada: sprite comemorando (ampliado, na cor do jogador)
## e, acima dele, a mensagem do vencedor em maiúsculas com onda e arco-íris por letra.

const G = preload("res://scripts/g.gd")
const SPRITE_SCALE := 4.0
const FONT_SIZE := 30

var color := Color.WHITE
var message := ""
var _t := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(460, G.TILE * SPRITE_SCALE + 64)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_winner(c: Color) -> void:
	color = c
	message = ""
	_t = 0.0


func _process(dt: float) -> void:
	if is_visible_in_tree():
		_t += dt
		queue_redraw()


func _draw() -> void:
	var sprite_size := G.TILE * SPRITE_SCALE
	var sprite_pos := Vector2((size.x - sprite_size) * 0.5, size.y - sprite_size)
	var rect := Rect2(sprite_pos, Vector2(sprite_size, sprite_size))
	var frames: Array = Sprites.frames("victory")
	if frames.is_empty():
		draw_texture_rect(Sprites.tex("player"), rect, false, color)
	else:
		# vai e volta pelos quadros de comemoração
		var n := frames.size()
		var i := int(_t * 6.0) % maxi(1, n * 2 - 2)
		if i >= n:
			i = n * 2 - 2 - i
		draw_texture_rect(frames[i], rect, false, color)
	if message != "":
		_draw_wave_text(Vector2(size.x * 0.5, sprite_pos.y - 10))


func _draw_wave_text(bottom_center: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var widths: Array = []
	var total := 0.0
	for ch in message:
		var w := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
		widths.append(w)
		total += w
	var x := bottom_center.x - total * 0.5
	for i in message.length():
		var ch := message[i]
		var y := bottom_center.y + sin(_t * 6.0 - i * 0.55) * 7.0
		var col := Color.from_hsv(fposmod(_t * 0.6 + i * 0.07, 1.0), 0.75, 1.0)
		var pos := Vector2(x, y)
		draw_string_outline(font, pos, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 6, Color(0, 0, 0, 0.9))
		draw_string(font, pos, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
		x += widths[i]
