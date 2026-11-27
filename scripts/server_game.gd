extends Node
## Simulação autoritativa de uma rodada. Roda SOMENTE no servidor.
## Os clientes apenas enviam comandos (direção / bomba / ação) e recebem snapshots.

const G = preload("res://scripts/g.gd")
const INF_T := 999.0
const REMOTE_DANGER := 1.5      # bomba de controle remoto: "pode explodir logo" (0,6 travava o bot)
const SUDDEN_LOOKAHEAD := 12.0   # bots enxergam a parede da morte súbita 12 s antes

signal round_over(winner_id: int)        # 0 = empate
signal game_event(kind: String, data: Array)

var tiles := PackedByteArray()
var items := PackedByteArray()
var blocked_items := 0      # bits (1 << item) dos itens bloqueados pelo líder da sala
var flames := PackedFloat32Array()
var flame_owner := PackedInt32Array()   # dono da bomba que fez o fogo (estatística de abates)
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
# tamanho do mapa desta rodada (cada sala tem o seu; muda com a quantidade de jogadores)
var mw := G.W
var mh := G.H
var sudden_step := G.SUDDEN_STEP   # mapa maior: blocos caem mais rápido para fechar no mesmo tempo


# ====================================================================== setup
func start_round(roster: Array, round_time: float) -> void:
	rng.randomize()
	var size := G.map_size(roster.size())
	mw = size.x
	mh = size.y
	var n := mw * mh
	sudden_step = G.SUDDEN_STEP * float((G.W - 2) * (G.H - 2)) / float((mw - 2) * (mh - 2))
	tiles.resize(n)
	tiles.fill(G.T_EMPTY)
	items.resize(n)
	items.fill(G.I_NONE)
	flames.resize(n)
	flames.fill(0.0)
	flame_owner.resize(n)
	flame_owner.fill(0)
	burn.resize(n)
	burn.fill(0.0)
	bombs.clear()
	players.clear()
	time_left = round_time
	running = true
	ending = false
	end_timer = 0.0
	sudden_active = false
	sudden_cells = G.spiral_cells(mw, mh)
	sudden_index = 0
	sudden_timer = 0.0
	_danger_frame = -1
	var spawns: Array = G.spawns(mw, mh).slice(0, roster.size())
	_build_map(spawns)
	for i in roster.size():
		var r: Dictionary = roster[i]
		players[r.id] = _new_player(r, spawns[i])


func _idx(c: Vector2i) -> int:
	return c.y * mw + c.x


func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < mw and c.y < mh


func _is_pillar(c: Vector2i) -> bool:
	return G.is_pillar(c, mw, mh)


func _new_player(r: Dictionary, spawn: Vector2i) -> Dictionary:
	return {
		"id": r.id, "name": r.name, "bot": r.bot,
		"pos": G.center_of(spawn), "alive": true,
		"facing": Vector2i(0, 1), "dir": Vector2i.ZERO, "dir2": Vector2i.ZERO,
		"bombs_max": G.START_BOMBS, "fire": G.START_FIRE, "speed_lvl": 0,
		"kick": false, "punch": false, "remote": false, "pierce": false, "line": false,
		"power": false, "wall_pass": false, "bomb_pass": false, "wall_t": 0.0, "bomb_pass_t": 0.0,
		"vest_t": 0.0, "hearts": 0, "invuln_t": 0.0,
		"disease": G.D_NONE, "disease_t": 0.0,
		"collected": [], "ai_path": [], "ai_timer": 0.0, "moving": false,
		"kills": 0, "suicide": false, "picked": 0,   # estatísticas da rodada (tela de resultado)
		"diff": int(r.get("difficulty", 1)), "ai_soft": 0.0, "ai_seen": 0.0, "ai_fleeing": false,
	}


