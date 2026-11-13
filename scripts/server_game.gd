extends Node
## Simulação autoritativa de uma rodada. Roda SOMENTE no servidor.
## Os clientes apenas enviam comandos (direção / bomba / ação) e recebem snapshots.

const G = preload("res://scripts/g.gd")
const INF_T := 999.0

signal round_over(winner_id: int)        # 0 = empate
signal game_event(kind: String, data: Array)

var tiles := PackedByteArray()
var items := PackedByteArray()
var flames := PackedFloat32Array()
var burn := PackedFloat32Array()
var bombs: Array = []
var players: Dictionary = {}             # id -> Dictionary
var time_left := 180.0
var running := false
var ending := false
var end_timer := 0.0
var sudden_active := false
var sudden_cells: Array = []
var sudden_index := 0
var sudden_timer := 0.0
var rng := RandomNumberGenerator.new()

var _next_bomb_id := 1
var _tick_count := 0
var _danger := PackedFloat32Array()
var _danger_frame := -1


# ====================================================================== setup
func start_round(roster: Array, round_time: float) -> void:
	rng.randomize()
	var n := G.W * G.H
	tiles.resize(n)
	tiles.fill(G.T_EMPTY)
	items.resize(n)
	items.fill(G.I_NONE)
	flames.resize(n)
	flames.fill(0.0)
	burn.resize(n)
	burn.fill(0.0)
	bombs.clear()
	players.clear()
	time_left = round_time
	running = true
	ending = false
	end_timer = 0.0
	sudden_active = false
	sudden_cells = G.spiral_cells()
	sudden_index = 0
	sudden_timer = 0.0
	_danger_frame = -1
	var spawns: Array = []
	for i in roster.size():
		spawns.append(G.SPAWNS[i])
	_build_map(spawns)
	for i in roster.size():
		var r: Dictionary = roster[i]
		players[r.id] = _new_player(r, spawns[i])


func _new_player(r: Dictionary, spawn: Vector2i) -> Dictionary:
	return {
		"id": r.id, "name": r.name, "bot": r.bot,
		"pos": G.center_of(spawn), "alive": true,
		"facing": Vector2i(0, 1), "dir": Vector2i.ZERO,
		"bombs_max": G.START_BOMBS, "fire": G.START_FIRE, "speed_lvl": 0,
		"kick": false, "punch": false, "remote": false, "pierce": false, "line": false,
		"power": false, "wall_pass": false, "bomb_pass": false,
		"vest_t": 0.0, "hearts": 0, "invuln_t": 0.0,
		"disease": G.D_NONE, "disease_t": 0.0,
		"collected": [], "ai_path": [], "ai_timer": 0.0,
	}


func _build_map(spawns: Array) -> void:
	var safe := {}
	for s in spawns:
		safe[s] = true
		for d in G.DIRS:
			safe[s + d] = true
	var total := 0
	for w in G.ITEM_WEIGHTS:
		total += w
	for y in G.H:
		for x in G.W:
			var c := Vector2i(x, y)
			var k: int = G.idx(c)
			if G.is_pillar(c):
				tiles[k] = G.T_HARD
			elif not safe.has(c) and rng.randf() < G.SOFT_DENSITY:
				tiles[k] = G.T_SOFT
				if rng.randf() < G.ITEM_CHANCE:
					items[k] = _random_item(total)


func _random_item(total: int) -> int:
	var r := rng.randi_range(1, total)
	for i in range(1, G.ITEM_COUNT):
		r -= G.ITEM_WEIGHTS[i]
		if r <= 0:
			return i
	return G.I_BOMB_UP


# ====================================================================== comandos dos jogadores
func set_input(id: int, d: Vector2i) -> void:
	if not players.has(id):
		return
	if d.x != 0 and d.y != 0:
		d.y = 0
	players[id].dir = d


func request_bomb(id: int) -> void:
	if running and players.has(id):
		_try_place_bomb(players[id], true)


func request_action(id: int) -> void:
	if running and players.has(id):
		_do_action(players[id])


func remove_player(id: int) -> void:
	if players.has(id) and players[id].alive:
		_kill(players[id])


