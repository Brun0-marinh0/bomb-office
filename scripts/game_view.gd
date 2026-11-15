extends Node2D
## Renderiza a arena a partir dos snapshots enviados pelo servidor (somente clientes).
## Tudo é desenhado com texturas 32x32 vindas do autoload Sprites.

const G = preload("res://scripts/g.gd")

var has_data := false
var tiles := PackedByteArray()
var flames := PackedByteArray()
var items := PackedByteArray()
var players: Array = []
var bombs: Array = []
var pdisp := {}      # id -> posição exibida (suavizada)
var bdisp := {}
var colors := {}
var names := {}
var my_id := 0
var t := 0.0
var shake := 0.0
var actions := {}    # id -> [animação, instante em que começou] (soltar bomba / arremessar)
var death_t := {}    # id -> instante da morte
var winner := 0      # vencedor da rodada (animação de comemoração)

## Decoração da parede de cima (assets/sprites/officeWall/); colunas sem entrada usam wall_plain.
const WALL_DECOR := {3: "wall_notice_board", 5: "wall_air_conditioner", 8: "wall_clock", 11: "wall_air_conditioner", 13: "wall_notice_board"}

const SOFT_FPS := 10.0  # animação da mesa (bloco destrutível), assets/sprites/deskOffice/
const ANIM_FPS := {"walk": 12.0, "place_bomb": 16.0, "throw": 18.0, "dizzy": 8.0, "death": 12.0, "victory": 6.0}

## Efeitos sonoros (assets/sounds/). Se o arquivo não existir, o jogo segue sem som.
const SFX_EXPLOSION := "res://assets/sounds/explosion/boom.mp3"
var sfx_boom: AudioStreamPlayer


func _ready() -> void:
	sfx_boom = AudioStreamPlayer.new()
	sfx_boom.max_polyphony = 8  # explosões em cadeia tocam sobrepostas
	sfx_boom.bus = "Efeitos"   # volume ajustado em Configurações (settings_menu.gd)
	if ResourceLoader.exists(SFX_EXPLOSION):
		sfx_boom.stream = load(SFX_EXPLOSION)
	add_child(sfx_boom)


func play_boom() -> void:
	if sfx_boom.stream != null:
		sfx_boom.play()


func set_roster(list: Array) -> void:
	for e in list:
		colors[e[0]] = e[2]
		names[e[0]] = e[1]


func reset() -> void:
	has_data = false
	pdisp.clear()
	bdisp.clear()
	players = []
	bombs = []
	actions.clear()
	death_t.clear()
	winner = 0


func apply(s: Array) -> void:
	tiles = s[1]
	flames = s[2]
	items = s[3]
	players = s[4]
	bombs = s[5]
	has_data = true


func on_event(kind: String, data: Array) -> void:
	match kind:
		"boom":
			shake = maxf(shake, 0.12)
			play_boom()
		"placed":
			actions[data[0]] = ["place_bomb", t]
		"punch":
			actions[data[0]] = ["throw", t]
		"death":
			death_t[data[0]] = t


## Escolhe o quadro da animação do jogador. Retorna null se não houver sprites (usa o bloco).
func _player_frame(e: Array) -> Texture2D:
	var id: int = e[0]
	var bits: int = e[6]
	var anim := ""
	var elapsed := 0.0
	var loop := true
	if not e[3]:
		anim = "death"
		elapsed = t - float(death_t.get(id, -100.0))
		loop = false
	elif id == winner:
		anim = "victory"
		elapsed = t
	elif actions.has(id) and t - float(actions[id][1]) < _anim_length(actions[id][0]):
		anim = actions[id][0]
		elapsed = t - float(actions[id][1])
		loop = false
	elif (bits & 2048) != 0:
		anim = "walk_" + _dir_name(int(e[4]), int(e[5]))
		elapsed = t
	elif int(e[7]) != 0:
		anim = "dizzy"
		elapsed = t
	else:
		var idle: Array = Sprites.frames("walk_" + _dir_name(int(e[4]), int(e[5])))
		return idle[0] if not idle.is_empty() else null
	var list: Array = Sprites.frames(anim)
	if list.is_empty():
		return null
	var fps: float = ANIM_FPS.get("walk" if anim.begins_with("walk_") else anim, 10.0)
	var i := int(elapsed * fps)
	if anim == "victory":
		var n := list.size()
		i = i % maxi(1, n * 2 - 2)
		if i >= n:
			i = n * 2 - 2 - i   # vai e volta
	elif loop:
		i = i % list.size()
	else:
		i = clampi(i, 0, list.size() - 1)
	return list[i]