func _build_map(spawns: Array) -> void:
	var safe := {}
	for s in spawns:
		safe[s] = true
		for d in G.DIRS:
			safe[s + d] = true
	var total := 0
	for i in range(1, G.ITEM_COUNT):
		if not _is_blocked(i):
			total += G.ITEM_WEIGHTS[i]
	for y in mh:
		for x in mw:
			var c := Vector2i(x, y)
			var k: int = _idx(c)
			if _is_pillar(c):
				tiles[k] = G.T_HARD
			elif not safe.has(c) and rng.randf() < G.SOFT_DENSITY:
				tiles[k] = G.T_SOFT
				if total > 0 and rng.randf() < G.ITEM_CHANCE:
					items[k] = _random_item(total)


func _random_item(total: int) -> int:
	var r := rng.randi_range(1, total)
	for i in range(1, G.ITEM_COUNT):
		if _is_blocked(i):
			continue
		r -= G.ITEM_WEIGHTS[i]
		if r <= 0:
			return i
	return G.I_NONE


func _is_blocked(item: int) -> bool:
	return (blocked_items & (1 << item)) != 0


# ====================================================================== comandos dos jogadores
## d = direção apertada por último; d2 = outra direção ainda segurada (eixo diferente),
## usada quando d está bloqueada (segurar → e apertar ↑ antes da esquina: anda até ela e vira).
func set_input(id: int, d: Vector2i, d2 := Vector2i.ZERO) -> void:
	if not players.has(id):
		return
	if d.x != 0 and d.y != 0:
		d.y = 0
	if d2.x != 0 and d2.y != 0:
		d2.y = 0
	if d2 == d or d2 == -d:
		d2 = Vector2i.ZERO
	players[id].dir = d
	players[id].dir2 = d2


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
	if p.wall_pass:
		p.wall_t = maxf(0.0, p.wall_t - dt)
		# acabou o tempo: só desliga fora dos blocos, para não prender o jogador na parede
		if p.wall_t <= 0.0 and not _inside_block(p):
			p.wall_pass = false
	if p.bomb_pass:
		p.bomb_pass_t = maxf(0.0, p.bomb_pass_t - dt)
		if p.bomb_pass_t <= 0.0:
			p.bomb_pass = false
			# se estiver em cima de bomba, consegue sair dela (como quando solta a própria bomba)
			for b in bombs:
				if not b.fly and _overlaps(p.pos, b.pos) and not b.pass_ids.has(p.id):
					b.pass_ids.append(p.id)
	if p.disease != G.D_NONE:
		p.disease_t -= dt
		if p.disease_t <= 0.0:
			p.disease = G.D_NONE
		elif p.disease == G.D_DIARRHEA:
			_try_place_bomb(p, false)


## Jogador encostando em algum bloco destrutível (pode estar entre duas células).
func _inside_block(p: Dictionary) -> bool:
	var c: Vector2i = G.cell_of(p.pos)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n: Vector2i = c + Vector2i(dx, dy)
			if not _in_bounds(n):
				continue
			var t: int = tiles[_idx(n)]
			if (t == G.T_SOFT or t == G.T_BURNING) and _overlaps(p.pos, G.center_of(n)):
				return true
	return false


# ====================================================================== movimento
func _speed(p: Dictionary) -> float:
	if p.disease == G.D_SLOW:
		return G.SLOW_SPEED
	if p.disease == G.D_FAST:
		return G.FAST_SPEED
	return G.BASE_SPEED + float(p.speed_lvl) * G.SPEED_STEP


func _passable(p: Dictionary, c: Vector2i) -> bool:
	if not _in_bounds(c):
		return false
	var t: int = tiles[_idx(c)]
	if t == G.T_HARD or t == G.T_FALLEN:
		return false
	if (t == G.T_SOFT or t == G.T_BURNING) and not p.wall_pass:
		return false
	var b = _bomb_at(c)
	if b != null and not p.bomb_pass and not b.pass_ids.has(p.id):
		return false
	return true


