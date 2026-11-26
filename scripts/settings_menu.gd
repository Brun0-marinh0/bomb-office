extends Control
## Painel de configurações no visual do menu, em abas:
##   ÁUDIO          volume da música e dos efeitos (barramentos "Musica" e "Efeitos")
##   VÍDEO          tela cheia, intensidade do efeito de câmera (CRT/VHS), interferências
##   CONTROLES      teclas do teclado (2 por ação), com restaurar padrão
##   ACESSIBILIDADE cores dos jogadores para daltonismo
## O main.gd lê os campos públicos e salva em user://settings.cfg.

signal changed(music: float, sfx: float)   # volumes
signal prefs_changed                       # vídeo, controles ou acessibilidade

const G = preload("res://scripts/g.gd")
const BUS_MUSIC := "Musica"
const BUS_SFX := "Efeitos"
const ACTIONS := ["up", "down", "left", "right", "bomb", "action"]
const ACTION_NAMES := {"up": "CIMA", "down": "BAIXO", "left": "ESQUERDA", "right": "DIREITA",
	"bomb": "BOMBA", "action": "AÇÃO"}
const DEFAULT_KEYS := {"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN], "left": [KEY_A, KEY_LEFT],
	"right": [KEY_D, KEY_RIGHT], "bomb": [KEY_SPACE, KEY_J], "action": [KEY_E, KEY_K]}
const TABS := ["ÁUDIO", "VÍDEO", "CONTROLES", "ACESSIBILIDADE"]

var music_vol := 0.8
var sfx_vol := 0.8
var crt := 1.0              # 0 = imagem limpa, 1 = efeito de câmera completo
var interference := true    # glitch nas explosões / chuvisco nas trocas de tela
var colorblind := false
var keys := default_keys()  # ação -> [tecla 1, tecla 2] (physical keycode; 0 = vazio)
var test_sfx := Callable()  # toca um efeito para ouvir o volume escolhido

var _music_slider: HSlider
var _sfx_slider: HSlider
var _music_pct: Label
var _sfx_pct: Label
var _crt_slider: HSlider
var _crt_pct: Label
var _fs_btn: Button
var _interf_btn: Button
var _cb_btn: Button
var _swatches: HBoxContainer
var _key_btns := {}         # "ação:slot" -> Button
var _capture := ""          # "ação:slot" esperando uma tecla
var _tab_btns: Array = []
var _pages: Array = []


static func default_keys() -> Dictionary:
	var d := {}
	for a in DEFAULT_KEYS:
		d[a] = (DEFAULT_KEYS[a] as Array).duplicate()
	return d


static func key_name(k: int) -> String:
	if k == 0:
		return "-"
	match k:
		KEY_SPACE: return "ESPAÇO"
		KEY_UP: return "SETA CIMA"
		KEY_DOWN: return "SETA BAIXO"
		KEY_LEFT: return "SETA ESQ."
		KEY_RIGHT: return "SETA DIR."
		KEY_ENTER: return "ENTER"
		KEY_SHIFT: return "SHIFT"
		KEY_CTRL: return "CTRL"
		KEY_ALT: return "ALT"
	return OS.get_keycode_string(k).to_upper()


## Os barramentos ficam em res://default_bus_layout.tres (carregado ao abrir o jogo).
## Na web (Godot 4.3) barramentos criados por código depois do início não recebem som,
## por isso aqui é só uma garantia caso o arquivo falte.
static func setup_buses() -> void:
	for n in [BUS_MUSIC, BUS_SFX]:
		if AudioServer.get_bus_index(n) == -1:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, n)
			AudioServer.set_bus_send(i, "Master")


