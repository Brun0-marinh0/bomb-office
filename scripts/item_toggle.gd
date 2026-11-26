extends Button
## Chave "ATIVO / DESATIVADO" de cada item na legenda do lobby.
## Desativado = o item não aparece nas partidas desta sala. Só o líder clica;
## para os outros ela só mostra o estado.

const MenuStyle = preload("res://scripts/menu_style.gd")
const W := 124.0
const H := 30.0
const ON := Color(0.35, 0.95, 0.45)

var active := true:
	set(v):
		active = v
		tooltip_text = ("Clique para desativar este item" if v else "Clique para ativar este item") \
			if not disabled else ""
		queue_redraw()


func _ready() -> void:
	custom_minimum_size = Vector2(W, H)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var clear := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(st, clear)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	active = active


func _draw() -> void:
	var col: Color = ON if active else MenuStyle.REC
	var hover := is_hovered() and not disabled
	# fundo e moldura (fica mais claro no hover)
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0, 0, 0, 0.55 if not hover else 0.8))
	draw_rect(r, Color(col, 0.9 if hover else 0.55), false, 1.0)
	# chave: trilho + bolinha (direita = ativo)
	var track := Rect2(Vector2(8, size.y * 0.5 - 6), Vector2(26, 12))
	draw_rect(track, Color(col, 0.35))
	var knob_x: float = track.position.x + (track.size.x - 10 if active else 0)
	draw_rect(Rect2(Vector2(knob_x, track.position.y - 1), Vector2(10, 14)), col)
	# texto
	var f: Font = MenuStyle.font()
	var px := MenuStyle.fs(13)
	var txt := "ATIVO" if active else "DESATIVADO"
	draw_string(f, Vector2(42, size.y * 0.5 + px * 0.32), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px,
		Color(col, 0.65 if disabled else 1.0))
