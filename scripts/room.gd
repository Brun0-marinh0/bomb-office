extends Node
## Uma sala no servidor: lobby, placar, sequência de rodadas e a simulação (server_game.gd).
## O nó Main recebe as RPCs e repassa para a sala do jogador; a sala responde
## só para os jogadores dela (main._send_to).

const G = preload("res://scripts/g.gd")
const ServerGame = preload("res://scripts/server_game.gd")
const Codec = preload("res://scripts/snapshot_codec.gd")
const WINNER_MSG_MAX := 20
const MAP_RESEND := 30     # manda o mapa inteiro pelo menos a cada 30 snapshots (1 s), para quem entrou no meio

signal changed            # algo que aparece na lista de salas mudou (jogadores, estado)
signal emptied            # nenhum humano na sala: o Main exclui a sala

var main: Node
var code := ""
var room_name := ""
var password := ""

var lobby := {}            # id -> {id, name, color, bot}
var order: Array = []      # ids em ordem de entrada (o primeiro humano é o líder)
var wins := {}
var cfg_wins := 3
var cfg_time := 180
var state := "lobby"       # lobby | round | round_end | match_end
var roster: Array = []
var sim: Node = null
var round_no := 0
var _snap_tick := 0
var _bot_seq := 0
var test_mode := false
var sim_speed := 1
var last_winner := 0       # vencedor da última rodada (pode mandar mensagem no modal)
var closed := false
var server_ms := 0.0       # relógio da sala (os clientes interpolam por ele); nunca zera
var _last_map := PackedByteArray()
var _map_age := 0
var _jitter_at := {}       # teste --fake-jitter: id -> instante liberado do último envio
var _stat_old := 0         # teste: bytes do formato antigo / novo, para comparar
var _stat_new := 0
var _stat_n := 0


func _ready() -> void:
	sim = ServerGame.new()
	sim.name = "Sim"
	add_child(sim)
	sim.round_over.connect(_on_round_over)
	sim.game_event.connect(_on_sim_event)


func log_line(msg: String) -> void:
	print("[servidor] [%s] %s" % [room_name, msg])


# =================================================================== envio
func _humans_ids() -> Array:
	var out: Array = []
	for id in order:
		if not lobby[id].bot:
			out.append(id)
	return out


func send_all(m: StringName, a: Array) -> void:
	if test_mode:
		return
	for id in _humans_ids():
		main._send_to(id, m, a)


# =================================================================== lobby
func players_count() -> int:
	return order.size()


func is_full() -> bool:
	return order.size() >= G.MAX_PLAYERS and not (state == "lobby" and _has_bot())


func join(id: int, pname: String) -> bool:
	if lobby.has(id):
		return true
	if order.size() >= G.MAX_PLAYERS and not (state == "lobby" and _remove_bot()):
		return false
	lobby[id] = {"id": id, "name": _unique_name(main._clean_name(pname)), "color": _free_color(), "bot": false}
	order.append(id)
	wins[id] = 0
	log_line("%s entrou (id %d) — %d na sala" % [lobby[id].name, id, order.size()])
	push_lobby()
	changed.emit()
	return true


## Tira o jogador (saiu da sala ou caiu). Se era o líder, o próximo humano assume.
func remove_member(id: int) -> void:
	if not lobby.has(id):
		return
	var was_leader := id == leader()
	log_line("%s saiu" % lobby[id].name)
	lobby.erase(id)
	order.erase(id)
	wins.erase(id)
	if state == "round":
		sim.remove_player(id)
	if not test_mode and _humans(order) == 0:
		emptied.emit()
		return
	if was_leader and leader() != 0:
		log_line("%s agora é o líder" % lobby[leader()].name)
	if state != "lobby" and _humans(order) == 0:
		_back_to_lobby()
	else:
		push_lobby()
	changed.emit()


func add_bot() -> void:
	if order.size() >= G.MAX_PLAYERS:
		return
	_bot_seq += 1
	var id := -_bot_seq
	lobby[id] = {"id": id, "name": _unique_name("Bot"), "color": _free_color(), "bot": true}
	order.append(id)
	wins[id] = 0