# ====================================================================== loop
func tick(dt: float) -> void:
	if not running:
		return
	_tick_count += 1
	time_left = maxf(0.0, time_left - dt)
	_update_sudden(dt)
	for p in players.values():
		if not p.alive:
			continue
		if p.bot:
			_bot_think(p, dt)
		_update_status(p, dt)
		if p.alive:
			_move_player(p, dt)
	_update_bombs(dt)
	_update_fire(dt)
	_check_hits()
	_check_pickups()
	_check_contagion()
	_check_end(dt)


func _update_status(p: Dictionary, dt: float) -> void:
	if p.vest_t > 0.0:
		p.vest_t = maxf(0.0, p.vest_t - dt)
	if p.invuln_t > 0.0:
		p.invuln_t = maxf(0.0, p.invuln_t - dt)
	if p.disease != G.D_NONE:
		p.disease_t -= dt
		if p.disease_t <= 0.0:
			p.disease = G.D_NONE
		elif p.disease == G.D_DIARRHEA:
			_try_place_bomb(p, false)


# ====================================================================== movimento
func _speed(p: Dictionary) -> float:
	if p.disease == G.D_SLOW:
		return G.SLOW_SPEED
	if p.disease == G.D_FAST:
		return G.FAST_SPEED
	return G.BASE_SPEED + float(p.speed_lvl) * G.SPEED_STEP


func _passable(p: Dictionary, c: Vector2i) -> bool:
	if not G.in_bounds(c):
		return false
	var t: int = tiles[G.idx(c)]
	if t == G.T_HARD or t == G.T_FALLEN:
		return false
	if (t == G.T_SOFT or t == G.T_BURNING) and not p.wall_pass:
		return false
	var b = _bomb_at(c)
	if b != null and not p.bomb_pass and not b.pass_ids.has(p.id):
		return false
	return true


## Movimento em grade com "assistência de curva": o jogador escorrega para o
## corredor quando aperta a direção um pouco desalinhado.
func _move_player(p: Dictionary, dt: float) -> void:
	var d: Vector2i = p.dir
	if p.disease == G.D_REVERSE:
		d = -d
	if d == Vector2i.ZERO:
		return
	p.facing = d
	var step := _speed(p) * dt
	var pos: Vector2 = p.pos
	var cell: Vector2i = G.cell_of(pos)
	var center: Vector2 = G.center_of(cell)
	var axis := Vector2(d)
	var perp := Vector2(absi(d.y), absi(d.x))
	var off := (pos - center).dot(perp)
	var along := (pos - center).dot(axis)
	var ahead: Vector2i = cell + d
	if _passable(p, ahead):
		if absf(off) > 0.001:
			var m := minf(step, absf(off))
			pos -= perp * signf(off) * m
			step -= m
		pos += axis * step
	else:
		if along >= -0.05 and absf(off) < 0.3:
			_try_kick(p, ahead, d)
		if along < 0.0:
			pos += axis * minf(step, -along)
		elif absf(off) > G.CORNER_ASSIST:
			var side := Vector2i(int(perp.x * signf(off)), int(perp.y * signf(off)))
			if _passable(p, cell + side) and _passable(p, cell + side + d):
				pos += perp * signf(off) * step
	# nunca passar do centro de um tile cuja frente está bloqueada
	var ncell: Vector2i = G.cell_of(pos)
	var ncenter: Vector2 = G.center_of(ncell)
	var nalong := (pos - ncenter).dot(axis)
	if nalong > 0.0 and not _passable(p, ncell + d):
		pos -= axis * nalong
	p.pos = pos


func _overlaps(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) < 0.8 and absf(a.y - b.y) < 0.8


func _player_on(c: Vector2i) -> bool:
	var cc: Vector2 = G.center_of(c)
	for q in players.values():
		if q.alive and _overlaps(q.pos, cc):
			return true
	return false


# ====================================================================== bombas
func _bomb_at(c: Vector2i):
	for b in bombs:
		if not b.fly and b.cell == c:
			return b
	return null


func _count_bombs(id: int) -> int:
	var n := 0
	for b in bombs:
		if b.owner == id:
			n += 1
	return n


func _has_power_bomb(id: int) -> bool:
	for b in bombs:
		if b.owner == id and b.power:
			return true
	return false


