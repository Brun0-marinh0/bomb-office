class_name MenuStyle
extends RefCounted
## Estilo do menu: neon anos 80 / synthwave.
## Fundo em degradê que troca de cor, raios girando, linhas de TV (CRT),
## título grosso e inclinado que balança e botões de texto que pulsam.

const PINK := Color(1.0, 0.16, 0.58)
const CYAN := Color(0.1, 0.95, 1.0)
const YELLOW := Color(1.0, 0.9, 0.25)
const INK := Color(0.12, 0.0, 0.18)
## Paleta do fundo (troca suavemente de uma cor para outra)
const SKY := [Color(0.95, 0.1, 0.5), Color(0.42, 0.04, 0.62), Color(0.04, 0.42, 0.78),
	Color(1.0, 0.42, 0.08)]

static var _heavy: FontVariation


## Fonte grossa e inclinada (a fonte padrão com negrito e itálico sintéticos).
static func heavy_font() -> FontVariation:
	if _heavy == null:
		_heavy = FontVariation.new()
		_heavy.base_font = ThemeDB.fallback_font
		_heavy.variation_embolden = 1.1
		_heavy.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.28, 1), Vector2.ZERO)
	return _heavy


static func sky_color(t: float) -> Color:
	var n := SKY.size()
	var f := fposmod(t, float(n))
	var i := int(f)
	return (SKY[i] as Color).lerp(SKY[(i + 1) % n], smoothstep(0.0, 1.0, f - i))


## Caixa de texto: fundo escuro translúcido, borda rosa, inclinada.
static func style_line_edit(e: LineEdit, font_size := 24) -> void:
	for st in ["normal", "focus", "read_only"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.0, 0.08, 0.7)
		sb.border_color = CYAN if st == "focus" else PINK
		sb.set_border_width_all(3)
		sb.skew = Vector2(0.18, 0)
		sb.content_margin_left = 18
		sb.content_margin_right = 18
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		e.add_theme_stylebox_override(st, sb)
	e.add_theme_font_override("font", heavy_font())
	e.add_theme_font_size_override("font_size", font_size)
	e.add_theme_color_override("font_color", Color.WHITE)
	e.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.45))
	e.add_theme_color_override("caret_color", CYAN)
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER


## Texto com sombra dura (usado em rótulos do menu).
static func style_label(l: Label, font_size: int, col := Color.WHITE, outline := 6) -> void:
	l.add_theme_font_override("font", heavy_font())
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(INK, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 3)
	l.add_theme_constant_override("shadow_offset_y", 3)
	l.add_theme_color_override("font_outline_color", INK)
	l.add_theme_constant_override("outline_size", outline)


static func label(text: String, font_size: int, col := Color.WHITE, outline := 6) -> Label:
	var l := Label.new()
	l.text = text
	style_label(l, font_size, col, outline)
	return l


## Painel escuro translúcido, levemente inclinado, com borda neon.
static func panel_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.0, 0.08, 0.62)
	sb.border_color = border
	sb.set_border_width_all(3)
	sb.skew = Vector2(0.04, 0)
	sb.shadow_color = Color(border, 0.35)
	sb.shadow_size = 10
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_content_margin(side, 18)
	return sb


static func panel(border: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(border))
	return p


## Barra de rolagem fina rosa.
static func style_scroll(sc: ScrollContainer) -> void:
	var bar := sc.get_v_scroll_bar()
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.08)
	track.content_margin_left = 6
	track.content_margin_right = 6
	bar.add_theme_stylebox_override("scroll", track)
	for st in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var g := StyleBoxFlat.new()
		g.bg_color = PINK if st == "grabber" else YELLOW
		bar.add_theme_stylebox_override(st, g)


