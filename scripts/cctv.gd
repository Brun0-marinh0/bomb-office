extends CanvasLayer
## Imagem de câmera de vigilância por cima de todas as telas (menus e partida).
## - OSD gravado na imagem: "● REC", câmera/tela, data/hora do aparelho.
## - Filtro (shaders/cctv.gdshader): lente, linhas de TV, granulado, vinheta.
## - Interferência: glitch nas explosões e em cada troca de tela; chuvisco "SEM SINAL" na troca de rodada.
## Fica na camada 2: acima da arena (0) e das telas de menu (1), abaixo da UI nítida (3).

const SHADER := preload("res://shaders/cctv.gdshader")
const CAMS := 4                 # a cada rodada "troca de câmera": CAM 01 -> 02 -> 03 -> 04 -> 01
const NO_SIGNAL := 0.45         # segundos de chuvisco total no começo da rodada
const SNOW_FADE := 0.3          # depois o chuvisco some aos poucos
const FLASH := 0.15             # chuvisco rápido na troca de tela
const BARREL_GAME := 0.10       # olho-de-peixe na partida
const BARREL_MENU := 0.06       # mais leve nos menus, para o clique não desalinhar dos botões

var screen := "menu"
var room_name := ""
var cam := 1
var t := 0.0
var _glitch := 0.0
var _flash := 0.0
var _cut_t := -1.0              # tempo desde a troca de câmera (-1 = nenhuma em andamento)
var _mat: ShaderMaterial
var _osd: Control


func _ready() -> void:
	_osd = OSD.new()
	_osd.cctv = self
	add_child(_osd)
	var filter := ColorRect.new()
	filter.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	filter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	filter.material = _mat
	add_child(filter)   # por último: o filtro distorce o OSD junto, como numa câmera de verdade
	set_screen(screen)


## Tela atual (boot, menu, rooms, lobby, game): muda o texto da câmera e a lente.
func set_screen(s: String) -> void:
	screen = s
	if _mat != null:
		_mat.set_shader_parameter("barrel", BARREL_GAME if s == "game" else BARREL_MENU)
	if s != "game":
		_cut_t = -1.0


func set_room(n: String) -> void:
	room_name = n


## Explosão: a imagem falha por um instante (explosões em cadeia somam).
func glitch(amount := 0.35) -> void:
	_glitch = minf(1.0, _glitch + amount)


## Troca de tela: falha forte com um chuvisco rápido.
func screen_cut() -> void:
	_glitch = 0.9
	_flash = FLASH


## Começo de rodada: chuvisco "SEM SINAL" e entra a próxima câmera.
func round_cut(round_no: int) -> void:
	cam = (maxi(round_no, 1) - 1) % CAMS + 1
	_cut_t = 0.0


func no_signal() -> bool:
	return _cut_t >= 0.0 and _cut_t < NO_SIGNAL


func cutting() -> bool:
	return _cut_t >= 0.0


func _process(dt: float) -> void:
	t += dt
	_glitch = maxf(0.0, _glitch - dt * 3.0)
	_flash = maxf(0.0, _flash - dt)
	var snow := 0.0
	if _cut_t >= 0.0:
		_cut_t += dt
		snow = clampf(1.0 - (_cut_t - NO_SIGNAL) / SNOW_FADE, 0.0, 1.0)
		if _cut_t > NO_SIGNAL + SNOW_FADE + 0.6:
			_cut_t = -1.0
	snow = maxf(snow, 0.7 * _flash / FLASH)
	_mat.set_shader_parameter("glitch", _glitch)
	_mat.set_shader_parameter("snow", snow)
	_osd.queue_redraw()


# =================================================================== texto da câmera
class OSD extends Control:
	const COL := Color(1, 1, 1, 0.88)
	const SHADOW := Color(0, 0, 0, 0.85)
	var cctv: Node

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _text(pos: Vector2, s: String, px: int, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0,
			col := COL) -> void:
		var font: Font = MenuStyle.font()
		var size_px := MenuStyle.fs(px)
		draw_string_outline(font, pos, s, align, width, size_px, 4, SHADOW)
		draw_string(font, pos, s, align, width, size_px, col)

	func _draw() -> void:
		var s: String = cctv.screen
		if s == "boot":
			return
		var w := size.x
		var h := size.y
		# ● REC (na partida fica abaixo do relógio da rodada)
		var rec_y := 70.0 if s == "game" else 30.0
		if int(cctv.t * 2.0) % 2 == 0:
			draw_circle(Vector2(24, rec_y), 6.0, MenuStyle.REC)
		_text(Vector2(36, rec_y + 7), "REC", 17)
		# câmera / tela (canto inferior esquerdo)
		var cam_txt := ""
		match s:
			"game":
				cam_txt = "CAM %02d" % cctv.cam
				if cctv.room_name != "":
					cam_txt += "  •  SALA %s" % String(cctv.room_name).to_upper()
			"menu":
				cam_txt = "CAM 00  •  RECEPÇÃO"
			"rooms":
				cam_txt = "MONITORAMENTO  •  SALAS"
			"lobby":
				cam_txt = "CAM  •  SALA %s" % String(cctv.room_name).to_upper()
		_text(Vector2(16, h - 48 if s == "game" else h - 16), cam_txt, 16)
		# data e hora do aparelho (canto inferior direito; na partida acima do ping)
		var d := Time.get_datetime_dict_from_system()
		var stamp := "%02d/%02d/%04d  %02d:%02d:%02d" % [d.day, d.month, d.year, d.hour, d.minute, d.second]
		_text(Vector2(0, h - 34 if s == "game" else h - 16), stamp, 16, HORIZONTAL_ALIGNMENT_RIGHT, w - 16)
		# troca de câmera (acima do aviso "RODADA N", que fica no centro)
		if s == "game" and cctv.cutting():
			var big := "SEM SINAL" if cctv.no_signal() else "CAM %02d" % cctv.cam
			_text(Vector2(0, h * 0.3), big, 44, HORIZONTAL_ALIGNMENT_CENTER, w)