func _try_place_bomb(p: Dictionary, allow_line: bool) -> void:
	if not running or not p.alive or p.disease == G.D_CONSTIPATION:
		return
	var cell: Vector2i = G.cell_of(p.pos)
	if _bomb_at(cell) != null:
		if allow_line and p.line:
			_place_line(p, cell)
		return
	if tiles[G.idx(cell)] != G.T_EMPTY:
		return
	if _count_bombs(p.id) >= p.bombs_max:
		return
	_spawn_bomb(p, cell)


func _spawn_bomb(p: Dictionary, cell: Vector2i) -> void:
	var rng_fire: int = p.fire
	var power := false
	if p.disease == G.D_SHORT_FIRE:
		rng_fire = 1
	elif p.power and not _has_power_bomb(p.id):
		rng_fire = G.POWER_RANGE
		power = true
	var b := {
		"id": _next_bomb_id, "owner": p.id, "cell": cell, "pos": G.center_of(cell),
		"fuse": G.SHORT_FUSE if p.disease == G.D_SHORT_FUSE else G.FUSE,
		"range": rng_fire, "pierce": p.pierce, "remote": p.remote, "power": power,
		"pass_ids": [], "move": Vector2i.ZERO, "dead": false,
		"fly": false, "fly_from": Vector2.ZERO, "fly_vec": Vector2.ZERO, "fly_dir": Vector2i.ZERO,
		"fly_t": 0.0, "fly_dur": 1.0, "bounces": 0,
	}
	_next_bomb_id += 1
	for q in players.values():
		if q.alive and _overlaps(q.pos, b.pos):
			b.pass_ids.append(q.id)
	bombs.append(b)
	_danger_frame = -1


## Bomba em Linha: apertar BOMBA em cima de uma bomba solta todas as restantes em linha.
func _place_line(p: Dictionary, cell: Vector2i) -> void:
	var d: Vector2i = p.facing
	var c: Vector2i = cell + d
	while _count_bombs(p.id) < p.bombs_max:
		if not G.in_bounds(c) or tiles[G.idx(c)] != G.T_EMPTY or _bomb_at(c) != null or _player_on(c):
			break
		_spawn_bomb(p, c)
		c += d


func _do_action(p: Dictionary) -> void:
	if not running or not p.alive:
		return
	if p.punch:
		var here: Vector2i = G.cell_of(p.pos)
		var b = _bomb_at(here + p.facing)
		if b == null:
			b = _bomb_at(here)
		if b != null:
			_launch(b, p.facing, G.PUNCH_DIST)
			return
	if p.remote:
		for b in bombs:
			if b.owner == p.id and b.remote and not b.fly:
				b.remote = false
				b.fuse = 0.0
				return


func _try_kick(p: Dictionary, ahead: Vector2i, d: Vector2i) -> void:
	if not p.kick:
		return
	var b = _bomb_at(ahead)
	if b == null or b.move != Vector2i.ZERO:
		return
	if _cell_blocked_for_bomb(ahead + d):
		return
	b.move = d
	b.pass_ids = []


func _launch(b: Dictionary, d: Vector2i, dist: int) -> void:
	b.fly = true
	b.move = Vector2i.ZERO
	b.pass_ids = []
	b.fly_from = G.center_of(b.cell)
	b.fly_vec = Vector2(d * dist)
	b.fly_dir = d
	b.fly_t = 0.0
	b.fly_dur = G.PUNCH_TIME_PER_TILE * dist
	b.bounces = 0
	_danger_frame = -1


func _cell_blocked_for_bomb(c: Vector2i) -> bool:
	if not G.in_bounds(c):
		return true
	if tiles[G.idx(c)] != G.T_EMPTY:
		return true
	if _bomb_at(c) != null:
		return true
	return _player_on(c)


## Arremesso dá a volta na arena (sai de um lado, entra do outro).
func _wrap(v: Vector2) -> Vector2:
	return Vector2(1.0 + fposmod(v.x - 1.0, float(G.W - 2)), 1.0 + fposmod(v.y - 1.0, float(G.H - 2)))


