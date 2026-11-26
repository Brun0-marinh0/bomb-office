class_name MenuStyle
extends RefCounted
## Estilo das telas de menu: central de monitoramento / gravador de câmeras (DVR).
## Combina com a partida, que aparece como imagem de câmera de vigilância (scripts/cctv.gd).
## - Fundo: mosaico de 4 câmeras do escritório (CameraWall).
## - Texto: fonte de terminal VT323, branco/cinza, destaque âmbar, vermelho só no REC e avisos.
## - Botões de DVR: moldura fina que inverte as cores ao passar o mouse.
## O filtro (olho-de-peixe, linhas de TV, granulado, glitch) vem do shader da câmera.

const TEXT := Color(0.9, 0.92, 0.88)
const MUTED := Color(0.55, 0.58, 0.56)
const AMBER := Color(1.0, 0.72, 0.2)
const REC := Color(1.0, 0.22, 0.16)
const INK := Color(0.02, 0.025, 0.03)
const PANEL_BG := Color(0.02, 0.03, 0.03, 0.84)
const FONT_PATH := "res://assets/fonts/VT323-Regular.ttf"
const FONT_SCALE := 1.3      # a VT323 é mais baixa que a fonte padrão: compensa nos tamanhos

static var _font: Font


## Fonte de terminal (VT323, licença OFL em assets/fonts/OFL.txt). Sem ela, usa a padrão.
static func font() -> Font:
	if _font == null:
		if ResourceLoader.exists(FONT_PATH):
			# com suavização: em tamanhos que não são múltiplos do pixel da fonte,
			# sem ela algumas colunas somem (o "M" virava "N")
			_font = load(FONT_PATH)
		else:
			_font = ThemeDB.fallback_font
	return _font


## Tamanho em px ajustado para a fonte de terminal.
static func fs(px: int) -> int:
	return int(round(px * FONT_SCALE)) if font() != ThemeDB.fallback_font else px


static func box(bg: Color, border: Color, width := 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	return sb


## Caixa de texto: fundo escuro, moldura cinza (âmbar com foco).
static func style_line_edit(e: LineEdit, font_size := 24) -> void:
	for st in ["normal", "focus", "read_only"]:
		var sb := box(Color(0, 0, 0, 0.6), AMBER if st == "focus" else MUTED)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		e.add_theme_stylebox_override(st, sb)
	e.add_theme_font_override("font", font())
	e.add_theme_font_size_override("font_size", fs(font_size))
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_uneditable_color", MUTED)
	e.add_theme_color_override("font_placeholder_color", Color(MUTED, 0.6))
	e.add_theme_color_override("caret_color", AMBER)
	e.add_theme_color_override("selection_color", Color(AMBER, 0.35))
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER


## Texto de terminal com contorno escuro (legível por cima do mosaico de câmeras).
static func style_label(l: Label, font_size: int, col := TEXT, outline := 4) -> void:
	l.add_theme_font_override("font", font())
	l.add_theme_font_size_override("font_size", fs(font_size))
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", INK)
	l.add_theme_constant_override("outline_size", mini(outline, 5))


static func label(text: String, font_size: int, col := TEXT, outline := 4) -> Label:
	var l := Label.new()
	l.text = text
	style_label(l, font_size, col, outline)
	return l


## Painel de DVR: fundo escuro, moldura fina.
static func panel_style(border: Color) -> StyleBoxFlat:
	var sb := box(PANEL_BG, border)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_content_margin(side, 18)
	return sb


static func panel(border: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(border))
	return p


static func style_scroll(sc: ScrollContainer) -> void:
	var bar := sc.get_v_scroll_bar()
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.06)
	track.content_margin_left = 5
	track.content_margin_right = 5
	bar.add_theme_stylebox_override("scroll", track)
	for st in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var g := StyleBoxFlat.new()
		g.bg_color = MUTED if st == "grabber" else AMBER
		bar.add_theme_stylebox_override(st, g)


