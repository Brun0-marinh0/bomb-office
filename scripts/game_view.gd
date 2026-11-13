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


func apply(s: Array) -> void:
	tiles = s[1]
	flames = s[2]
	items = s[3]
	players = s[4]
	bombs = s[5]
	has_data = true


func on_event(kind: String, _data: Array) -> void:
	if kind == "boom":
		shake = maxf(shake, 0.12)


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
	var flame := Sprites.tex("flame")

	# ---- arena
	for y in G.H:
		for x in G.W:
			var k := y * G.W + x
			var r := Rect2(x * T, y * T, T, T)
			var tt: int = tiles[k]
			if tt == G.T_HARD:
				draw_texture_rect(hard, r, false)
			elif tt == G.T_FALLEN:
				draw_texture_rect(fallen, r, false)
			else:
				draw_texture_rect(floor_a if (x + y) % 2 == 0 else floor_b, r, false)
				if tt == G.T_SOFT:
					draw_texture_rect(soft, r, false)
				elif tt == G.T_BURNING:
					draw_texture_rect(soft, r, false, Color(1.0, 0.45 + 0.3 * sin(t * 40.0), 0.2))
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
	sorted.sort_custom(func(a, b): return a[2] < b[2])
	for e in sorted:
		if not e[3]:
			continue
		var id: int = e[0]
		var pos: Vector2 = pdisp.get(id, Vector2(e[1], e[2]))
		var center := pos * T
		var r := Rect2(center - Vector2(T, T) * 0.5, Vector2(T, T))
		var bits: int = e[6]
		var col: Color = G.PLAYER_COLORS[int(colors.get(id, 0)) % G.PLAYER_COLORS.size()]
		if int(e[7]) != 0 and int(t * 6.0) % 2 == 0:
			col = col.lerp(Color(0.45, 1.0, 0.3), 0.6)
		if (bits & 768) != 0 and int(t * 14.0) % 2 == 0:
			col.a = 0.35
		draw_texture_rect(ptex, r, false, col)
		if not pcustom:
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