func _update_bombs(dt: float) -> void:
	for b in bombs.duplicate():
		if b.dead:
			continue
		if b.fly:
			b.fly_t += dt
			var ft := minf(1.0, b.fly_t / b.fly_dur)
			b.pos = _wrap(b.fly_from + b.fly_vec * ft)
			if ft >= 1.0:
				_land(b)
			continue
		if b.move != Vector2i.ZERO:
			_slide(b, dt)
		if flames[G.idx(b.cell)] > 0.0:
			b.remote = false
			b.fuse = minf(b.fuse, G.CHAIN_DELAY)
		if not b.remote:
			b.fuse -= dt
			if b.fuse <= 0.0:
				_explode(b)
				continue
		if b.pass_ids.size() > 0:
			var keep: Array = []
			for id in b.pass_ids:
				if players.has(id) and players[id].alive and _overlaps(players[id].pos, b.pos):
					keep.append(id)
			b.pass_ids = keep


func _land(b: Dictionary) -> void:
	var cell: Vector2i = G.cell_of(b.pos)
	if _cell_blocked_for_bomb(cell):
		b.bounces += 1
		if b.bounces > 30:
			b.fly = false
			b.cell = cell
			b.fuse = 0.0
			b.remote = false
			return
		b.fly_from = G.center_of(cell)
		b.fly_vec = Vector2(b.fly_dir)
		b.fly_t = 0.0
		b.fly_dur = G.PUNCH_TIME_PER_TILE * 1.5
		return
	b.fly = false
	b.cell = cell
	b.pos = G.center_of(cell)
	_danger_frame = -1


func _slide(b: Dictionary, dt: float) -> void:
	var d: Vector2i = b.move
	var axis := Vector2(d)
	var center: Vector2 = G.center_of(b.cell)
	var along: float = (b.pos - center).dot(axis)
	var step := G.KICK_SPEED * dt
	if along + step >= 0.0 and _cell_blocked_for_bomb(b.cell + d):
		b.pos = center
		b.move = Vector2i.ZERO
		return
	b.pos += axis * step
	b.cell = G.cell_of(b.pos)
	_danger_frame = -1


func _explode(b: Dictionary) -> void:
	if b.dead:
		return
	b.dead = true
	for i in bombs.size():
		if bombs[i].id == b.id:
			bombs.remove_at(i)
			break
	var origin: Vector2i = b.cell
	var ok: int = G.idx(origin)
	flames[ok] = G.FLAME_TIME
	items[ok] = G.I_NONE
	for d in G.DIRS:
		for i in range(1, int(b.range) + 1):
			var c: Vector2i = origin + d * i
			if not G.in_bounds(c):
				break
			var k: int = G.idx(c)
			var t: int = tiles[k]
			if t == G.T_HARD or t == G.T_FALLEN:
				break
			if t == G.T_SOFT:
				tiles[k] = G.T_BURNING
				burn[k] = G.FLAME_TIME
				if b.pierce:
					continue
				break
			if t == G.T_BURNING:
				if b.pierce:
					continue
				break
			flames[k] = G.FLAME_TIME
			var ob = _bomb_at(c)
			if ob != null:
				ob.remote = false
				ob.fuse = minf(ob.fuse, G.CHAIN_DELAY)
				break
			if items[k] != G.I_NONE:
				items[k] = G.I_NONE
				if not b.pierce:
					break
	_danger_frame = -1
	game_event.emit("boom", [origin.x, origin.y])


func _update_fire(dt: float) -> void:
	for k in flames.size():
		if flames[k] > 0.0:
			flames[k] = maxf(0.0, flames[k] - dt)
		if burn[k] > 0.0:
			burn[k] -= dt
			if burn[k] <= 0.0:
				burn[k] = 0.0
				if tiles[k] == G.T_BURNING:
					tiles[k] = G.T_EMPTY


# ====================================================================== dano, itens, doenças
func _check_hits() -> void:
	for p in players.values():
		if not p.alive:
			continue
		var k: int = G.idx(G.cell_of(p.pos))
		if flames[k] > 0.0 or tiles[k] == G.T_BURNING:
			_hurt(p)


func _hurt(p: Dictionary) -> void:
	if p.invuln_t > 0.0 or p.vest_t > 0.0:
		return
	if p.hearts > 0:
		p.hearts -= 1
		p.invuln_t = G.HEART_INVULN
		game_event.emit("heart", [p.id])
		return
	_kill(p)


func _kill(p: Dictionary) -> void:
	if not p.alive:
		return
	p.alive = false
	p.dir = Vector2i.ZERO
	for b in bombs:
		if b.owner == p.id:
			b.remote = false
	_scatter(p.collected)
	p.collected = []
	game_event.emit("death", [p.id])


