extends PanelContainer
## Painel "SEUS ITENS:" à direita da arena, no estilo de terminal âmbar (VT323).
## - item novo: a linha é "digitada" letra por letra;
## - item que sai: a linha é "apagada" de trás pra frente (backspace);
## - item com tempo (colete, caveira): pisca quando faltam 5 s ou menos.
##
## Uso: set_entries([{key, text, timer, quiet}]) a cada snapshot. timer < 0 = sem tempo;
## quiet = número que muda o tempo todo (bombas 2/3): atualiza sem redigitar.
## lose(key): item consumido (coração): a linha pisca em vermelho e é apagada.

const MenuStyle = preload("res://scripts/menu_style.gd")

const TYPE_CPS := 38.0      # letras por segundo ao digitar
const DELETE_CPS := 70.0    # letras por segundo ao apagar
const WARN_AT := 5.0        # segundos restantes a partir dos quais a linha pisca
const BLINK := 0.5          # período da piscada
const FONT_SIZE := 15
const LOST_TIME := 0.9      # quanto tempo a linha consumida pisca em vermelho antes de apagar

var _title: Label
var _list: VBoxContainer
var _rows := {}             # key -> {label, text, timer, shown, deleting}
var _dying: Array = []      # linhas sendo apagadas
var _clock := 0.0
var _suppress := {}         # key -> até quando ignorar (item consumido que o snapshot ainda mostra)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := MenuStyle.box(Color(0.0, 0.0, 0.0, 0.55), Color(0, 0, 0, 0), 0)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_content_margin(side, 10)
	add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)
	_title = MenuStyle.label("SEUS ITENS:", FONT_SIZE + 1, MenuStyle.AMBER, 3)
	vb.add_child(_title)
	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 2)
	vb.add_child(_list)


## entries: Array de {key: String, text: String, timer: float}
func set_entries(entries: Array) -> void:
	var seen := {}
	for e in entries:
		var key: String = e.key
		var text: String = "> " + String(e.text).to_upper()
		var timer: float = e.get("timer", -1.0)
		var quiet: bool = e.get("quiet", false)
		seen[key] = true
		if _suppress.has(key):
			if _clock < float(_suppress[key]):
				continue
			_suppress.erase(key)
		if not _rows.has(key):
			_add_row(key, text, timer)
			continue
		var r: Dictionary = _rows[key]
		if r.text != text:
			var label: Label = r.label
			label.text = text
			# item sem tempo que mudou (ex.: pegou mais uma bomba): digita de novo.
			# Item com tempo só atualiza a contagem, sem redigitar a cada segundo.
			if timer < 0.0 and not quiet:
				r.shown = 0.0
			else:
				r.shown = minf(r.shown, text.length())
			r.text = text
		r.timer = timer
	for key in _rows.keys():
		if not seen.has(key):
			var r: Dictionary = _rows[key]
			_rows.erase(key)
			r.deleting = true
			r.shown = minf(r.shown, r.text.length())
			(r.label as Label).modulate.a = 1.0
			_dying.append(r)


func lose(key: String) -> void:
	_suppress[key] = _clock + 1.5
	if not _rows.has(key):
		return
	var r: Dictionary = _rows[key]
	_rows.erase(key)
	r.deleting = true
	r.lost = LOST_TIME
	var l: Label = r.label
	l.add_theme_color_override("font_color", MenuStyle.REC)
	l.visible_characters = -1
	r.shown = float(r.text.length())
	_dying.append(r)


func clear_now() -> void:
	for r in _rows.values():
		(r.label as Label).queue_free()
	for r in _dying:
		(r.label as Label).queue_free()
	_rows.clear()
	_dying.clear()


func _add_row(key: String, text: String, timer: float) -> void:
	var l := MenuStyle.label(text, FONT_SIZE, MenuStyle.AMBER, 3)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.visible_characters = 0
	_list.add_child(l)
	_rows[key] = {label = l, text = text, timer = timer, shown = 0.0, deleting = false, lost = 0.0}


func _process(dt: float) -> void:
	_clock += dt
	# cursor piscando no título, como num terminal
	_title.text = "SEUS ITENS:" + ("_" if fmod(_clock, 1.0) < 0.5 else " ")
	for r in _rows.values():
		var l: Label = r.label
		var n: int = r.text.length()
		if r.shown < n:
			r.shown = minf(r.shown + TYPE_CPS * dt, n)
		l.visible_characters = int(r.shown)
		if r.timer >= 0.0 and r.timer <= WARN_AT and r.shown >= n:
			l.modulate.a = 1.0 if fmod(_clock, BLINK) < BLINK * 0.5 else 0.15
		else:
			l.modulate.a = 1.0
	for i in range(_dying.size() - 1, -1, -1):
		var r: Dictionary = _dying[i]
		var l: Label = r.label
		if r.lost > 0.0:
			# consumido: pisca rápido em vermelho antes de começar a apagar
			r.lost -= dt
			l.modulate.a = 1.0 if fmod(_clock, 0.2) < 0.1 else 0.25
			continue
		l.modulate.a = 1.0
		r.shown -= DELETE_CPS * dt
		if r.shown <= 0.0:
			l.queue_free()
			_dying.remove_at(i)
		else:
			l.visible_characters = int(ceil(r.shown))
