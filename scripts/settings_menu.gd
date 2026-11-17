extends Control
## Painel de configurações (volume da música e dos efeitos), no visual neon do menu.
## Os volumes são aplicados nos barramentos de áudio "Musica" e "Efeitos".

signal changed(music: float, sfx: float)

const BUS_MUSIC := "Musica"
const BUS_SFX := "Efeitos"

var music_vol := 0.8
var sfx_vol := 0.8
var test_sfx := Callable()   # toca um efeito para ouvir o volume escolhido

var _music_slider: HSlider
var _sfx_slider: HSlider
var _music_pct: Label
var _sfx_pct: Label


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
	# na web sem HTTPS o som sai pelo WebAudio, com volume próprio
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
	var panel := MenuStyle.panel(MenuStyle.PINK)
	panel.custom_minimum_size.x = 560
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	panel.add_child(vb)
	var title := MenuStyle.label("CONFIGURAÇÕES", 40, MenuStyle.PINK, 8)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var r1 := _slider_row("MÚSICA", music_vol)
	_music_slider = r1[0]
	_music_pct = r1[1]
	vb.add_child(r1[2])
	var r2 := _slider_row("EFEITOS", sfx_vol)
	_sfx_slider = r2[0]
	_sfx_pct = r2[1]
	vb.add_child(r2[2])
	_music_slider.value_changed.connect(func(_v): _on_change())
	_sfx_slider.value_changed.connect(func(_v): _on_change())
	_sfx_slider.drag_ended.connect(func(_c):
		if test_sfx.is_valid():
			test_sfx.call())
	var close_btn := MenuStyle.NeonButton.new("FECHAR", 30, true)
	close_btn.pressed.connect(close)
	vb.add_child(close_btn)


func open() -> void:
	_music_slider.set_value_no_signal(music_vol * 100.0)
	_sfx_slider.set_value_no_signal(sfx_vol * 100.0)
	_update_labels()
	visible = true


func close() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _on_change() -> void:
	music_vol = _music_slider.value / 100.0
	sfx_vol = _sfx_slider.value / 100.0
	_update_labels()
	apply_volumes(music_vol, sfx_vol)
	changed.emit(music_vol, sfx_vol)


func _update_labels() -> void:
	_music_pct.text = "%d%%" % roundi(_music_slider.value)
	_sfx_pct.text = "%d%%" % roundi(_sfx_slider.value)


func _slider_row(text: String, value: float) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var l := MenuStyle.label(text, 24, MenuStyle.YELLOW)
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
	fill.bg_color = MenuStyle.PINK
	fill.content_margin_top = 6
	fill.content_margin_bottom = 6
	fill.skew = Vector2(0.3, 0)
	s.add_theme_stylebox_override("grabber_area", fill)
	var fill_hl := fill.duplicate()
	fill_hl.bg_color = MenuStyle.CYAN
	s.add_theme_stylebox_override("grabber_area_highlight", fill_hl)
	s.add_theme_icon_override("grabber", _knob(MenuStyle.YELLOW))
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


# =================================================================== botão de engrenagem
class GearButton extends Button:
	const SIZE := 56.0

	func _ready() -> void:
		custom_minimum_size = Vector2(SIZE, SIZE)
		focus_mode = Control.FOCUS_NONE
		tooltip_text = "Configurações"
		for st in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0, 0, 0, 0.45 if st == "pressed" else 0.3)
			sb.border_color = Color(1, 1, 1, 0.5)
			sb.set_border_width_all(2)
			sb.set_corner_radius_all(12)
			add_theme_stylebox_override(st, sb)

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