static func apply_volumes(music: float, sfx: float) -> void:
	# na web a música (e, sem HTTPS, os efeitos) sai pelo WebAudio, com volume próprio
	preload("res://scripts/web_audio.gd").set_volumes(clampf(music, 0.0, 1.0), clampf(sfx, 0.0, 1.0))
	for pair in [[BUS_MUSIC, music], [BUS_SFX, sfx]]:
		var i := AudioServer.get_bus_index(pair[0])
		if i == -1:
			continue
		var v: float = clampf(pair[1], 0.0, 1.0)
		AudioServer.set_bus_mute(i, v <= 0.001)
		AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.001)))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.0, 0.06, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed:
			close())
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := MenuStyle.panel(MenuStyle.AMBER)
	panel.custom_minimum_size.x = 640
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := MenuStyle.label("CONFIGURAÇÕES", 36, MenuStyle.AMBER, 8)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	# abas
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 8)
	vb.add_child(tabs)
	for i in TABS.size():
		var b := MenuStyle.DvrButton.new(TABS[i], 17)
		b.toggle_mode = true
		b.pressed.connect(_show_tab.bind(i))
		tabs.add_child(b)
		_tab_btns.append(b)
	# páginas: mesma altura para o painel não pular ao trocar de aba
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(600, 330)
	vb.add_child(stack)
	for p in [_build_audio(), _build_video(), _build_controls(), _build_access()]:
		var page: Control = p
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.add_child(page)
		_pages.append(page)
	var close_btn := MenuStyle.DvrButton.new("FECHAR", 28, true)
	close_btn.pressed.connect(close)
	vb.add_child(close_btn)
	_show_tab(0)


# ------------------------------------------------------------------ abas
func _page() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	return v


func _build_audio() -> Control:
	var v := _page()
	var r1 := _slider_row("MÚSICA", music_vol)
	_music_slider = r1[0]
	_music_pct = r1[1]
	v.add_child(r1[2])
	var r2 := _slider_row("EFEITOS", sfx_vol)
	_sfx_slider = r2[0]
	_sfx_pct = r2[1]
	v.add_child(r2[2])
	_music_slider.value_changed.connect(func(_v): _on_change())
	_sfx_slider.value_changed.connect(func(_v): _on_change())
	_sfx_slider.drag_ended.connect(func(_c):
		if test_sfx.is_valid():
			test_sfx.call())
	return v


func _build_video() -> Control:
	var v := _page()
	_fs_btn = _toggle_row(v, "TELA CHEIA", func(on: bool): Net.set_fullscreen(on))
	var r := _slider_row("CÂMERA", crt)
	_crt_slider = r[0]
	_crt_pct = r[1]
	v.add_child(r[2])
	_crt_slider.value_changed.connect(func(_v):
		crt = _crt_slider.value / 100.0
		_update_labels()
		prefs_changed.emit())
	v.add_child(_hint("Intensidade do efeito de câmera de vigilância (lente, linhas de TV, granulado). 0% = imagem limpa."))
	_interf_btn = _toggle_row(v, "INTERFERÊNCIAS", func(on: bool):
		interference = on
		prefs_changed.emit())
	v.add_child(_hint("Glitch nas explosões e chuvisco nas trocas de tela e de rodada."))
	return v


func _build_controls() -> Control:
	var v := _page()
	v.add_theme_constant_override("separation", 6)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(grid)
	for a in ACTIONS:
		var l := MenuStyle.label(ACTION_NAMES[a], 20, MenuStyle.MUTED)
		l.custom_minimum_size.x = 150
		grid.add_child(l)
		for slot in 2:
			var b := MenuStyle.DvrButton.new("", 18)
			b.custom_minimum_size.x = 150
			b.focus_mode = Control.FOCUS_NONE
			var id := "%s:%d" % [a, slot]
			b.pressed.connect(_start_capture.bind(id))
			grid.add_child(b)
			_key_btns[id] = b
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	var reset := MenuStyle.DvrButton.new("RESTAURAR PADRÃO", 17)
	reset.pressed.connect(func():
		keys = default_keys()
		_capture = ""
		_update_keys()
		prefs_changed.emit())
	hb.add_child(reset)
	v.add_child(hb)
	v.add_child(_hint("Clique numa tecla e aperte a nova (ESC cancela). Tecla já usada troca de lugar."))
	return v


