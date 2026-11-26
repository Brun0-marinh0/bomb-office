extends Control
## Tela de resultado da partida (por cima do jogo): campeão, tabela com vitórias, abates,
## mortes, suicídios e itens pegos, e a votação de revanche.
## Quem decide o que fazer é o main.gd (sinais abaixo).

signal rematch_pressed
signal lobby_pressed
signal leave_pressed
signal message_sent(text: String)

const G = preload("res://scripts/g.gd")
const MenuStyle = preload("res://scripts/menu_style.gd")
const COLS := ["VITÓRIAS", "ABATES", "MORTES", "SUICÍDIOS", "ITENS"]

var _title: Label
var _champ_msg: Label
var _table: GridContainer
var _rematch: Button
var _votes: Label
var _lobby: Button
var _timer_label: Label
var _msg_row: HBoxContainer
var _msg_edit: LineEdit
var _deadline_ms := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := MenuStyle.panel(MenuStyle.AMBER)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size.x = 720
	panel.add_child(vb)
	vb.add_child(_centered(MenuStyle.label("RESULTADO DA PARTIDA", 18, MenuStyle.MUTED, 3)))
	_title = _centered(MenuStyle.label("", 36, MenuStyle.AMBER, 6))
	vb.add_child(_title)
	_champ_msg = _centered(MenuStyle.label("", 22, Color.WHITE, 5))
	_champ_msg.visible = false
	vb.add_child(_champ_msg)
	_table = GridContainer.new()
	_table.columns = 2 + COLS.size()
	_table.add_theme_constant_override("h_separation", 22)
	_table.add_theme_constant_override("v_separation", 6)
	_table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(_table)
	# campeão humano pode deixar um recado para todos
	_msg_row = HBoxContainer.new()
	_msg_row.add_theme_constant_override("separation", 10)
	_msg_edit = LineEdit.new()
	_msg_edit.max_length = 20
	_msg_edit.placeholder_text = "recado do campeão (Enter)"
	_msg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MenuStyle.style_line_edit(_msg_edit, 18)
	_msg_edit.text_submitted.connect(func(_t): _send_msg())
	_msg_row.add_child(_msg_edit)
	var send := MenuStyle.DvrButton.new("ENVIAR", 18)
	send.pressed.connect(_send_msg)
	_msg_row.add_child(send)
	vb.add_child(_msg_row)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 20)
	_rematch = MenuStyle.DvrButton.new("REVANCHE", 26, true)
	_rematch.toggle_mode = true
	_rematch.pressed.connect(func(): rematch_pressed.emit())
	hb.add_child(_rematch)
	_lobby = MenuStyle.DvrButton.new("VOLTAR AO LOBBY", 20)
	_lobby.pressed.connect(func(): lobby_pressed.emit())
	hb.add_child(_lobby)
	var leave := MenuStyle.DvrButton.new("SAIR DA SALA", 20, false, MenuStyle.REC)
	leave.pressed.connect(func(): leave_pressed.emit())
	hb.add_child(leave)
	vb.add_child(hb)
	_votes = _centered(MenuStyle.label("", 17, MenuStyle.TEXT, 3))
	vb.add_child(_votes)
	_timer_label = _centered(MenuStyle.label("", 15, MenuStyle.MUTED, 3))
	vb.add_child(_timer_label)


## rows: [[id, vitórias, abates, mortes, suicídios, itens], ...]; names/colors: id -> valor.
func show_results(title: String, rows: Array, names: Dictionary, colors: Dictionary, my_id: int,
		is_leader: bool, can_write: bool, secs: float) -> void:
	_title.text = title
	_champ_msg.visible = false
	for c in _table.get_children():
		c.queue_free()
	_table.add_child(Control.new())
	_table.add_child(MenuStyle.label("JOGADOR", 16, MenuStyle.MUTED, 3))
	for h in COLS:
		_table.add_child(_num(h, MenuStyle.MUTED, 16))
	for r in rows:
		var id: int = r[0]
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(18, 18)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sw.color = G.player_color(int(colors.get(id, 0)))
		_table.add_child(sw)
		var nm := String(names.get(id, "?")).to_upper()
		var col: Color = MenuStyle.AMBER if id == my_id else MenuStyle.TEXT
		_table.add_child(MenuStyle.label(nm + ("  (VOCÊ)" if id == my_id else ""), 20, col, 4))
		for i in COLS.size():
			_table.add_child(_num(str(r[i + 1]), col, 20))
	_lobby.visible = is_leader
	_msg_row.visible = can_write
	_msg_edit.text = ""
	_rematch.set_pressed_no_signal(false)
	_rematch.text = "REVANCHE"
	_votes.text = ""
	_deadline_ms = Time.get_ticks_msec() + int(secs * 1000.0)
	visible = true
	if can_write:
		_msg_edit.grab_focus()


func set_votes(voters: Array, needed: int, my_id: int, names: Dictionary) -> void:
	var mine := my_id in voters
	_rematch.set_pressed_no_signal(mine)
	_rematch.text = "REVANCHE  %d/%d" % [voters.size(), needed] + ("  (SEU VOTO)" if mine else "")
	if voters.is_empty():
		_votes.text = "Revanche começa quando todos votarem."
	else:
		var who := PackedStringArray()
		for id in voters:
			who.append(String(names.get(id, "?")))
		_votes.text = "Querem revanche: " + ", ".join(who)


func set_message(text: String) -> void:
	_champ_msg.text = "\"%s\"" % text
	_champ_msg.visible = text != ""


func _process(_dt: float) -> void:
	if not visible:
		return
	var left := maxi(0, ceili((_deadline_ms - Time.get_ticks_msec()) / 1000.0))
	_timer_label.text = "Voltando ao lobby em %ds" % left


func _send_msg() -> void:
	var t := _msg_edit.text.strip_edges()
	if t == "":
		return
	message_sent.emit(t)
	_msg_edit.text = ""


func _centered(l: Label) -> Label:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _num(text: String, col: Color, size: int) -> Label:
	var l := MenuStyle.label(text, size, col, 3)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
