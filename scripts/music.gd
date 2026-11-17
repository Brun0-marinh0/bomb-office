extends Node
## Música de entrada (menu e sala de espera).
## Sorteia uma faixa de assets/sounds/intro/ (.ogg ou .mp3), toca em loop e,
## quando a partida começa, abaixa o volume aos poucos até 0 e para.
## Para adicionar músicas, basta colocar mais arquivos .ogg na pasta.

const WebAudio = preload("res://scripts/web_audio.gd")
const DIR := "res://assets/sounds/intro"
const EXTS := ["ogg", "mp3"]
const VOLUME_DB := -6.0
const FADE_IN := 1.0
const FADE_OUT := 2.5

var player: AudioStreamPlayer
var _tracks: Array[String] = []
var _last := ""
var _tween: Tween
var _fading_out := false
var _web_playing := false   # tocando pelo WebAudio (na web as faixas não vão no pacote do jogo)


func _ready() -> void:
	player = AudioStreamPlayer.new()
	add_child(player)
	_tracks = _find_tracks()


## Começa (ou continua) a música de entrada. Se estiver sumindo, volta ao normal.
func play_intro() -> void:
	if WebAudio.web():
		_play_intro_web()
		return
	if _tracks.is_empty():
		return
	if player.playing and not _fading_out:
		return
	if player.playing and _fading_out:
		_fade_to(VOLUME_DB, FADE_IN, false)
		return
	var choices := _tracks.duplicate()
	if choices.size() > 1:
		choices.erase(_last)    # evita repetir a mesma música da vez anterior
	_last = choices.pick_random()
	var stream = load(_last)
	if stream == null:
		return
	if "loop" in stream:
		stream.loop = true
	player.stream = stream
	player.volume_db = -40.0
	player.play()
	print("[musica] tocando %s" % _last.get_file())
	_fade_to(VOLUME_DB, FADE_IN, false)


## A partida começou: abaixa o volume até 0 e para.
func fade_out() -> void:
	if WebAudio.web():
		if _web_playing and not _fading_out:
			_fading_out = true
			WebAudio.fade_music(0.0, FADE_OUT, true)
			get_tree().create_timer(FADE_OUT).timeout.connect(func():
				if _fading_out:
					_web_playing = false
					_fading_out = false
					print("[musica] parou (partida começou)"))
		return
	if not player.playing or _fading_out:
		return
	_fade_to(-80.0, FADE_OUT, true)


## Mesmo comportamento de play_intro(), tocando pelo WebAudio em streaming
## (o sorteio da faixa é feito no navegador, a partir de assets/sounds/intro/index.json).
func _play_intro_web() -> void:
	if _web_playing and not _fading_out:
		return
	if _web_playing and _fading_out:
		_fading_out = false
		WebAudio.fade_music(db_to_linear(VOLUME_DB), FADE_IN, false)
		return
	WebAudio.play_random_intro(db_to_linear(VOLUME_DB), FADE_IN)
	_web_playing = true
	_fading_out = false


func _fade_to(db: float, secs: float, stop_after: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_fading_out = stop_after
	_tween = create_tween()
	# fade linear na amplitude (soa mais natural que linear em dB)
	_tween.tween_method(_set_linear, db_to_linear(player.volume_db), db_to_linear(db), secs)
	if stop_after:
		_tween.tween_callback(func():
			player.stop()
			_fading_out = false
			print("[musica] parou (partida começou)"))


func _set_linear(v: float) -> void:
	player.volume_db = maxf(linear_to_db(v), -80.0)


## Lista as faixas da pasta. No jogo exportado os arquivos aparecem como
## "nome.ogg.import"/".remap", por isso o sufixo é removido.
func _find_tracks() -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	for f in DirAccess.get_files_at(DIR):
		var name := f.trim_suffix(".import").trim_suffix(".remap")
		var path := DIR + "/" + name
		if name.get_extension().to_lower() in EXTS and not out.has(path):
			out.append(path)
	return out