func _build_access() -> Control:
	var v := _page()
	_cb_btn = _toggle_row(v, "CORES P/ DALTONISMO", func(on: bool):
		colorblind = on
		G.colorblind = on
		_update_swatches()
		prefs_changed.emit())
	v.add_child(_hint("Troca as cores dos jogadores por uma paleta que continua distinguível com daltonismo (deuteranopia, protanopia e tritanopia)."))
	_swatches = HBoxContainer.new()
	_swatches.alignment = BoxContainer.ALIGNMENT_CENTER
	_swatches.add_theme_constant_override("separation", 8)
	v.add_child(_swatches)
	v.add_child(_hint("No placar, jogador eliminado aparece com X e nome riscado; no mapa, cada nome tem a cor do jogador ao lado."))
	return v


func _show_tab(i: int) -> void:
	_capture = ""
	_update_keys()
	for k in _pages.size():
		(_pages[k] as Control).visible = k == i
		(_tab_btns[k] as Button).set_pressed_no_signal(k == i)


# ------------------------------------------------------------------ abrir / fechar
func open() -> void:
	_music_slider.set_value_no_signal(music_vol * 100.0)
	_sfx_slider.set_value_no_signal(sfx_vol * 100.0)
	_crt_slider.set_value_no_signal(crt * 100.0)
	_set_toggle(_fs_btn, Net.is_fullscreen())
	_set_toggle(_interf_btn, interference)
	_set_toggle(_cb_btn, colorblind)
	_update_labels()
	_update_keys()
	_update_swatches()
	visible = true


func close() -> void:
	_capture = ""
	visible = false


func _input(event: InputEvent) -> void:
	# esperando a nova tecla de uma ação
	if not visible or _capture == "" or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	var k: int = event.physical_keycode
	if k == KEY_ESCAPE:
		_capture = ""
		_update_keys()
		return
	var parts := _capture.split(":")
	var a := parts[0]
	var slot := int(parts[1])
	var old: int = keys[a][slot]
	# tecla já usada em outro lugar: troca de lugar com a antiga desta ação
	for b in ACTIONS:
		for s in 2:
			if keys[b][s] == k and not (b == a and s == slot):
				keys[b][s] = old
	keys[a][slot] = k
	_capture = ""
	_update_keys()
	prefs_changed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _start_capture(id: String) -> void:
	_capture = id
	_update_keys()


func _update_keys() -> void:
	for id in _key_btns:
		var parts: PackedStringArray = id.split(":")
		var b: Button = _key_btns[id]
		b.text = "APERTE..." if id == _capture else key_name(int(keys[parts[0]][int(parts[1])]))


func _update_swatches() -> void:
	if _swatches == null:
		return
	for c in _swatches.get_children():
		c.queue_free()
	for i in G.PLAYER_COLORS.size():
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(40, 28)
		sw.color = G.player_color(i)
		sw.tooltip_text = G.player_color_name(i)
		_swatches.add_child(sw)


func _on_change() -> void:
	music_vol = _music_slider.value / 100.0
	sfx_vol = _sfx_slider.value / 100.0
	_update_labels()
	apply_volumes(music_vol, sfx_vol)
	changed.emit(music_vol, sfx_vol)


func _update_labels() -> void:
	_music_pct.text = "%d%%" % roundi(_music_slider.value)
	_sfx_pct.text = "%d%%" % roundi(_sfx_slider.value)
	_crt_pct.text = "%d%%" % roundi(_crt_slider.value)


# ------------------------------------------------------------------ peças
func _hint(text: String) -> Label:
	var l := MenuStyle.label(text, 14, MenuStyle.MUTED, 3)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 580
	return l


## Linha com nome + botão LIGADO/DESLIGADO. cb recebe o novo estado.
func _toggle_row(parent: Control, text: String, cb: Callable) -> Button:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var l := MenuStyle.label(text, 22, MenuStyle.MUTED)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var b := MenuStyle.DvrButton.new("", 20)
	b.toggle_mode = true
	b.custom_minimum_size.x = 170
	b.toggled.connect(func(on: bool):
		_set_toggle(b, on)
		cb.call(on))
	row.add_child(b)
	parent.add_child(row)
	return b