## Tema dos diálogos (senha da sala, encerrar sala) no mesmo estilo.
static func dialog_theme() -> Theme:
	var th := Theme.new()
	th.default_font = font()
	th.default_font_size = fs(18)
	var win := box(Color(0.02, 0.03, 0.03, 0.97), AMBER)
	win.expand_margin_top = 30
	win.expand_margin_left = 2
	win.expand_margin_right = 2
	win.expand_margin_bottom = 2
	th.set_stylebox("embedded_border", "Window", win)
	th.set_stylebox("embedded_unfocused_border", "Window", win)
	th.set_color("title_color", "Window", AMBER)
	th.set_font("title_font", "Window", font())
	th.set_font_size("title_font_size", "Window", fs(18))
	var pnl := box(Color(0.02, 0.03, 0.03, 0.97), Color(0, 0, 0, 0), 0)
	pnl.set_content_margin_all(12)
	th.set_stylebox("panel", "AcceptDialog", pnl)
	th.set_color("font_color", "Label", TEXT)
	for st in ["normal", "focus", "read_only"]:
		var sb := box(Color(0, 0, 0, 0.6), AMBER if st == "focus" else MUTED)
		sb.set_content_margin_all(6)
		th.set_stylebox(st, "LineEdit", sb)
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("caret_color", "LineEdit", AMBER)
	var b_normal := box(Color(0, 0, 0, 0.4), MUTED)
	b_normal.content_margin_left = 16
	b_normal.content_margin_right = 16
	b_normal.content_margin_top = 2
	b_normal.content_margin_bottom = 2
	var b_hover := b_normal.duplicate()
	b_hover.bg_color = TEXT
	b_hover.border_color = TEXT
	var b_press := b_normal.duplicate()
	b_press.bg_color = AMBER
	b_press.border_color = AMBER
	var b_focus := box(Color(0, 0, 0, 0), AMBER)
	th.set_stylebox("normal", "Button", b_normal)
	th.set_stylebox("hover", "Button", b_hover)
	th.set_stylebox("pressed", "Button", b_press)
	th.set_stylebox("hover_pressed", "Button", b_press)
	th.set_stylebox("focus", "Button", b_focus)
	th.set_color("font_color", "Button", TEXT)
	for k in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		th.set_color(k, "Button", INK)
	th.set_color("font_focus_color", "Button", TEXT)
	return th