## Movimento em grade com "assistência de curva" (corner sliding): apertando contra a
## quina de um pilar, o jogador escorrega para o corredor mais próximo. Se a direção
## principal não anda nada, tenta a segunda direção segurada.
func _move_player(p: Dictionary, dt: float) -> void:
	p.moving = false
	var d: Vector2i = p.dir
	var d2: Vector2i = p.get("dir2", Vector2i.ZERO)
	if p.disease == G.D_REVERSE:
		d = -d
		d2 = -d2
	if d == Vector2i.ZERO:
		return
	if not _step(p, d, dt) and d2 != Vector2i.ZERO:
		_step(p, d2, dt)


## Um passo na direção d. Retorna se o jogador saiu do lugar.
func _step(p: Dictionary, d: Vector2i, dt: float) -> bool:
	var start_pos: Vector2 = p.pos
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
		var side := Vector2i(int(perp.x * signf(off)), int(perp.y * signf(off)))
		var can_slide := absf(off) > G.CORNER_ASSIST and _passable(p, cell + side) \
				and _passable(p, cell + side + d)
		if can_slide:
			# escorrega para o lado da abertura (mesmo antes de chegar no centro da casa)
			pos += perp * signf(off) * step
			if along < 0.0:
				pos += axis * minf(step * 0.5, -along)
		elif along < 0.0:
			pos += axis * minf(step, -along)
	# nunca passar do centro de um tile cuja frente está bloqueada
	var ncell: Vector2i = G.cell_of(pos)
	var ncenter: Vector2 = G.center_of(ncell)
	var nalong := (pos - ncenter).dot(axis)
	if nalong > 0.0 and not _passable(p, ncell + d):
		pos -= axis * nalong
	p.pos = pos
	p.moving = pos.distance_squared_to(start_pos) > 0.000001
	return p.moving


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
		if allow_line and p.line and _count_bombs(p.id) < p.bombs_max:
			_place_line(p, cell)
			game_event.emit("placed", [p.id])
		return
	if tiles[_idx(cell)] != G.T_EMPTY:
		return
	if _count_bombs(p.id) >= p.bombs_max:
		return
	_spawn_bomb(p, cell)
	game_event.emit("placed", [p.id])


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
		if not _in_bounds(c) or tiles[_idx(c)] != G.T_EMPTY or _bomb_at(c) != null or _player_on(c):
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
			game_event.emit("punch", [p.id])
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
	if not _in_bounds(c):
		return true
	if tiles[_idx(c)] != G.T_EMPTY:
		return true
	if _bomb_at(c) != null:
		return true
	return _player_on(c)


## Arremesso dá a volta na arena (sai de um lado, entra do outro).
func _wrap(v: Vector2) -> Vector2:
	return Vector2(1.0 + fposmod(v.x - 1.0, float(mw - 2)), 1.0 + fposmod(v.y - 1.0, float(mh - 2)))


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
		if flames[_idx(b.cell)] > 0.0:
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
	var ok: int = _idx(origin)
	flames[ok] = G.FLAME_TIME
	flame_owner[ok] = b.owner
	items[ok] = G.I_NONE
	for d in G.DIRS:
		for i in range(1, int(b.range) + 1):
			var c: Vector2i = origin + d * i
			if not _in_bounds(c):
				break
			var k: int = _idx(c)
			var t: int = tiles[k]
			if t == G.T_HARD or t == G.T_FALLEN:
				break
			if t == G.T_SOFT:
				tiles[k] = G.T_BURNING
				burn[k] = G.FLAME_TIME
				flame_owner[k] = b.owner
				if b.pierce:
					continue
				break
			if t == G.T_BURNING:
				if b.pierce:
					continue
				break
			flames[k] = G.FLAME_TIME
			flame_owner[k] = b.owner
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
		var k: int = _idx(G.cell_of(p.pos))
		if flames[k] > 0.0 or tiles[k] == G.T_BURNING:
			_hurt(p, flame_owner[k])