func _has_bot() -> bool:
	for id in order:
		if lobby[id].bot:
			return true
	return false


func _remove_bot() -> bool:
	for i in range(order.size() - 1, -1, -1):
		var id: int = order[i]
		if lobby[id].bot:
			lobby.erase(id)
			wins.erase(id)
			order.remove_at(i)
			return true
	return false


func _free_color() -> int:
	for c in G.MAX_PLAYERS:
		var used := false
		for id in order:
			if lobby[id].color == c:
				used = true
		if not used:
			return c
	return 0


func _unique_name(base: String) -> String:
	var taken := {}
	for id in order:
		taken[lobby[id].name] = true
	if not taken.has(base) and base != "Bot":
		return base
	var n := 1 if base == "Bot" else 2
	while taken.has("%s %d" % [base, n]):
		n += 1
	return "%s %d" % [base, n]


func leader() -> int:
	for id in order:
		if not lobby[id].bot:
			return id
	return 0


func _humans(ids: Array) -> int:
	var n := 0
	for id in ids:
		if lobby.has(id) and not lobby[id].bot:
			n += 1
	return n


func push_lobby() -> void:
	var list: Array = []
	for id in order:
		var e: Dictionary = lobby[id]
		list.append([id, e.name, e.color, e.bot])
	send_all(&"rpc_lobby", [list, leader(), state, cfg_wins, cfg_time,
		main.share_url, main.share_fixed, room_name, code])


func _wins_for(ids: Array) -> Dictionary:
	var w := {}
	for id in ids:
		w[id] = int(wins.get(id, 0))
	return w


## Botão "Encerrar sala" do líder: todos voltam para a lista e a sala é excluída.
func close(msg: String) -> void:
	closed = true
	state = "lobby"
	sim.running = false
	log_line("sala encerrada pelo líder")
	for id in _humans_ids():
		main._send_to(id, &"rpc_left_room", [msg])


# =================================================================== comandos do líder / jogadores
func cfg(sender: int, w: int, t: int) -> void:
	if sender != leader() or state != "lobby":
		return
	cfg_wins = clampi(w, 1, 9)
	cfg_time = clampi(t, 60, 300)
	push_lobby()


func bots(sender: int, add: bool) -> void:
	if sender != leader() or state != "lobby":
		return
	if add:
		add_bot()
	else:
		_remove_bot()
	push_lobby()
	changed.emit()


func start(sender: int) -> void:
	if sender == leader() and state == "lobby" and order.size() >= 1:
		start_match()


func abort(sender: int) -> void:
	if sender == leader() and state != "lobby":
		log_line("partida encerrada pelo líder")
		_back_to_lobby()


func winner_msg(sender: int, text: String) -> void:
	if state != "round_end" and state != "match_end":
		return
	if sender != last_winner or not lobby.has(sender) or lobby[sender].bot:
		return
	var clean := ""
	for ch in text.strip_edges():
		if ch.unicode_at(0) >= 32:
			clean += ch
	clean = clean.substr(0, WINNER_MSG_MAX).strip_edges().to_upper()
	if clean != "":
		log_line("mensagem do vencedor %s: %s" % [lobby[sender].name, clean])
		send_all(&"rpc_winner_text", [sender, clean])


func input(sender: int, d: Vector2i) -> void:
	if state == "round":
		sim.set_input(sender, d)


func bomb(sender: int) -> void:
	if state == "round":
		sim.request_bomb(sender)


func action(sender: int) -> void:
	if state == "round":
		sim.request_action(sender)


# =================================================================== partida
func start_match() -> void:
	roster = order.slice(0, G.MAX_PLAYERS)
	for id in roster:
		wins[id] = 0
	round_no = 0
	log_line("partida iniciada com %d jogadores (vence quem fizer %d)" % [roster.size(), cfg_wins])
	_start_round()
	changed.emit()


func _start_round() -> void:
	roster = roster.filter(func(id): return lobby.has(id))
	if roster.is_empty() or (not test_mode and _humans(roster) == 0):
		_back_to_lobby()
		return
	round_no += 1
	var entries: Array = []
	for id in roster:
		entries.append({"id": id, "name": lobby[id].name, "bot": lobby[id].bot})
	entries.shuffle()
	sim.start_round(entries, float(cfg_time))
	state = "round"
	_snap_tick = 0
	_last_map = PackedByteArray()   # primeiro snapshot da rodada leva o mapa
	push_lobby()
	send_all(&"rpc_round_start", [round_no, roster.duplicate(), _wins_for(roster)])