## Ao morrer, os itens coletados se espalham pela arena.
func _scatter(list: Array) -> void:
	if list.is_empty():
		return
	var free: Array = []
	for y in G.H:
		for x in G.W:
			var c := Vector2i(x, y)
			var k: int = G.idx(c)
			if tiles[k] == G.T_EMPTY and items[k] == G.I_NONE and flames[k] <= 0.0 \
					and _bomb_at(c) == null and not _player_on(c):
				free.append(c)
	free.shuffle()
	for i in mini(list.size(), free.size()):
		items[G.idx(free[i])] = list[i]


func _check_pickups() -> void:
	for p in players.values():
		if not p.alive:
			continue
		var k: int = G.idx(G.cell_of(p.pos))
		var it: int = items[k]
		if it != G.I_NONE and tiles[k] == G.T_EMPTY:
			items[k] = G.I_NONE
			_apply_item(p, it)
			game_event.emit("item", [p.id, it])


func _apply_item(p: Dictionary, it: int) -> void:
	match it:
		G.I_BOMB_UP:
			p.bombs_max = mini(p.bombs_max + 1, G.MAX_BOMBS)
		G.I_FIRE_UP:
			p.fire = mini(p.fire + 1, G.MAX_FIRE)
		G.I_FULL_FIRE:
			p.fire = G.MAX_FIRE
		G.I_SPEED_UP:
			p.speed_lvl = mini(p.speed_lvl + 1, G.MAX_SPEED_LVL)
		G.I_KICK:
			p.kick = true
		G.I_PUNCH:
			p.punch = true
		G.I_REMOTE:
			p.remote = true
			p.pierce = false
		G.I_PIERCE:
			p.pierce = true
			p.remote = false
		G.I_LINE:
			p.line = true
		G.I_POWER:
			p.power = true
		G.I_WALL_PASS:
			p.wall_pass = true
		G.I_BOMB_PASS:
			p.bomb_pass = true
		G.I_VEST:
			p.vest_t = G.VEST_TIME
		G.I_HEART:
			p.hearts = 1
		G.I_SKULL:
			p.disease = rng.randi_range(1, G.DISEASE_COUNT - 1)
			p.disease_t = G.DISEASE_TIME
	if it != G.I_VEST and it != G.I_HEART:
		p.collected.append(it)


## Caveira é contagiosa: encostar em alguém doente passa a doença.
func _check_contagion() -> void:
	var ps: Array = players.values()
	for a in ps:
		if not a.alive or a.disease == G.D_NONE:
			continue
		for b in ps:
			if b.id != a.id and b.alive and b.disease == G.D_NONE and _overlaps(a.pos, b.pos):
				b.disease = a.disease
				b.disease_t = G.DISEASE_TIME


# ====================================================================== morte súbita / fim
func _update_sudden(dt: float) -> void:
	if not sudden_active:
		if time_left > G.SUDDEN_DEATH_AT:
			return
		sudden_active = true
		game_event.emit("sudden", [])
	sudden_timer -= dt
	while sudden_timer <= 0.0 and sudden_index < sudden_cells.size():
		var c: Vector2i = sudden_cells[sudden_index]
		sudden_index += 1
		if tiles[G.idx(c)] == G.T_HARD:
			continue
		_drop_block(c)
		sudden_timer += G.SUDDEN_STEP


func _drop_block(c: Vector2i) -> void:
	var k: int = G.idx(c)
	tiles[k] = G.T_FALLEN
	items[k] = G.I_NONE
	flames[k] = 0.0
	burn[k] = 0.0
	for i in range(bombs.size() - 1, -1, -1):
		if not bombs[i].fly and bombs[i].cell == c:
			bombs[i].dead = true
			bombs.remove_at(i)
	for p in players.values():
		if p.alive and G.cell_of(p.pos) == c:
			_kill(p)
	_danger_frame = -1


func _check_end(dt: float) -> void:
	var alive: Array = []
	for p in players.values():
		if p.alive:
			alive.append(p.id)
	var n := players.size()
	if not ending:
		if (n >= 2 and alive.size() <= 1) or (n < 2 and alive.is_empty()) or time_left <= 0.0:
			ending = true
			end_timer = G.ROUND_END_DELAY
		return
	end_timer -= dt
	if end_timer > 0.0:
		return
	running = false
	var winner := 0
	if alive.size() == 1 and n >= 2:
		winner = alive[0]
	round_over.emit(winner)