func _hurt(p: Dictionary, killer := 0) -> void:
	if p.invuln_t > 0.0 or p.vest_t > 0.0:
		return
	if p.hearts > 0:
		p.hearts -= 1
		p.invuln_t = G.HEART_INVULN
		game_event.emit("heart", [p.id])
		return
	_kill(p, killer)


## killer: id do dono da bomba (0 = morte súbita / sem dono).
func _kill(p: Dictionary, killer := 0) -> void:
	if not p.alive:
		return
	p.alive = false
	if killer == p.id:
		p.suicide = true
	elif killer != 0 and players.has(killer):
		players[killer].kills += 1
	p.dir = Vector2i.ZERO
	for b in bombs:
		if b.owner == p.id:
			b.remote = false
	_scatter(p.collected)
	p.collected = []
	game_event.emit("death", [p.id, killer])


## Ao morrer, os itens coletados se espalham pela arena.
func _scatter(list: Array) -> void:
	if list.is_empty():
		return
	var free: Array = []
	var reach := _reachable_cells()
	var doomed := _doomed_cells()
	for y in mh:
		for x in mw:
			var c := Vector2i(x, y)
			var k: int = _idx(c)
			# só onde alguém ainda consegue chegar e a parede da morte súbita não vai cair logo
			if tiles[k] == G.T_EMPTY and items[k] == G.I_NONE and flames[k] <= 0.0 \
					and _bomb_at(c) == null and not _player_on(c) \
					and (reach.is_empty() or reach.has(c)) and not doomed.has(c):
				free.append(c)
	free.shuffle()
	for i in mini(list.size(), free.size()):
		items[_idx(free[i])] = list[i]


func _check_pickups() -> void:
	for p in players.values():
		if not p.alive:
			continue
		var k: int = _idx(G.cell_of(p.pos))
		var it: int = items[k]
		if it != G.I_NONE and tiles[k] == G.T_EMPTY:
			items[k] = G.I_NONE
			p.picked += 1
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
			p.wall_t = G.WALL_PASS_TIME
		G.I_BOMB_PASS:
			p.bomb_pass = true
			p.bomb_pass_t = G.BOMB_PASS_TIME
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
		if tiles[_idx(c)] == G.T_HARD:
			continue
		_drop_block(c)
		sudden_timer += sudden_step


func _drop_block(c: Vector2i) -> void:
	var k: int = _idx(c)
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
	_prune_unreachable_items()
	_danger_frame = -1


## Casas que algum jogador vivo ainda alcança (atravessando mesas, que dá para explodir).
func _reachable_cells() -> Dictionary:
	var seen := {}
	var q: Array = []
	for p in players.values():
		if p.alive:
			var c: Vector2i = G.cell_of(p.pos)
			if not seen.has(c):
				seen[c] = true
				q.append(c)
	while not q.is_empty():
		var c: Vector2i = q.pop_back()
		for d in G.DIRS:
			var n: Vector2i = c + d
			if seen.has(n) or not _in_bounds(n):
				continue
			var t: int = tiles[_idx(n)]
			if t == G.T_HARD or t == G.T_FALLEN:
				continue
			seen[n] = true
			q.append(n)
	return seen


## Próximas casas da espiral da morte súbita (~10 s): item não deve aparecer lá.
func _doomed_cells() -> Dictionary:
	var res := {}
	if not sudden_active:
		return res
	for i in range(sudden_index, mini(sudden_index + int(10.0 / sudden_step), sudden_cells.size())):
		res[sudden_cells[i]] = true
	return res


## A parede da morte súbita fechou um bolsão: itens lá dentro somem (ninguém pega mais).
func _prune_unreachable_items() -> void:
	var reach := _reachable_cells()
	if reach.is_empty():
		return
	for k in items.size():
		if items[k] != G.I_NONE and not reach.has(Vector2i(k % mw, k / mw)):
			items[k] = G.I_NONE


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
	var n := mw * mh
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
			p.bombs_max, p.fire, p.speed_lvl, p.disease_t, p.vest_t, p.wall_t, p.bomb_pass_t, _count_bombs(p.id)])
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
	return [time_left, tiles, fl, vis_items, pl, bl, sudden_active, mw, mh]


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
	if p.moving: b |= 2048
	return b