# =================================================================== título
## Texto grande parado; de vez em quando "falha o sinal" por um instante.
class Title extends Control:
	var text := "BOMB OFFICE"
	var font_size := 96
	var t := 0.0
	var _next_glitch := 2.0
	var _glitch_until := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0, MenuStyle.fs(font_size) * 1.0)

	func _process(dt: float) -> void:
		t += dt
		if t >= _next_glitch:
			_glitch_until = t + randf_range(0.1, 0.22)
			_next_glitch = t + randf_range(3.0, 7.0)
		queue_redraw()

	func _draw() -> void:
		var f: Font = MenuStyle.font()
		var px := MenuStyle.fs(font_size)
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		var p := Vector2((size.x - w) * 0.5, size.y * 0.5 + px * 0.3)
		if t < _glitch_until:
			var j := Vector2(randf_range(-10, 10), randf_range(-2, 2))
			draw_string(f, p + j + Vector2(-5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(1, 0.1, 0.1, 0.7))
			draw_string(f, p + j + Vector2(5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0.1, 0.9, 1, 0.7))
			draw_string(f, p + j, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, MenuStyle.TEXT)
			for i in 3:   # faixas de interferência cortando o texto
				var y := p.y - px * randf_range(0.1, 0.8)
				draw_rect(Rect2(p.x - 20, y, w + 40, randf_range(2, 6)), Color(MenuStyle.INK, 0.85))
			return
		draw_string_outline(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, 8, MenuStyle.INK)
		draw_string(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, MenuStyle.TEXT)


# =================================================================== botão de DVR
## Moldura fina; ao passar o mouse inverte (fundo claro, texto escuro). O principal é âmbar.
class DvrButton extends Button:
	func _init(label: String, size_px: int, is_primary := false, accent := Color(0, 0, 0, 0)) -> void:
		text = label
		focus_mode = Control.FOCUS_ALL
		var edge: Color = accent if accent.a > 0.0 else (MenuStyle.AMBER if is_primary else MenuStyle.MUTED)
		var fill: Color = accent if accent.a > 0.0 else (MenuStyle.AMBER if is_primary else MenuStyle.TEXT)
		var normal := MenuStyle.box(Color(0, 0, 0, 0.45), edge)
		normal.content_margin_left = 16
		normal.content_margin_right = 16
		normal.content_margin_top = 2
		normal.content_margin_bottom = 2
		var hover := normal.duplicate()
		hover.bg_color = fill
		hover.border_color = fill
		var press := normal.duplicate()
		press.bg_color = MenuStyle.AMBER
		press.border_color = MenuStyle.AMBER
		var disabled := normal.duplicate()
		disabled.border_color = Color(MenuStyle.MUTED, 0.3)
		add_theme_stylebox_override("normal", normal)
		add_theme_stylebox_override("hover", hover)
		add_theme_stylebox_override("pressed", press)
		add_theme_stylebox_override("hover_pressed", press)
		add_theme_stylebox_override("disabled", disabled)
		add_theme_stylebox_override("focus", MenuStyle.box(Color(0, 0, 0, 0), MenuStyle.AMBER))
		add_theme_font_override("font", MenuStyle.font())
		add_theme_font_size_override("font_size", MenuStyle.fs(size_px))
		add_theme_color_override("font_color", edge if (is_primary or accent.a > 0.0) else MenuStyle.TEXT)
		add_theme_color_override("font_focus_color", edge if (is_primary or accent.a > 0.0) else MenuStyle.TEXT)
		for k in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			add_theme_color_override(k, MenuStyle.INK)
		add_theme_color_override("font_disabled_color", Color(MenuStyle.MUTED, 0.4))


# =================================================================== mosaico de câmeras (fundo)
## Central de monitoramento: 4 câmeras do escritório desenhadas com os sprites do jogo.
## De vez em quando uma perde o sinal, e às vezes alguém passa andando.
class CameraWall extends Control:
	const G = preload("res://scripts/g.gd")
	const NAMES := ["RECEPÇÃO", "CORREDOR", "SALA 101", "COPA"]
	const ROWS := 6
	const GAP := 6.0
	const DIM := Color(0.0, 0.01, 0.01, 0.68)   # escurece as câmeras para o menu ficar legível
	var t := 0.0
	var _maps: Array = []                  # por câmera: Array de linhas (0 chão, 1 mesa)
	var _static: Control                   # chão e paredes: só redesenha quando muda o tamanho
	var _lost := -1                        # câmera sem sinal
	var _lost_until := 0.0
	var _next_lost := 6.0
	var _walker := {}                      # alguém andando: {cam, x, dir, color}
	var _next_walker := 1.5

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_static = Control.new()
		_static.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_static.show_behind_parent = true
		_static.draw.connect(_draw_static)
		add_child(_static)
		resized.connect(_static.queue_redraw)
		var rng := RandomNumberGenerator.new()
		for cam in 4:
			rng.seed = 1000 + cam * 77
			var rows: Array = []
			for y in ROWS:
				var row := PackedByteArray()
				row.resize(24)
				for x in 24:
					# linha 0 = parede; linha 3 fica livre (corredor por onde alguém passa)
					row[x] = 1 if (y >= 1 and y != 3 and rng.randf() < 0.42) else 0
				rows.append(row)
			_maps.append(rows)

	func _feed_rect(cam: int) -> Rect2:
		var fw := (size.x - GAP * 3.0) * 0.5
		var fh := (size.y - GAP * 3.0) * 0.5
		return Rect2(GAP + (cam % 2) * (fw + GAP), GAP + (cam / 2) * (fh + GAP), fw, fh)

	func _tile() -> float:
		return _feed_rect(0).size.y / ROWS

	func _process(dt: float) -> void:
		t += dt
		if _lost >= 0 and t > _lost_until:
			_lost = -1
		if _lost < 0 and t > _next_lost:
			_lost = randi() % 4
			_lost_until = t + randf_range(2.0, 3.0)
			_next_lost = t + randf_range(9.0, 15.0)
		if _walker.is_empty() and t > _next_walker:
			var cam := randi() % 4
			var dir := 1 if randi() % 2 == 0 else -1
			_walker = {"cam": cam, "dir": dir, "x": -1.0 if dir > 0 else _feed_rect(cam).size.x / _tile() + 1.0,
				"color": randi() % 8}
		if not _walker.is_empty():
			_walker.x += _walker.dir * dt * 1.6
			var cols := _feed_rect(0).size.x / _tile()
			if _walker.x < -1.5 or _walker.x > cols + 1.5:
				_walker = {}
				_next_walker = t + randf_range(4.0, 8.0)
		queue_redraw()

	func _draw_static() -> void:
		var tile := _tile()
		var floor_a := Sprites.tex("floor")
		var floor_b := Sprites.tex("floor_alt")
		for cam in 4:
			var r := _feed_rect(cam)
			_static.draw_rect(r, Color(0.04, 0.05, 0.05))
			var cols := int(ceil(r.size.x / tile))
			for y in ROWS:
				for x in cols:
					var dst := Rect2(r.position + Vector2(x * tile, y * tile), Vector2(tile, tile)).intersection(r)
					if dst.size.x <= 0.0:
						continue
					var src := Rect2(0, 0, 32.0 * dst.size.x / tile, 32)
					var tex: Texture2D
					if y == 0:
						var decor := ["wall_plain", "wall_clock", "wall_plain", "wall_notice_board", "wall_plain", "wall_air_conditioner"]
						tex = Sprites.tex("officeWall/" + decor[(x + cam * 2) % decor.size()])
					else:
						tex = floor_a if (x + y) % 2 == 0 else floor_b
					_static.draw_texture_rect_region(tex, dst, src)

	func _draw() -> void:
		var tile := _tile()
		var desks: Array = Sprites.seq("deskOffice/deskOffice_")
		var f: Font = MenuStyle.font()
		for cam in 4:
			var r := _feed_rect(cam)
			var rows: Array = _maps[cam]
			var cols := int(ceil(r.size.x / tile))
			if not desks.is_empty():
				for y in ROWS:
					for x in mini(cols, 24):
						if rows[y][x] == 1:
							var dst := Rect2(r.position + Vector2(x * tile, y * tile), Vector2(tile, tile)).intersection(r)
							if dst.size.x > 0.0:
								var fr := int(t * 10.0 + x * 7 + y * 13 + cam * 5) % desks.size()
								draw_texture_rect_region(desks[fr], dst, Rect2(0, 0, 32.0 * dst.size.x / tile, 32))
			if not _walker.is_empty() and _walker.cam == cam:
				var frames: Array = Sprites.frames("walk_right" if _walker.dir > 0 else "walk_left")
				if not frames.is_empty():
					var tex: Texture2D = frames[int(t * 12.0) % frames.size()]
					var dst := Rect2(r.position + Vector2(_walker.x * tile, 3 * tile), Vector2(tile, tile))
					if r.encloses(dst):
						draw_texture_rect(tex, dst, false, G.player_color(_walker.color))
			draw_rect(r, DIM)
			if cam == _lost:
				draw_rect(r, Color(0.03, 0.06, 0.2))
				var msg := "SEM SINAL"
				var px := MenuStyle.fs(30)
				var w := f.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
				draw_string(f, r.get_center() + Vector2(-w * 0.5, px * 0.3), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, px, MenuStyle.TEXT)
			draw_rect(r, Color(MenuStyle.MUTED, 0.5), false, 2.0)
			var lbl := "CAM %02d • %s" % [cam + 1, NAMES[cam]]
			# a CAM 01 começa depois do "● REC" do canto da tela
			var lp := r.position + Vector2(90.0 if cam == 0 else 10.0, MenuStyle.fs(16) + 4)
			draw_string_outline(f, lp, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, MenuStyle.fs(16), 4, MenuStyle.INK)
			draw_string(f, lp, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, MenuStyle.fs(16), Color(MenuStyle.TEXT, 0.8))