# =================================================================== fundo
class Background extends Control:
	const RAYS := 18
	var t := 0.0

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(dt: float) -> void:
		t += dt
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var top: Color = MenuStyle.sky_color(t * 0.12)
		var bottom: Color = MenuStyle.sky_color(t * 0.12 + 1.6).darkened(0.35)
		draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
			PackedColorArray([top, top, bottom, bottom]))
		# raios girando a partir de um ponto atrás do título
		var c := Vector2(w * 0.5, h * 0.3)
		var r := Vector2(w, h).length()
		for i in RAYS:
			if i % 2 == 1:
				continue
			var a0 := t * 0.08 + TAU * i / RAYS
			var a1 := a0 + TAU / RAYS
			draw_colored_polygon(PackedVector2Array([c, c + Vector2.from_angle(a0) * r,
				c + Vector2.from_angle(a1) * r]), Color(1, 1, 1, 0.07))
		# vinheta: bordas mais escuras
		var dark := Color(0.05, 0.0, 0.1, 0.55)
		var clear := Color(0.05, 0.0, 0.1, 0.0)
		draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h * 0.18), Vector2(0, h * 0.18)]),
			PackedColorArray([dark, dark, clear, clear]))
		draw_polygon(PackedVector2Array([Vector2(0, h * 0.75), Vector2(w, h * 0.75), Vector2(w, h), Vector2(0, h)]),
			PackedColorArray([clear, clear, dark, dark]))


# =================================================================== linhas de TV (por cima de tudo)
class Scanlines extends Control:
	var t := 0.0

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(dt: float) -> void:
		t += dt
		queue_redraw()

	func _draw() -> void:
		var y := 0.0
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(0, 0, 0, 0.13), 1.0)
			y += 4.0
		# faixa clara que desce devagar, como uma fita VHS
		var by := fposmod(t * 90.0, size.y + 160.0) - 80.0
		draw_rect(Rect2(0, by, size.x, 40), Color(1, 1, 1, 0.035))


# =================================================================== título
class Title extends Control:
	var text := "BOMB OFFICE"
	var font_size := 96
	var t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0, font_size * 1.45)

	func _process(dt: float) -> void:
		t += dt
		queue_redraw()

	func _draw() -> void:
		var font: Font = MenuStyle.heavy_font()
		var total := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var ang := sin(t * 1.3) * 0.06
		var sc := 1.0 + sin(t * 2.6) * 0.03
		draw_set_transform(size * 0.5, ang, Vector2(sc, sc))
		var x := -total * 0.5
		var base_y := font_size * 0.35
		var fill: Color = Color.WHITE.lerp(MenuStyle.PINK, 0.5 + 0.5 * sin(t * 1.7))
		for i in text.length():
			var ch := text[i]
			var adv := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var p := Vector2(x, base_y + sin(t * 4.0 + i * 0.55) * 7.0)
			# camadas: sombra escura, ciano e magenta deslocados, letra branca com contorno
			draw_string(font, p + Vector2(9, 9), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(MenuStyle.INK, 0.85))
			draw_string(font, p + Vector2(-5, 2), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, MenuStyle.CYAN)
			draw_string(font, p + Vector2(5, 4), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, MenuStyle.PINK)
			draw_string_outline(font, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 10, MenuStyle.INK)
			draw_string(font, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fill)
			x += adv
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# =================================================================== botão de texto neon
class NeonButton extends Button:
	var primary := false   # o principal pulsa sempre (no celular não existe "passar o mouse")
	var base_color := Color.WHITE
	var t := 0.0

	func _init(label: String, size_px: int, is_primary := false, base := Color.WHITE) -> void:
		text = label
		primary = is_primary
		base_color = base
		flat = true
		focus_mode = Control.FOCUS_ALL
		add_theme_font_override("font", MenuStyle.heavy_font())
		add_theme_font_size_override("font_size", size_px)
		add_theme_color_override("font_outline_color", MenuStyle.INK)
		add_theme_constant_override("outline_size", 10)
		var empty := StyleBoxEmpty.new()
		for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
			add_theme_stylebox_override(st, empty)
		resized.connect(func(): pivot_offset = size * 0.5)

	func _process(dt: float) -> void:
		t += dt
		var hot := primary or is_hovered() or has_focus()
		var col := base_color
		if hot:
			col = MenuStyle.PINK.lerp(MenuStyle.YELLOW, 0.5 + 0.5 * sin(t * 6.0))
			rotation = sin(t * 3.0) * 0.05
			var s := 1.0 + 0.06 * (0.5 + 0.5 * sin(t * 6.0))
			scale = Vector2(s, s)
		else:
			rotation = 0.0
			scale = Vector2.ONE
		if is_pressed():
			col = MenuStyle.CYAN
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			add_theme_color_override(k, col)