# ====================================================================== bots (CPU)
func _blast_cells(origin: Vector2i, rng_fire: int, pierce: bool) -> Array:
	var res: Array = [origin]
	for d in G.DIRS:
		for i in range(1, rng_fire + 1):
			var c: Vector2i = origin + d * i
			if not _in_bounds(c):
				break
			var t: int = tiles[_idx(c)]
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
	_danger.resize(mw * mh)
	_danger.fill(INF_T)
	var times := {}
	for b in bombs:
		if not b.fly:
			times[b.id] = REMOTE_DANGER if b.remote else float(b.fuse)
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
			var k: int = _idx(c)
			_danger[k] = minf(_danger[k], times[b.id])
	for k in _danger.size():
		if flames[k] > 0.0 or tiles[k] == G.T_BURNING:
			_danger[k] = 0.0
	# morte súbita: cada casa da espiral recebe o tempo até a parede cair nela
	# (enxerga SUDDEN_LOOKAHEAD s à frente, inclusive antes de começar), para os bots
	# fugirem para o centro com antecedência em vez de morrer encostados na parede
	var fall_t := sudden_timer if sudden_active else time_left - G.SUDDEN_DEATH_AT
	if fall_t < SUDDEN_LOOKAHEAD:
		for i in range(sudden_index, sudden_cells.size()):
			var c: Vector2i = sudden_cells[i]
			if tiles[_idx(c)] == G.T_HARD:
				continue
			if fall_t >= SUDDEN_LOOKAHEAD:
				break
			var k := _idx(c)
			_danger[k] = minf(_danger[k], maxf(fall_t, 0.0))
			fall_t += sudden_step
	return _danger


# ====================================================================== IA dos bots
## Ajustes por dificuldade (0 Fácil, 1 Normal, 2 Difícil):
##   think   intervalo entre decisões (s)      react  atraso para perceber perigo (s)
##   soft_cd intervalo mínimo entre bombas em mesas (não limpa o mapa no começo)
##   esc_max tamanho máximo da rota de fuga    margin folga de tempo na fuga (s)
##   hunt    chance de ir atrás de jogadores   reach  até onde procura alvo (casas)
const AI := [
	{"think": [0.45, 0.7], "react": 0.35, "soft_cd": 9.0, "esc_max": 4, "margin": 0.35, "hunt": 0.35, "reach": 6},
	{"think": [0.25, 0.45], "react": 0.12, "soft_cd": 6.0, "esc_max": 6, "margin": 0.4, "hunt": 0.55, "reach": 10},
	{"think": [0.12, 0.22], "react": 0.0, "soft_cd": 4.5, "esc_max": 7, "margin": 0.35, "hunt": 0.9, "reach": 16},
]


func _ai(p: Dictionary) -> Dictionary:
	return AI[clampi(int(p.get("diff", 1)), 0, AI.size() - 1)]


func _bot_think(p: Dictionary, dt: float) -> void:
	var cfg := _ai(p)
	p.ai_timer -= dt
	p.ai_soft = float(p.get("ai_soft", 0.0)) - dt
	var cell: Vector2i = G.cell_of(p.pos)
	var danger := _danger_map()
	var in_danger := danger[_idx(cell)] < INF_T
	if in_danger:
		# percebe o perigo com um atraso (Fácil demora mais)
		p.ai_seen = float(p.get("ai_seen", 0.0)) + dt
	else:
		p.ai_seen = 0.0
	var must_flee: bool = in_danger and p.ai_seen >= float(cfg.react) and not p.get("ai_fleeing", false)
	# fugindo, mas apareceu bomba nova no caminho: recalcula na hora
	if p.ai_fleeing and not (p.ai_path as Array).is_empty() and not _path_safe(p, cell, danger, float(cfg.margin)):
		must_flee = true
	if p.ai_timer <= 0.0 or must_flee or (in_danger and p.ai_path.is_empty() and p.ai_seen >= float(cfg.react)):
		p.ai_timer = rng.randf_range(cfg.think[0], cfg.think[1])
		_bot_plan(p, cell, danger)
	_bot_follow(p, cell)
	if p.remote and not in_danger and _count_bombs(p.id) > 0 and _remote_hits_enemy(p):
		_do_action(p)