func _anim_length(anim: String) -> float:
	return Sprites.frames(anim).size() / float(ANIM_FPS.get(anim, 10.0))


func _dir_name(fx: int, fy: int) -> String:
	if fx > 0:
		return "right"
	if fx < 0:
		return "left"
	if fy < 0:
		return "up"
	return "down"


func _process(dt: float) -> void:
	t += dt
	shake = maxf(0.0, shake - dt)
	var a := 1.0 - exp(-dt * 22.0)
	for e in players:
		var id: int = e[0]
		var target := Vector2(e[1], e[2])
		if not pdisp.has(id) or (pdisp[id] as Vector2).distance_to(target) > 1.5:
			pdisp[id] = target
		else:
			pdisp[id] = (pdisp[id] as Vector2).lerp(target, a)
	var seen := {}
	for e in bombs:
		var id: int = e[0]
		seen[id] = true
		var target := Vector2(e[1], e[2])
		if not bdisp.has(id) or (bdisp[id] as Vector2).distance_to(target) > 1.5:
			bdisp[id] = target
		else:
			bdisp[id] = (bdisp[id] as Vector2).lerp(target, a)
	for id in bdisp.keys():
		if not seen.has(id):
			bdisp.erase(id)
	queue_redraw()


func _is_edge(x: int, y: int) -> bool:
	return x == 0 or y == 0 or x == G.W - 1 or y == G.H - 1


## Borda do escritório: parede alta em cima (com decorações), parede fina nos lados e embaixo.
## As partes transparentes dos sprites deixam ver o fundo, fora da sala.
func _draw_wall(x: int, y: int, r: Rect2) -> void:
	if y == 0 or y == G.H - 1:
		var tex := Sprites.tex("officeWall/" + (WALL_DECOR.get(x, "wall_plain") if y == 0 else "wall_bottom"))
		# nos cantos só o pedaço que encontra a parede lateral (que tem 7 px de espessura)
		if x == 0:
			draw_texture_rect_region(tex, Rect2(r.position + Vector2(25, 0), Vector2(7, 32)), Rect2(25, 0, 7, 32))
		elif x == G.W - 1:
			draw_texture_rect_region(tex, Rect2(r.position, Vector2(7, 32)), Rect2(0, 0, 7, 32))
		else:
			draw_texture_rect(tex, r, false)
	elif x == 0:
		draw_texture_rect(Sprites.tex("officeWall/wall_left"), r, false)
	else:
		draw_texture_rect(Sprites.tex("officeWall/wall_right"), r, false)