# ====================================================================== snapshot
func snapshot() -> Array:
	var n := G.W * G.H
	var vis_items := PackedByteArray()
	vis_items.resize(n)
	var fl := PackedByteArray()
	fl.resize(n)
	for k in n:
		vis_items[k] = items[k] if tiles[k] == G.T_EMPTY else 0
		fl[k] = 1 if flames[k] > 0.0 else 0
	var pl: Array = []
	for p in players.values():
		pl.append([p.id, p.pos.x, p.pos.y, p.alive, p.facing.x, p.facing.y, _bits(p), p.disease,
			p.bombs_max, p.fire, p.speed_lvl, p.disease_t, p.vest_t])
	var bl: Array = []
	for b in bombs:
		var z := 0.0
		if b.fly:
			z = sin(PI * clampf(b.fly_t / b.fly_dur, 0.0, 1.0)) * (0.9 if b.bounces == 0 else 0.4)
		var kind := 0
		if b.remote:
			kind |= 1
		if b.pierce:
			kind |= 2
		if b.power:
			kind |= 4
		var frac := 1.0 if b.remote else clampf(b.fuse / G.FUSE, 0.0, 1.0)
		bl.append([b.id, b.pos.x, b.pos.y, z, kind, frac])
	return [time_left, tiles, fl, vis_items, pl, bl, sudden_active]


func _bits(p: Dictionary) -> int:
	var b := 0
	if p.kick: b |= 1
	if p.punch: b |= 2
	if p.remote: b |= 4
	if p.pierce: b |= 8
	if p.line: b |= 16
	if p.power: b |= 32
	if p.wall_pass: b |= 64
	if p.bomb_pass: b |= 128
	if p.vest_t > 0.0: b |= 256
	if p.invuln_t > 0.0: b |= 512
	if p.hearts > 0: b |= 1024
	return b


# ====================================================================== bots (CPU)
func _blast_cells(origin: Vector2i, rng_fire: int, pierce: bool) -> Array:
	var res: Array = [origin]
	for d in G.DIRS:
		for i in range(1, rng_fire + 1):
			var c: Vector2i = origin + d * i
			if not G.in_bounds(c):
				break
			var t: int = tiles[G.idx(c)]
			if t == G.T_HARD or t == G.T_FALLEN:
				break
			if t == G.T_SOFT or t == G.T_BURNING:
				if pierce:
					continue
				break
			res.append(c)
			if _bomb_at(c) != null:
				break
	return res


## Para cada tile: em quantos segundos ele vai pegar fogo (INF_T = seguro).
func _danger_map() -> PackedFloat32Array:
	if _danger_frame == _tick_count:
		return _danger
	_danger_frame = _tick_count
	_danger.resize(G.W * G.H)
	_danger.fill(INF_T)
	var times := {}
	for b in bombs:
		if not b.fly:
			times[b.id] = 0.6 if b.remote else float(b.fuse)
	for _iter in 2:
		for b in bombs:
			if b.fly:
				continue
			for c in _blast_cells(b.cell, b.range, b.pierce):
				var ob = _bomb_at(c)
				if ob != null and times.has(ob.id) and times[ob.id] > times[b.id]:
					times[ob.id] = times[b.id]
	for b in bombs:
		if b.fly:
			continue
		for c in _blast_cells(b.cell, b.range, b.pierce):
			var k: int = G.idx(c)
			_danger[k] = minf(_danger[k], times[b.id])
	for k in _danger.size():
		if flames[k] > 0.0 or tiles[k] == G.T_BURNING:
			_danger[k] = 0.0
	if sudden_active:
		for i in range(sudden_index, mini(sudden_index + 4, sudden_cells.size())):
			_danger[G.idx(sudden_cells[i])] = 0.0
	return _danger