func _bot_plan(p: Dictionary, cell: Vector2i, danger: PackedFloat32Array) -> void:
	var cfg := _ai(p)
	p.ai_fleeing = false
	if danger[_idx(cell)] < INF_T:
		p.ai_path = _flee_path(p, cell, danger, float(cfg.margin))
		p.ai_fleeing = true
		return
	var reach := _reach(p, cell, danger)
	# encurralado entre mesas (ou na morte súbita): abre caminho sem esperar o intervalo
	var boxed: bool = reach.order.size() < 4 or sudden_active
	# bomba aqui mesmo? (jogador na linha de fogo, ou mesa com o intervalo cumprido)
	var hit := _bomb_targets(p, cell)
	var want: bool = hit.player or (hit.soft and (p.ai_soft <= 0.0 or boxed))
	if want and _bot_can_escape(p, cell, danger):
		_try_place_bomb(p, false)
		if hit.soft and not hit.player:
			p.ai_soft = float(cfg.soft_cd) * rng.randf_range(0.8, 1.2)
		var d2 := _danger_map()
		p.ai_path = _flee_path(p, cell, d2, float(cfg.margin))
		p.ai_fleeing = true
		return
	var path: Array = []
	# 1) item perto
	path = _pick(reach, func(c, depth): return depth <= 8 and items[_idx(c)] != G.I_NONE \
		and items[_idx(c)] != G.I_SKULL and tiles[_idx(c)] == G.T_EMPTY)
	# fim de jogo (morte súbita ou só mais um adversário): parte para cima
	var hunt := float(cfg.hunt)
	if sudden_active or _alive_count() <= 2:
		hunt = 1.0
	# dividindo a casa com outro jogador sem poder soltar bomba: primeiro se afasta
	if _crowded(p, cell):
		hunt = 0.0
	# 2) caçar: casa de onde a bomba pega alguém
	if path.is_empty() and rng.randf() < hunt:
		path = _pick(reach, func(c, depth): return depth <= int(cfg.reach) and _bomb_targets(p, c).player)
	# 3) mesa (respeitando o intervalo)
	if path.is_empty() and (p.ai_soft <= 0.0 or boxed):
		path = _pick(reach, func(c, depth): return _bomb_targets(p, c).soft and not _taken(p, c))
	# 4) chegar perto de alguém (meio de jogo não fica parado)
	if path.is_empty() and rng.randf() < hunt:
		path = _pick(reach, func(c, depth): return depth >= 1 and _near_enemy(p, c, 2))
	# 5) passear por um lugar livre, longe dos outros bots (não empilham)
	if path.is_empty() or _crowded(p, cell):
		var opts: Array = []
		for c in reach.order:
			var dep: int = reach.depth[c]
			if dep >= 3 and dep <= 9 and not _taken(p, c):
				opts.append(c)
		if not opts.is_empty():
			path = _path_to(reach, opts[rng.randi() % opts.size()])
	p.ai_path = path


## A rota atual ainda passa a tempo por cada casa (ninguém soltou bomba nova no caminho)?
func _path_safe(p: Dictionary, cell: Vector2i, danger: PackedFloat32Array, margin: float) -> bool:
	var spd := maxf(_speed(p), 0.5)
	var k := 0
	for c in p.ai_path:
		if c == cell:
			continue
		k += 1
		if not _passable(p, c) or danger[_idx(c)] < (k + 0.5) / spd + margin:
			return false
	return true


