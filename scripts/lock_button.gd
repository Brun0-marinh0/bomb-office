extends Button
## Cadeado da legenda de itens no lobby: fechado = item bloqueado (não aparece na partida).
## Só o líder clica; para os outros ele só mostra o estado.

const MenuStyle = preload("res://scripts/menu_style.gd")
const SIZE := 34.0

var locked := false:
	set(v):
		locked = v
		tooltip_text = "Liberar item" if v else "Bloquear item"
		queue_redraw()


func _ready() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var sb := MenuStyle.box(Color(0, 0, 0, 0.0 if st in ["normal", "disabled", "focus"] else 0.4),
			Color(MenuStyle.AMBER, 0.6) if st.begins_with("hover") else Color(0, 0, 0, 0), 1)
		add_theme_stylebox_override(st, sb)
	locked = locked


func _draw() -> void:
	var c := size * 0.5 + Vector2(0, 3)
	var col: Color = MenuStyle.REC if locked else MenuStyle.TEXT
	if disabled:
		col.a = 0.7
	# corpo do cadeado
	draw_rect(Rect2(c + Vector2(-9, -4), Vector2(18, 13)), col)
	draw_circle(c + Vector2(0, 1.5), 2.2, MenuStyle.INK)
	draw_line(c + Vector2(0, 2), c + Vector2(0, 5.5), MenuStyle.INK, 2.0)
	# alça: fechada encaixa dos dois lados; aberta fica levantada e solta à direita
	var lift := 0.0 if locked else -5.0
	var arc_c := c + Vector2(0, -6 + lift)
	draw_arc(arc_c, 6.0, PI, TAU, 12, col, 2.5, true)
	draw_line(arc_c + Vector2(-6, 0), c + Vector2(-6, -4), col, 2.5)
	if locked:
		draw_line(arc_c + Vector2(6, 0), c + Vector2(6, -4), col, 2.5)
	else:
		draw_line(arc_c + Vector2(6, 0), arc_c + Vector2(6, 2), col, 2.5)