func _set_toggle(b: Button, on: bool) -> void:
	b.set_pressed_no_signal(on)
	b.text = "LIGADO" if on else "DESLIGADO"


func _slider_row(text: String, value: float) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var l := MenuStyle.label(text, 24, MenuStyle.MUTED)
	l.custom_minimum_size.x = 130
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 100
	s.step = 5
	s.value = value * 100.0
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size.y = 40
	s.focus_mode = Control.FOCUS_ALL
	_style_slider(s)
	row.add_child(s)
	var pct := MenuStyle.label("", 22, Color.WHITE)
	pct.custom_minimum_size.x = 72
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)
	return [s, pct, row]


func _style_slider(s: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.15)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	track.skew = Vector2(0.3, 0)
	s.add_theme_stylebox_override("slider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = MenuStyle.AMBER
	fill.content_margin_top = 6
	fill.content_margin_bottom = 6
	fill.skew = Vector2(0.3, 0)
	s.add_theme_stylebox_override("grabber_area", fill)
	var fill_hl := fill.duplicate()
	fill_hl.bg_color = MenuStyle.TEXT
	s.add_theme_stylebox_override("grabber_area_highlight", fill_hl)
	s.add_theme_icon_override("grabber", _knob(MenuStyle.TEXT))
	s.add_theme_icon_override("grabber_highlight", _knob(Color.WHITE))
	s.add_theme_icon_override("grabber_disabled", _knob(Color(0.5, 0.5, 0.5)))


## Bolinha do controle deslizante (desenhada em código).
static func _knob(col: Color) -> ImageTexture:
	var n := 30
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d <= n * 0.5 - 1:
				img.set_pixel(x, y, MenuStyle.INK if d > n * 0.5 - 4 else col)
	return ImageTexture.create_from_image(img)


# =================================================================== botões de ícone do canto
## Base dos botões quadrados do canto da tela (engrenagem, sair): mesmo fundo e borda.
class HudIconButton extends Button:
	const SIZE := 56.0
	var tip := ""

	func _ready() -> void:
		custom_minimum_size = Vector2(SIZE, SIZE)
		focus_mode = Control.FOCUS_NONE
		tooltip_text = tip
		for st in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0, 0, 0, 0.45 if st == "pressed" else 0.3)
			sb.border_color = Color(1, 1, 1, 0.5)
			sb.set_border_width_all(2)
			sb.set_corner_radius_all(12)
			add_theme_stylebox_override(st, sb)


class GearButton extends HudIconButton:
	func _init() -> void:
		tip = "Configurações"

	func _draw() -> void:
		var c := size * 0.5
		var col := Color(1, 1, 1, 0.85)
		var teeth := 8
		var r_out := 17.0
		var r_in := 12.5
		var pts := PackedVector2Array()
		for i in teeth * 4:
			var a := TAU * i / (teeth * 4)
			var r := r_out if (i % 4 == 1 or i % 4 == 2) else r_in
			pts.append(c + Vector2.from_angle(a) * r)
		draw_colored_polygon(pts, col)
		draw_circle(c, 5.5, Color(0.1, 0.05, 0.15, 1.0))


## Ícone de sair (porta com seta para fora): encerra a partida.
class ExitButton extends HudIconButton:
	func _init() -> void:
		tip = "Encerrar partida"

	func _draw() -> void:
		var c := size * 0.5
		var col := Color(1, 1, 1, 0.85)
		# batente da porta, aberto do lado direito por onde a seta sai
		var door := PackedVector2Array([
			c + Vector2(3, -8), c + Vector2(3, -15), c + Vector2(-14, -15),
			c + Vector2(-14, 15), c + Vector2(3, 15), c + Vector2(3, 8)])
		draw_polyline(door, col, 3.5, true)
		# seta saindo
		draw_line(c + Vector2(-6, 0), c + Vector2(10, 0), col, 3.5, true)
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(8, -7), c + Vector2(17, 0), c + Vector2(8, 7)]), col)