func _physics_process(delta: float) -> void:
	server_ms += delta * 1000.0
	if state != "round" or closed:
		return
	for i in sim_speed:
		if sim.running:
			sim.tick(delta)
	_snap_tick += 1
	if state == "round" and _snap_tick % 2 == 0:
		_send_snapshot(false)


## Codifica o snapshot uma vez (scripts/snapshot_codec.gd) e manda os mesmos bytes para todos.
func _send_snapshot(force_map: bool) -> void:
	var s: Array = sim.snapshot()
	var map: PackedByteArray = s[1] + s[3]
	_map_age += 1
	var with_map := force_map or _map_age >= MAP_RESEND or map != _last_map
	if with_map:
		_last_map = map
		_map_age = 0
	var data := Codec.encode(int(server_ms), s, with_map)
	if test_mode:
		_stat_old += var_to_bytes(s).size()
		_stat_new += data.size()
		_stat_n += 1
		return
	var jitter := int(main.args.get("fake-jitter", "0"))
	if jitter <= 0:
		send_all(&"rpc_snapshot", [data])
		return
	# teste: atrasa cada envio (sem trocar a ordem, como numa rede Wi-Fi ruim)
	var now := Time.get_ticks_msec() / 1000.0
	for id in _humans_ids():
		var at := maxf(float(_jitter_at.get(id, 0.0)), now + randf() * jitter / 1000.0)
		_jitter_at[id] = at
		get_tree().create_timer(at - now).timeout.connect(func():
			if lobby.has(id) and not closed:
				main._send_to(id, &"rpc_snapshot", [data]))


## Teste: tamanho médio do snapshot no formato antigo (Array de Variants) e no novo.
func snapshot_stats() -> String:
	if _stat_n == 0:
		return ""
	return "snapshot médio: antigo %d B, novo %d B (%d amostras)" % [_stat_old / _stat_n, _stat_new / _stat_n, _stat_n]


func _on_round_over(winner: int) -> void:
	if winner != 0:
		wins[winner] = int(wins.get(winner, 0)) + 1
	state = "round_end"
	var wname: String = lobby[winner].name if lobby.has(winner) else "?"
	log_line("rodada %d: %s" % [round_no, ("vitória de " + wname) if winner != 0 else "empate"])
	var w := _wins_for(roster)
	last_winner = winner
	_send_snapshot(true)
	send_all(&"rpc_round_end", [winner, w])
	var champion := winner != 0 and int(wins[winner]) >= cfg_wins
	# vencedor humano ganha mais tempo para escrever a mensagem
	var human_winner: bool = lobby.has(winner) and not lobby[winner].bot
	var wait := 4.0
	if champion:
		wait = 3.0
	elif human_winner:
		wait = 9.0
	await get_tree().create_timer(wait / sim_speed).timeout
	if state != "round_end" or closed or not is_inside_tree():
		return
	if test_mode and (champion or round_no >= 20):
		print("[teste] fim da partida. placar: %s" % str(w))
		print("[teste] %s" % snapshot_stats())
		get_tree().quit(0)
		return
	if not champion:
		_start_round()
		return
	state = "match_end"
	log_line("CAMPEÃO: %s" % wname)
	send_all(&"rpc_match_end", [winner, w])
	await get_tree().create_timer(12.0 if human_winner else 7.0).timeout
	if state == "match_end" and not closed and is_inside_tree():
		_back_to_lobby()


func _back_to_lobby() -> void:
	state = "lobby"
	sim.running = false
	push_lobby()
	changed.emit()


func _on_sim_event(kind: String, data: Array) -> void:
	if test_mode:
		if kind == "death" and lobby.has(data[0]):
			print("[teste]   %s morreu (faltando %ds)" % [lobby[data[0]].name, int(sim.time_left)])
		return
	send_all(&"rpc_event", [kind, data])