func _draw() -> void:
	if not has_data:
		return
	var T := float(G.TILE)
	if shake > 0.0:
		draw_set_transform(Vector2(randf_range(-3, 3), randf_range(-3, 3)))
	var floor_a := Sprites.tex("floor")
	var floor_b := Sprites.tex("floor_alt")
	var hard := Sprites.tex("hard")
	var fallen := Sprites.tex("fallen")
	var soft := Sprites.tex("soft")
	var soft_anim: Array = Sprites.seq("deskOffice/deskOffice_")
	var flame := Sprites.tex("flame")
	var use_wall := Sprites.is_custom("officeWall/wall_plain")

	# ---- arena
	for y in G.H:
		for x in G.W:
			var k := y * G.W + x
			var r := Rect2(x * T, y * T, T, T)
			var tt: int = tiles[k]
			if tt == G.T_HARD and use_wall and _is_edge(x, y):
				_draw_wall(x, y, r)
			elif tt == G.T_HARD:
				draw_texture_rect(hard, r, false)
			elif tt == G.T_FALLEN:
				draw_texture_rect(fallen, r, false)
			else:
				draw_texture_rect(floor_a if (x + y) % 2 == 0 else floor_b, r, false)
				var st: Texture2D = soft
				if not soft_anim.is_empty():
					# cada mesa começa num quadro diferente para não piscarem todas juntas
					var f := int(t * SOFT_FPS + (x * 7 + y * 13)) % soft_anim.size()
					st = soft_anim[f]
				if tt == G.T_SOFT:
					draw_texture_rect(st, r, false)
				elif tt == G.T_BURNING:
					draw_texture_rect(st, r, false, Color(1.0, 0.45 + 0.3 * sin(t * 40.0), 0.2))
				elif items[k] != 0:
					Sprites.draw_item(self, items[k], r)

	# ---- bombas
	var btex := Sprites.tex("bomb")
	var bomb_custom := Sprites.is_custom("bomb")
	for e in bombs:
		var id: int = e[0]
		var pos: Vector2 = bdisp.get(id, Vector2(e[1], e[2]))
		var z: float = e[3]
		var kind: int = e[4]
		var frac: float = e[5]
		var pulse := 1.0 + 0.07 * sin(t * (8.0 + 22.0 * (1.0 - frac)))
		var sz := T * pulse
		var c := pos * T - Vector2(0, z * T)
		if z > 0.01:
			draw_rect(Rect2(pos * T + Vector2(-9, 8), Vector2(18, 5)), Color(0, 0, 0, 0.35))
		var tint := Color.WHITE
		if (kind & 1) != 0:
			tint = Color(0.55, 0.7, 1.0)
		elif (kind & 2) != 0:
			tint = Color(0.85, 0.55, 1.0)
		if (kind & 4) != 0:
			tint = Color(1.0, 0.5, 0.5)
		draw_texture_rect(btex, Rect2(c - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), false, tint)
		if not bomb_custom:
			if (kind & 1) != 0:
				draw_rect(Rect2(c - Vector2(2, 2), Vector2(4, 4)), Color(1, 0.2, 0.2) if int(t * 4) % 2 == 0 else Color(0.4, 0, 0))
			elif int(t * 10) % 2 == 0:
				draw_rect(Rect2(c + Vector2(5, -12), Vector2(5, 5)), Color(1, 0.85, 0.2))

	# ---- fogo
	var fa := 0.85 + 0.15 * sin(t * 30.0)
	for k in flames.size():
		if flames[k] != 0:
			var x := k % G.W
			var y := k / G.W
			draw_texture_rect(flame, Rect2(x * T, y * T, T, T), false, Color(1, 1, 1, fa))

	# ---- jogadores
	var ptex := Sprites.tex("player")
	var pcustom := Sprites.is_custom("player")
	var font := ThemeDB.fallback_font
	var sorted := players.duplicate()
	# mortos primeiro (ficam por baixo), depois os vivos de cima para baixo
	sorted.sort_custom(func(a, b): return (not a[3]) if a[3] != b[3] else a[2] < b[2])
	for e in sorted:
		var id: int = e[0]
		var frame := _player_frame(e)
		if not e[3] and frame == null:
			continue   # sem sprites: morto some (como antes)
		var pos: Vector2 = pdisp.get(id, Vector2(e[1], e[2]))
		var center := pos * T
		var r := Rect2(center - Vector2(T, T) * 0.5, Vector2(T, T))
		var bits: int = e[6]
		var col: Color = G.PLAYER_COLORS[int(colors.get(id, 0)) % G.PLAYER_COLORS.size()]
		if not e[3]:
			# corpo fica no chão, desbotando depois da animação de morte
			var since := t - float(death_t.get(id, -100.0))
			col.a = clampf(1.0 - (since - 0.7) * 0.5, 0.35, 1.0)
			draw_texture_rect(frame, r, false, col)
			continue
		if int(e[7]) != 0 and int(t * 6.0) % 2 == 0:
			col = col.lerp(Color(0.45, 1.0, 0.3), 0.6)
		if (bits & 768) != 0 and int(t * 14.0) % 2 == 0:
			col.a = 0.35
		if frame != null:
			draw_texture_rect(frame, r, false, col)
		else:
			draw_texture_rect(ptex, r, false, col)
		if frame == null and not pcustom:
			var f := Vector2(e[4], e[5])
			var eye := center + f * 6.0
			var side := Vector2(-f.y, f.x) * 5.0
			var ec := Color(0.05, 0.05, 0.08, col.a)
			draw_rect(Rect2(eye + side - Vector2(2, 2), Vector2(4, 4)), ec)
			draw_rect(Rect2(eye - side - Vector2(2, 2), Vector2(4, 4)), ec)
		if (bits & 256) != 0:
			draw_rect(r.grow(-1.0), Color(0.3, 1.0, 0.5, 0.9), false, 2.0)
		if (bits & 1024) != 0:
			draw_rect(Rect2(r.position + Vector2(T - 9, 1), Vector2(7, 6)), Color(1.0, 0.35, 0.5))
		var nm: String = names.get(id, "?")
		var npos := Vector2(center.x - 50, r.position.y - 3)
		var ncol := Color(1, 0.92, 0.3) if id == my_id else Color.WHITE
		draw_string_outline(font, npos, nm, HORIZONTAL_ALIGNMENT_CENTER, 100, 10, 3, Color(0, 0, 0, 0.85))
		draw_string(font, npos, nm, HORIZONTAL_ALIGNMENT_CENTER, 100, 10, ncol)
		if id == my_id:
			var tip := Vector2(center.x, r.position.y - 14)
			draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-5, -6), tip + Vector2(5, -6)]), ncol)