## O que uma bomba em c pegaria: jogador inimigo na linha, mesa colada.
func _bomb_targets(p: Dictionary, c: Vector2i) -> Dictionary:
	var res := {"player": false, "soft": false}
	for d in G.DIRS:
		for i in range(1, int(p.fire) + 1):
			var n: Vector2i = c + d * i
			if not _in_bounds(n):
				break
			var t: int = tiles[_idx(n)]
			if t == G.T_HARD or t == G.T_FALLEN or t == G.T_BURNING:
				break
			if t == G.T_SOFT:
				if i == 1:
					res.soft = true
				break
			for q in players.values():
				if q.alive and q.id != p.id and G.cell_of(q.pos) == n:
					res.player = true
	# alguém na mesma casa também conta (senão dois bots empilhados nunca reagem)
	for q in players.values():
		if q.alive and q.id != p.id and G.cell_of(q.pos) == c:
			res.player = true
	return res


func _bot_can_escape(p: Dictionary, cell: Vector2i, danger: PackedFloat32Array) -> bool:
	if p.disease == G.D_CONSTIPATION or _count_bombs(p.id) >= p.bombs_max:
		return false
	if _bomb_at(cell) != null or tiles[_idx(cell)] != G.T_EMPTY:
		return false
	var fuse := G.SHORT_FUSE if p.disease == G.D_SHORT_FUSE else G.FUSE
	var sim := danger.duplicate()
	for c in _blast_cells(cell, p.fire, p.pierce):
		var k: int = _idx(c)
		sim[k] = minf(sim[k], fuse)
	# basta chegar numa casa que a própria bomba não pega e que não vai pegar fogo tão cedo
	var esc := _flee_path(p, cell, sim, float(_ai(p).margin), false, fuse + G.FLAME_TIME + 1.0)
	return not esc.is_empty() and esc.size() <= int(_ai(p).esc_max)


## Rota de fuga que considera o tempo: só passa por uma casa se chega e sai dela antes
## de explodir (com folga). Prefere casa sem perigo; se não houver (fim da morte súbita),
## vai para a que demora mais a ficar perigosa.
func _flee_path(p: Dictionary, start: Vector2i, danger: PackedFloat32Array, margin: float,
		allow_best := true, safe_after := INF_T) -> Array:
	var spd := maxf(_speed(p), 0.5)
	var prev := {start: start}
	var depth := {start: 0}
	var q: Array = [start]
	var head := 0
	var best := start
	var best_v := danger[_idx(start)]
	var shared := start    # casa segura que outro bot já escolheu (só se não houver outra)
	while head < q.size() and head < 220:
		var c: Vector2i = q[head]
		head += 1
		var dz: float = danger[_idx(c)]
		if c != start and dz >= safe_after:
			if not _taken(p, c):
				return _rebuild(prev, start, c)
			if shared == start:
				shared = c
		if dz > best_v:
			best_v = dz
			best = c
		for d in G.DIRS:
			var n: Vector2i = c + d
			if prev.has(n) or not _passable(p, n):
				continue
			var k: int = depth[c] + 1
			# fica na casa n de ~(k-0.5)/v até (k+0.5)/v
			if danger[_idx(n)] < (k + 0.5) / spd + margin:
				continue
			prev[n] = c
			depth[n] = k
			q.append(n)
	if shared != start:
		return _rebuild(prev, start, shared)
	if allow_best and best != start:
		return _rebuild(prev, start, best)
	if allow_best:
		# nada passa na conta do tempo: pelo menos sai para o vizinho menos perigoso
		var nb := start
		var nv := danger[_idx(start)]
		for d in G.DIRS:
			var n: Vector2i = start + d
			if _passable(p, n) and danger[_idx(n)] > nv:
				nv = danger[_idx(n)]
				nb = n
		if nb != start:
			return [nb]
	return []