func _bot_think(p: Dictionary, dt: float) -> void:
	p.ai_timer -= dt
	var cell: Vector2i = G.cell_of(p.pos)
	var danger := _danger_map()
	var in_danger := danger[G.idx(cell)] < INF_T
	if p.ai_timer <= 0.0 or (in_danger and p.ai_path.is_empty()):
		p.ai_timer = 0.2 + rng.randf() * 0.2
		_bot_plan(p, cell, danger)
	_bot_follow(p, cell)
	if p.remote and not in_danger and _count_bombs(p.id) > 0 and rng.randf() < 0.03:
		_do_action(p)


func _bot_plan(p: Dictionary, cell: Vector2i, danger: PackedFloat32Array) -> void:
	if danger[G.idx(cell)] < INF_T:
		p.ai_path = _bfs(p, cell, danger, func(c): return danger[G.idx(c)] >= INF_T, true)
		return
	if _bot_wants_bomb(p, cell, danger):
		_try_place_bomb(p, false)
		var d2 := _danger_map()
		p.ai_path = _bfs(p, cell, d2, func(c): return d2[G.idx(c)] >= INF_T, true)
		return
	var path := _bfs(p, cell, danger, func(c): return items[G.idx(c)] != G.I_NONE and tiles[G.idx(c)] == G.T_EMPTY, false)
	if path.is_empty() or path.size() > 8:
		var alt := _bfs(p, cell, danger, func(c): return _good_bomb_spot(p, c), false)
		if not alt.is_empty():
			path = alt
	if path.is_empty() and rng.randf() < 0.6:
		var opts: Array = []
		for d in G.DIRS:
			var n: Vector2i = cell + d
			if _passable(p, n) and danger[G.idx(n)] >= INF_T:
				opts.append(n)
		if not opts.is_empty():
			path = [opts[rng.randi() % opts.size()]]
	p.ai_path = path


func _good_bomb_spot(p: Dictionary, c: Vector2i) -> bool:
	for d in G.DIRS:
		for i in range(1, int(p.fire) + 1):
			var n: Vector2i = c + d * i
			if not G.in_bounds(n):
				break
			var t: int = tiles[G.idx(n)]
			if t == G.T_HARD or t == G.T_FALLEN or t == G.T_BURNING:
				break
			if t == G.T_SOFT:
				if i == 1:
					return true
				break
			for q in players.values():
				if q.alive and q.id != p.id and G.cell_of(q.pos) == n:
					return true
	return false


func _bot_wants_bomb(p: Dictionary, cell: Vector2i, danger: PackedFloat32Array) -> bool:
	if p.disease == G.D_CONSTIPATION or _count_bombs(p.id) >= p.bombs_max:
		return false
	if _bomb_at(cell) != null or tiles[G.idx(cell)] != G.T_EMPTY:
		return false
	if not _good_bomb_spot(p, cell):
		return false
	var sim := danger.duplicate()
	for c in _blast_cells(cell, p.fire, p.pierce):
		var k: int = G.idx(c)
		sim[k] = minf(sim[k], G.FUSE)
	var esc := _bfs(p, cell, sim, func(c): return sim[G.idx(c)] >= INF_T, true)
	return not esc.is_empty() and esc.size() <= 6


func _bfs(p: Dictionary, start: Vector2i, danger: PackedFloat32Array, goal: Callable, fleeing: bool) -> Array:
	var prev := {start: start}
	var q: Array = [start]
	var head := 0
	while head < q.size() and head < 200:
		var c: Vector2i = q[head]
		head += 1
		if c != start and goal.call(c):
			var path: Array = []
			var cur: Vector2i = c
			while cur != start:
				path.push_front(cur)
				cur = prev[cur]
			return path
		for d in G.DIRS:
			var n: Vector2i = c + d
			if prev.has(n) or not _passable(p, n):
				continue
			var dz: float = danger[G.idx(n)]
			if fleeing:
				if dz < 0.35:
					continue
			elif dz < INF_T:
				continue
			prev[n] = c
			q.append(n)
	return []


func _bot_follow(p: Dictionary, cell: Vector2i) -> void:
	var path: Array = p.ai_path
	while not path.is_empty() and path[0] == cell:
		path.pop_front()
	if path.is_empty():
		p.dir = Vector2i.ZERO
		return
	var nxt: Vector2i = path[0]
	var d: Vector2i = nxt - cell
	if absi(d.x) + absi(d.y) != 1:
		p.ai_path = []
		p.dir = Vector2i.ZERO
		return
	p.dir = -d if p.disease == G.D_REVERSE else d