## BFS por casas seguras (sem perigo nenhum): ordem por distância, para escolher alvos.
func _reach(p: Dictionary, start: Vector2i, danger: PackedFloat32Array) -> Dictionary:
	var prev := {start: start}
	var depth := {start: 0}
	var order: Array = []
	var q: Array = [start]
	var head := 0
	while head < q.size() and head < 220:
		var c: Vector2i = q[head]
		head += 1
		if c != start:
			order.append(c)
		for d in G.DIRS:
			var n: Vector2i = c + d
			if prev.has(n) or not _passable(p, n) or danger[_idx(n)] < INF_T:
				continue
			prev[n] = c
			depth[n] = depth[c] + 1
			q.append(n)
	return {"prev": prev, "depth": depth, "order": order, "start": start}


## Primeiro alvo (mais perto) que satisfaz goal(c, distância).
func _pick(reach: Dictionary, goal: Callable) -> Array:
	for c in reach.order:
		if goal.call(c, reach.depth[c]):
			return _path_to(reach, c)
	return []


func _path_to(reach: Dictionary, c: Vector2i) -> Array:
	return _rebuild(reach.prev, reach.start, c)


func _rebuild(prev: Dictionary, start: Vector2i, c: Vector2i) -> Array:
	var path: Array = []
	var cur: Vector2i = c
	while cur != start:
		path.push_front(cur)
		cur = prev[cur]
	return path


## Outro bot já está lá ou indo para lá.
func _taken(p: Dictionary, c: Vector2i) -> bool:
	for q in players.values():
		if q.id == p.id or not q.alive:
			continue
		if G.cell_of(q.pos) == c:
			return true
		if q.bot and not (q.ai_path as Array).is_empty() and q.ai_path.back() == c:
			return true
	return false


func _alive_count() -> int:
	var n := 0
	for q in players.values():
		if q.alive:
			n += 1
	return n


func _crowded(p: Dictionary, cell: Vector2i) -> bool:
	for q in players.values():
		if q.id != p.id and q.alive and G.cell_of(q.pos) == cell:
			return true
	return false


func _near_enemy(p: Dictionary, c: Vector2i, dist: int) -> bool:
	for q in players.values():
		if q.id != p.id and q.alive:
			var qc: Vector2i = G.cell_of(q.pos)
			var m := absi(qc.x - c.x) + absi(qc.y - c.y)
			if m >= 1 and m <= dist:
				return true
	return false


## Controle remoto: detona quando alguma bomba dele pega um inimigo (e ele está seguro).
func _remote_hits_enemy(p: Dictionary) -> bool:
	for b in bombs:
		if b.owner != p.id or b.fly or not b.remote:
			continue
		for c in _blast_cells(b.cell, b.range, b.pierce):
			if c == G.cell_of(p.pos):
				return false
			for q in players.values():
				if q.alive and q.id != p.id and G.cell_of(q.pos) == c:
					return true
	return false


func _bot_follow(p: Dictionary, cell: Vector2i) -> void:
	var path: Array = p.ai_path
	while not path.is_empty() and path[0] == cell:
		path.pop_front()
	if path.is_empty():
		# chegou: termina de entrar na casa (não fica parado na borda, metade na casa vizinha)
		var off: Vector2 = G.center_of(cell) - p.pos
		var d0 := Vector2i.ZERO
		if absf(off.x) > 0.12:
			d0 = Vector2i(int(signf(off.x)), 0)
		elif absf(off.y) > 0.12:
			d0 = Vector2i(0, int(signf(off.y)))
		p.dir = -d0 if p.disease == G.D_REVERSE else d0
		return
	var nxt: Vector2i = path[0]
	var d: Vector2i = nxt - cell
	if absi(d.x) + absi(d.y) != 1:
		p.ai_path = []
		p.dir = Vector2i.ZERO
		return
	p.dir = -d if p.disease == G.D_REVERSE else d
