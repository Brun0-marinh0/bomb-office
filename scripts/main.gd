extends Node
## Cena principal do BombOffice.
## - Servidor: lobby, sequência de rodadas/placar e a simulação (server_game.gd).
## - Cliente: menu, lobby, HUD, entrada do jogador e renderização (game_view.gd).
## Toda a comunicação passa pelas funções rpc_* deste nó (/root/Main).
##
## Argumentos de linha de comando (depois de "--"):
##   --server                 servidor dedicado (também automático em --headless)
##   --port=9080              porta do servidor
##   --cert=x.pem --key=y.pem ativa wss:// (TLS) direto no servidor
##   --test-bots=4            partida só de bots, para testar (sai ao final)
##   --autojoin=ws://host:porta --name=Fulano --autostart --addbots=2   (testes)

const G = preload("res://scripts/g.gd")
const ServerGame = preload("res://scripts/server_game.gd")
const GameView = preload("res://scripts/game_view.gd")
const TouchControls = preload("res://scripts/touch_controls.gd")
const ItemIcon = preload("res://scripts/item_icon.gd")
const WinnerDisplay = preload("res://scripts/winner_display.gd")
const WINNER_MSG_MAX := 20
const SETTINGS_PATH := "user://settings.cfg"
const ABILITY_NAMES := ["Chute", "Luva", "Remoto", "Perfurante", "Linha", "Super Bomba",
	"Atravessa paredes", "Atravessa bombas"]

var args := {}

# ------------------------------------------------------------- estado do servidor
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
var share_url := ""
var share_fixed := false
var last_winner := 0       # vencedor da última rodada (pode mandar mensagem no modal)

# ------------------------------------------------------------- estado do cliente
var my_id := 0
var player_name := ""
var cl_players: Array = []
var cl_leader := 0
var cl_state := "lobby"
var cl_cfg_wins := 3
var cl_cfg_time := 180
var cl_roster: Array = []
var cl_wins := {}
var dir_stack: Array = []
var last_dir := Vector2i.ZERO
var auto_started := false
var _snap_count := 0
var cl_share_url := ""
var cl_share_fixed := false

# ------------------------------------------------------------- UI
var view: Node2D
var ui: Control
var screens := {}
var screen := ""
var name_edit: LineEdit
var url_edit: LineEdit
var url_box: Control
var host_box: Control
var status_label: Label
var lobby_list: VBoxContainer
var link_box: Control
var link_edit: LineEdit
var leader_box: VBoxContainer
var copy_btn: Button
var close_dialog: ConfirmationDialog
var wins_value: Label
var time_value: Label
var wait_label: Label
var start_btn: Button
var hud_time: Label
var hud_chips: HBoxContainer
var hud_stats: Label
var hud_abort: Button
var overlay: CenterContainer
var overlay_label: Label
var winner_disp: Control
var score_label: Label
var msg_row: HBoxContainer
var msg_edit: LineEdit
var cl_winner := 0
var touch: Control
var chips := {}
var chip_ids: Array = []
var _overlay_token := 0


# =================================================================== inicialização
func _ready() -> void:
	args = _parse_args()
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var headless := DisplayServer.get_name() == "headless"
	if OS.has_feature("dedicated_server") or args.has("server") or args.has("test-bots") \
			or (headless and not args.has("autojoin")):
		_start_dedicated()
		return
	RenderingServer.set_default_clear_color(Color(0.07, 0.08, 0.11))
	_load_settings()
	view = GameView.new()
	view.visible = false
	add_child(view)
	_build_ui()
	_show("menu")
	if args.has("autojoin"):
		player_name = str(args.get("name", "Teste"))
		_connect_to(str(args["autojoin"]))
	if args.has("screenshot"):
		_take_screenshot(str(args["screenshot"]), float(args.get("shot-delay", "5")))


## Teste: --screenshot=arquivo.png --shot-delay=5 [--shot-count=4 --shot-interval=1.5]
func _take_screenshot(path: String, delay: float) -> void:
	var count := maxi(1, int(args.get("shot-count", "1")))
	var interval := float(args.get("shot-interval", "1.0"))
	await get_tree().create_timer(delay).timeout
	for i in count:
		await RenderingServer.frame_post_draw
		var out := path if count == 1 else path.get_basename() + "_%d.png" % i
		get_viewport().get_texture().get_image().save_png(out)
		print("[teste] captura salva em %s" % out)
		if i < count - 1:
			await get_tree().create_timer(interval).timeout
	get_tree().quit(0)


func _parse_args() -> Dictionary:
	var out := {}
	var all: PackedStringArray = OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	for a in all:
		if not a.begins_with("--"):
			continue
		var s := a.substr(2)
		var eq := s.find("=")
		if eq >= 0:
			out[s.substr(0, eq)] = s.substr(eq + 1)
		else:
			out[s] = ""
	return out


func _start_dedicated() -> void:
	var port := int(args.get("port", str(G.DEFAULT_PORT)))
	var tls: TLSOptions = null
	if args.has("cert") and args.has("key"):
		var cert := X509Certificate.new()
		var key := CryptoKey.new()
		if cert.load(str(args["cert"])) == OK and key.load(str(args["key"])) == OK:
			tls = TLSOptions.server(key, cert)
		else:
			push_error("Falha ao carregar certificado/chave TLS")
	if not _start_server(port, true, tls):
		get_tree().quit(1)
		return
	if args.has("test-bots"):
		test_mode = true
		sim_speed = maxi(1, int(args.get("speed", "4")))
		cfg_wins = maxi(1, int(args.get("wins", "2")))
		for i in clampi(int(args["test-bots"]), 1, G.MAX_PLAYERS):
			_add_bot()
		_start_match()


func _start_server(port: int, dedicated: bool, tls: TLSOptions) -> bool:
	var err := Net.host(port, dedicated, tls)
	if err != OK:
		var msg := "Não foi possível abrir o servidor na porta %d (erro %d)." % [port, err]
		print(msg)
		if status_label != null:
			status_label.text = msg
		return false
	sim = ServerGame.new()
	sim.name = "Sim"
	add_child(sim)
	sim.round_over.connect(_on_round_over)
	sim.game_event.connect(_on_sim_event)
	share_url = _detect_share_url()
	print("[servidor] escutando em %s://0.0.0.0:%d" % ["wss" if tls != null else "ws", port])
	if share_url != "":
		print("[servidor] link para convidar: %s" % share_url)
	return true


# =================================================================== utilidades de rede
func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


func _broadcast(m: StringName, a: Array) -> void:
	if multiplayer.get_peers().size() > 0:
		callv("rpc", [m] + a)
	if Net.is_server and not Net.is_dedicated:
		callv(m, a)


func _send_to(id: int, m: StringName, a: Array) -> void:
	if Net.is_server and not Net.is_dedicated and id == multiplayer.get_unique_id():
		callv(m, a)
	else:
		callv("rpc_id", [id, m] + a)


func _to_server(m: StringName, a: Array = []) -> void:
	if Net.is_server:
		callv(m, a)
	elif multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		callv("rpc_id", [1, m] + a)


# =================================================================== SERVIDOR: lobby
func _server_join(id: int, pname: String) -> void:
	if lobby.has(id):
		return
	if order.size() >= G.MAX_PLAYERS and not (state == "lobby" and _remove_bot()):
		_send_to(id, &"rpc_rejected", ["Sala cheia (máximo de %d jogadores)." % G.MAX_PLAYERS])
		return
	lobby[id] = {"id": id, "name": _unique_name(_clean_name(pname)), "color": _free_color(), "bot": false}
	order.append(id)
	wins[id] = 0
	print("[servidor] %s entrou (id %d) — %d na sala" % [lobby[id].name, id, order.size()])
	_push_lobby()


func _add_bot() -> void:
	if order.size() >= G.MAX_PLAYERS:
		return
	_bot_seq += 1
	var id := -_bot_seq
	lobby[id] = {"id": id, "name": _unique_name("Bot"), "color": _free_color(), "bot": true}
	order.append(id)
	wins[id] = 0


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


func _clean_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.unicode_at(0) >= 32:
			out += ch
	out = out.substr(0, 12).strip_edges()
	return out if out != "" else "Jogador"


func _leader() -> int:
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


func _push_lobby() -> void:
	var list: Array = []
	for id in order:
		var e: Dictionary = lobby[id]
		list.append([id, e.name, e.color, e.bot])
	_broadcast(&"rpc_lobby", [list, _leader(), state, cfg_wins, cfg_time, share_url, share_fixed])


## Link para convidar outros jogadores (passe --share-url=... para fixar).
## Sem o argumento, tenta adivinhar o IP da rede local deste PC
## (exceto dentro do Docker, onde só enxergaria o IP interno do container).
func _detect_share_url() -> String:
	var fixed := str(args.get("share-url", "")).strip_edges()
	share_fixed = fixed != ""
	if share_fixed:
		return fixed
	if OS.get_environment("BOMB_IN_DOCKER") != "":
		return ""
	var web_port := int(args.get("web-port", "8060"))
	var best := ""
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var is_private := a.begins_with("10.") or a.begins_with("192.168.") \
				or (a.begins_with("172.") and int(a.split(".")[1]) >= 16 and int(a.split(".")[1]) <= 31)
		if not is_private:
			continue
		# adaptadores virtuais (WSL, Hyper-V, hotspot) costumam terminar em .1
		if best == "" or (best.ends_with(".1") and not a.ends_with(".1")):
			best = a
	return "http://%s:%d/" % [best, web_port] if best != "" else ""


## Expulsa todos da sala (botão "Encerrar sala" do líder).
func _close_room() -> void:
	print("[servidor] sala encerrada pelo líder — todos foram desconectados")
	var humans: Array = []
	for id in order:
		if not lobby[id].bot:
			humans.append(id)
	state = "lobby"
	if sim != null:
		sim.running = false
	lobby.clear()
	order.clear()
	wins.clear()
	roster.clear()
	_bot_seq = 0
	for id in humans:
		_send_to(id, &"rpc_rejected", ["A sala foi encerrada pelo líder."])
	await get_tree().create_timer(1.0).timeout
	var peer := multiplayer.multiplayer_peer as WebSocketMultiplayerPeer
	if peer != null:
		for id in humans:
			if id != multiplayer.get_unique_id() and multiplayer.get_peers().has(id):
				peer.disconnect_peer(id)


func _wins_for(ids: Array) -> Dictionary:
	var w := {}
	for id in ids:
		w[id] = int(wins.get(id, 0))
	return w


func _on_peer_disconnected(id: int) -> void:
	if not Net.is_server or not lobby.has(id):
		return
	print("[servidor] %s saiu" % lobby[id].name)
	lobby.erase(id)
	order.erase(id)
	wins.erase(id)
	if sim != null and state == "round":
		sim.remove_player(id)
	if not test_mode and state != "lobby" and _humans(order) == 0:
		_back_to_lobby()
		return
	_push_lobby()


# =================================================================== SERVIDOR: partida
func _start_match() -> void:
	roster = order.slice(0, G.MAX_PLAYERS)
	for id in roster:
		wins[id] = 0
	round_no = 0
	print("[servidor] partida iniciada com %d jogadores (vence quem fizer %d)" % [roster.size(), cfg_wins])
	_start_round()


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
	_push_lobby()
	_broadcast(&"rpc_round_start", [round_no, roster.duplicate(), _wins_for(roster)])


func _physics_process(delta: float) -> void:
	if Net.is_server and sim != null and state == "round":
		for i in sim_speed:
			if sim.running:
				sim.tick(delta)
		_snap_tick += 1
		if state == "round" and _snap_tick % 2 == 0 and not test_mode:
			_broadcast(&"rpc_snapshot", [sim.snapshot()])
	if view != null and screen == "game" and my_id in cl_roster:
		_send_input()


func _on_round_over(winner: int) -> void:
	if winner != 0:
		wins[winner] = int(wins.get(winner, 0)) + 1
	state = "round_end"
	var wname: String = lobby[winner].name if lobby.has(winner) else "?"
	print("[servidor] rodada %d: %s" % [round_no, ("vitória de " + wname) if winner != 0 else "empate"])
	var w := _wins_for(roster)
	last_winner = winner
	_broadcast(&"rpc_snapshot", [sim.snapshot()])
	_broadcast(&"rpc_round_end", [winner, w])
	var champion := winner != 0 and int(wins[winner]) >= cfg_wins
	# vencedor humano ganha mais tempo para escrever a mensagem
	var human_winner: bool = lobby.has(winner) and not lobby[winner].bot
	var wait := 4.0
	if champion:
		wait = 3.0
	elif human_winner:
		wait = 9.0
	await get_tree().create_timer(wait / sim_speed).timeout
	if state != "round_end":
		return
	if test_mode and (champion or round_no >= 20):
		print("[teste] fim da partida. placar: %s" % str(w))
		get_tree().quit(0)
		return
	if not champion:
		_start_round()
		return
	state = "match_end"
	print("[servidor] CAMPEÃO: %s" % wname)
	_broadcast(&"rpc_match_end", [winner, w])
	await get_tree().create_timer(12.0 if human_winner else 7.0).timeout
	if state == "match_end":
		_back_to_lobby()


func _back_to_lobby() -> void:
	state = "lobby"
	if sim != null:
		sim.running = false
	_push_lobby()


func _on_sim_event(kind: String, data: Array) -> void:
	if test_mode:
		if kind == "death" and lobby.has(data[0]):
			print("[teste]   %s morreu (faltando %ds)" % [lobby[data[0]].name, int(sim.time_left)])
		return
	_broadcast(&"rpc_event", [kind, data])


# =================================================================== RPC: cliente -> servidor
@rpc("any_peer", "reliable")
func rpc_join(pname: String) -> void:
	if Net.is_server:
		_server_join(_sender(), pname)


@rpc("any_peer", "reliable")
func rpc_cfg(w: int, t: int) -> void:
	if not Net.is_server or _sender() != _leader() or state != "lobby":
		return
	cfg_wins = clampi(w, 1, 9)
	cfg_time = clampi(t, 60, 300)
	_push_lobby()


@rpc("any_peer", "reliable")
func rpc_bots(add: bool) -> void:
	if not Net.is_server or _sender() != _leader() or state != "lobby":
		return
	if add:
		_add_bot()
	else:
		_remove_bot()
	_push_lobby()


@rpc("any_peer", "reliable")
func rpc_start() -> void:
	if Net.is_server and _sender() == _leader() and state == "lobby" and order.size() >= 1:
		_start_match()


@rpc("any_peer", "reliable")
func rpc_winner_msg(text: String) -> void:
	if not Net.is_server or (state != "round_end" and state != "match_end"):
		return
	var id := _sender()
	if id != last_winner or not lobby.has(id) or lobby[id].bot:
		return
	var clean := ""
	for ch in text.strip_edges():
		if ch.unicode_at(0) >= 32:
			clean += ch
	clean = clean.substr(0, WINNER_MSG_MAX).strip_edges().to_upper()
	if clean != "":
		print("[servidor] mensagem do vencedor %s: %s" % [lobby[id].name, clean])
		_broadcast(&"rpc_winner_text", [id, clean])


@rpc("any_peer", "reliable")
func rpc_close_room() -> void:
	if Net.is_server and _sender() == _leader() and state == "lobby":
		_close_room()


@rpc("any_peer", "reliable")
func rpc_abort() -> void:
	if Net.is_server and _sender() == _leader() and state != "lobby":
		print("[servidor] partida encerrada pelo líder")
		_back_to_lobby()


@rpc("any_peer", "reliable")
func rpc_input(x: int, y: int) -> void:
	if Net.is_server and sim != null and state == "round":
		sim.set_input(_sender(), Vector2i(clampi(x, -1, 1), clampi(y, -1, 1)))


@rpc("any_peer", "reliable")
func rpc_bomb() -> void:
	if Net.is_server and sim != null and state == "round":
		sim.request_bomb(_sender())


@rpc("any_peer", "reliable")
func rpc_action() -> void:
	if Net.is_server and sim != null and state == "round":
		sim.request_action(_sender())


# =================================================================== RPC: servidor -> clientes
@rpc("authority", "reliable")
func rpc_lobby(list: Array, leader: int, st: String, w: int, t: int, share: String, share_fixed: bool) -> void:
	if Net.is_dedicated or view == null:
		return
	cl_share_url = share
	cl_share_fixed = share_fixed
	cl_players = list
	cl_leader = leader
	cl_cfg_wins = w
	cl_cfg_time = t
	cl_state = st
	view.set_roster(list)
	if st == "lobby":
		_show("lobby")
	elif screen != "game":
		_show("game")
		_show_overlay("Partida em andamento.\nVocê entra na próxima!", 3.0)
	_refresh_lobby()
	if args.has("autostart") and not auto_started and leader == my_id and st == "lobby" \
			and list.size() >= int(args.get("autostart-min", "1")):
		auto_started = true
		for i in int(args.get("addbots", "0")):
			_to_server(&"rpc_bots", [true])
		_to_server(&"rpc_start", [])


@rpc("authority", "reliable")
func rpc_rejected(msg: String) -> void:
	if view == null:
		return
	_on_leave_pressed()
	status_label.text = msg
	if args.has("autojoin"):
		print("[cliente] removido da sala: %s" % msg)
		if args.has("autoquit"):
			get_tree().quit(0)


@rpc("authority", "reliable")
func rpc_round_start(n: int, ids: Array, w: Dictionary) -> void:
	if Net.is_dedicated or view == null:
		return
	cl_roster = ids
	cl_wins = w
	cl_state = "round"
	view.reset()
	view.my_id = my_id
	dir_stack.clear()
	last_dir = Vector2i.ZERO
	_show("game")
	get_viewport().gui_release_focus()
	_rebuild_chips(ids)
	var txt := "RODADA %d" % n
	if my_id in ids:
		var c := _color_of(my_id)
		txt += "\nVocê é o bloco %s" % G.PLAYER_COLOR_NAMES[c]
	_show_overlay(txt, 2.0)
	if args.has("autojoin"):
		print("[cliente] rodada %d começou" % n)
	if args.has("test-suicide"):   # teste: solta uma bomba e fica parado
		await get_tree().create_timer(1.0).timeout
		_to_server(&"rpc_bomb")


@rpc("authority", "unreliable_ordered")
func rpc_snapshot(s: Array) -> void:
	if Net.is_dedicated or view == null:
		return
	_snap_count += 1
	view.apply(s)
	_update_hud(s)


@rpc("authority", "reliable")
func rpc_event(kind: String, data: Array) -> void:
	if Net.is_dedicated or view == null:
		return
	view.on_event(kind, data)
	match kind:
		"sudden":
			_show_overlay("MORTE SÚBITA!", 1.5)
		"death":
			if data[0] == my_id:
				_show_overlay("Você foi eliminado!", 1.5)


@rpc("authority", "reliable")
func rpc_round_end(winner: int, w: Dictionary) -> void:
	if Net.is_dedicated or view == null:
		return
	cl_wins = w
	view.winner = winner
	var title := "EMPATE!" if winner == 0 else "%s venceu a rodada!" % _name_of(winner)
	_show_winner_overlay(winner, title, w)
	if args.has("autojoin"):
		print("[cliente] fim da rodada: %s (snapshots recebidos: %d)" % [title, _snap_count])
	if args.has("winner-msg") and winner == my_id:   # teste: escreve a mensagem sozinho
		await get_tree().create_timer(1.0).timeout
		msg_edit.text = str(args["winner-msg"])
		_send_winner_msg()


@rpc("authority", "reliable")
func rpc_winner_text(winner: int, text: String) -> void:
	if Net.is_dedicated or view == null:
		return
	if winner_disp.visible and cl_winner == winner:
		winner_disp.message = text
	if args.has("autojoin"):
		print("[cliente] mensagem do vencedor recebida: %s" % text)


@rpc("authority", "reliable")
func rpc_match_end(winner: int, w: Dictionary) -> void:
	if Net.is_dedicated or view == null:
		return
	cl_wins = w
	view.winner = winner
	_show_winner_overlay(winner, "%s É O CAMPEÃO!" % _name_of(winner).to_upper(), w)
	if args.has("autojoin"):
		print("[cliente] campeão: %s" % _name_of(winner))
		if args.has("autoquit"):
			get_tree().quit(0)


# =================================================================== CLIENTE: conexão
func _connect_to(url: String) -> void:
	if url == "":
		status_label.text = "Informe o endereço do servidor."
		return
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		url = "ws://" + url
	var err := Net.join(url)
	if err != OK:
		status_label.text = "Endereço inválido (erro %d)." % err
		return
	status_label.text = "Conectando em %s ..." % url


func _on_connected() -> void:
	my_id = multiplayer.get_unique_id()
	status_label.text = "Conectado!"
	_to_server(&"rpc_join", [player_name])
	await get_tree().create_timer(5.0).timeout
	if screen == "menu" and multiplayer.multiplayer_peer is WebSocketMultiplayerPeer:
		status_label.text = "O servidor não respondeu. Sua versão do jogo pode estar desatualizada:\nrecarregue a página (Ctrl+F5) e tente de novo."


func _on_connection_failed() -> void:
	Net.leave()
	if status_label != null:
		status_label.text = "Não foi possível conectar ao servidor."
	if args.has("autoquit"):
		get_tree().quit(1)


func _on_server_disconnected() -> void:
	Net.leave()
	if view == null:
		return
	_show("menu")
	status_label.text = "A conexão com o servidor caiu."
	if args.has("autoquit"):
		get_tree().quit(1)


func _on_join_pressed() -> void:
	player_name = _clean_name(name_edit.text)
	_save_settings()
	_connect_to(url_edit.text.strip_edges())


func _on_host_pressed() -> void:
	player_name = _clean_name(name_edit.text)
	_save_settings()
	if _start_server(G.DEFAULT_PORT, false, null):
		my_id = 1
		_server_join(1, player_name)


func _on_dedicated_pressed() -> void:
	if _start_server(G.DEFAULT_PORT, true, null):
		host_box.visible = false
		status_label.text = "Servidor dedicado rodando na porta %d.\nAbra o jogo em outra janela/navegador para jogar." % G.DEFAULT_PORT


func _on_leave_pressed() -> void:
	Net.leave()
	if sim != null:
		sim.queue_free()
		sim = null
	lobby.clear()
	order.clear()
	wins.clear()
	state = "lobby"
	my_id = 0
	host_box.visible = not OS.has_feature("web")
	_show("menu")
	status_label.text = ""


# =================================================================== CLIENTE: entrada
func _send_input() -> void:
	var d := Vector2i.ZERO
	if not dir_stack.is_empty():
		d = dir_stack.back()
	if d == Vector2i.ZERO and touch.visible:
		d = touch.dir
	if d == Vector2i.ZERO:
		d = _joy_dir()
	if d != last_dir:
		last_dir = d
		_to_server(&"rpc_input", [d.x, d.y])


func _joy_dir() -> Vector2i:
	if Input.get_connected_joypads().is_empty():
		return Vector2i.ZERO
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP):
		return Vector2i(0, -1)
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN):
		return Vector2i(0, 1)
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT):
		return Vector2i(-1, 0)
	if Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT):
		return Vector2i(1, 0)
	var v := Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if v.length() < 0.5:
		return Vector2i.ZERO
	if absf(v.x) > absf(v.y):
		return Vector2i(int(signf(v.x)), 0)
	return Vector2i(0, int(signf(v.y)))


func _key_dir(k: int) -> Vector2i:
	match k:
		KEY_W, KEY_UP:
			return Vector2i(0, -1)
		KEY_S, KEY_DOWN:
			return Vector2i(0, 1)
		KEY_A, KEY_LEFT:
			return Vector2i(-1, 0)
		KEY_D, KEY_RIGHT:
			return Vector2i(1, 0)
	return Vector2i.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if screen != "game":
		return
	if event is InputEventKey and not event.echo:
		var k: int = event.physical_keycode
		var d := _key_dir(k)
		if d != Vector2i.ZERO:
			dir_stack.erase(d)
			if event.pressed:
				dir_stack.append(d)
			get_viewport().set_input_as_handled()
		elif event.pressed:
			if k in [KEY_SPACE, KEY_J, KEY_Z, KEY_ENTER, KEY_KP_0]:
				_to_server(&"rpc_bomb")
				get_viewport().set_input_as_handled()
			elif k in [KEY_SHIFT, KEY_K, KEY_X, KEY_E, KEY_CTRL]:
				_to_server(&"rpc_action")
				get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_A:
			_to_server(&"rpc_bomb")
		elif event.button_index == JOY_BUTTON_B or event.button_index == JOY_BUTTON_X:
			_to_server(&"rpc_action")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		dir_stack.clear()


func _process(_dt: float) -> void:
	if view == null or not view.visible:
		return
	var vs := get_viewport().get_visible_rect().size
	var top := 50.0
	var bottom := 40.0
	var map := Vector2(G.W * G.TILE, G.H * G.TILE)
	var s := minf((vs.x - 16.0) / map.x, (vs.y - top - bottom) / map.y)
	if s >= 1.0:
		s = floorf(s * 4.0) / 4.0
	view.scale = Vector2(s, s)
	view.position = Vector2((vs.x - map.x * s) * 0.5, top + (vs.y - top - bottom - map.y * s) * 0.5).round()


# =================================================================== UI
func _label(text: String, size := 18) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _button(text: String, cb: Callable, size := 18) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.pressed.connect(cb)
	return b


func _make_panel(min_w: float) -> Array:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = min_w
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	margin.add_child(vb)
	return [center, vb]


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font_size = 18
	ui.theme = th
	layer.add_child(ui)
	_build_menu()
	_build_lobby()
	_build_hud()
	_build_overlay()
	touch = TouchControls.new()
	touch.visible = false
	ui.add_child(touch)
	touch.bomb_pressed.connect(func(): _to_server(&"rpc_bomb"))
	touch.action_pressed.connect(func(): _to_server(&"rpc_action"))


func _build_menu() -> void:
	var r := _make_panel(460)
	screens["menu"] = r[0]
	var vb: VBoxContainer = r[1]
	var title := _label("BOMB OFFICE", 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := _label("Batalha de bombas online • 2 a 8 jogadores", 15)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.7)
	vb.add_child(sub)
	vb.add_child(_label("Seu nome:"))
	name_edit = LineEdit.new()
	name_edit.max_length = 12
	name_edit.text = player_name
	name_edit.placeholder_text = "Digite seu nome"
	name_edit.text_submitted.connect(func(_t): _on_join_pressed())
	vb.add_child(name_edit)
	var ub := VBoxContainer.new()
	ub.add_child(_label("Servidor:", 15))
	url_edit = LineEdit.new()
	url_edit.text = Net.default_url()
	ub.add_child(url_edit)
	url_box = ub
	url_box.visible = not Net.url_has_server_param()
	vb.add_child(url_box)
	vb.add_child(_button("ENTRAR", _on_join_pressed, 22))
	var hb := HBoxContainer.new()
	var h1 := _button("Hospedar e jogar", _on_host_pressed, 15)
	h1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h2 := _button("Servidor dedicado", _on_dedicated_pressed, 15)
	h2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(h1)
	hb.add_child(h2)
	host_box = hb
	host_box.visible = not OS.has_feature("web")
	vb.add_child(host_box)
	status_label = _label("", 15)
	status_label.modulate = Color(1, 0.75, 0.5)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.x = 420
	vb.add_child(status_label)
	var help := _label("Teclado: Setas/WASD movem • Espaço solta bomba • Shift/E ação\nCelular: analógico à esquerda, botões à direita", 13)
	help.modulate = Color(1, 1, 1, 0.6)
	vb.add_child(help)


func _build_lobby() -> void:
	var r := _make_panel(900)
	screens["lobby"] = r[0]
	var vb: VBoxContainer = r[1]
	var title := _label("SALA DE ESPERA", 30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var lb := HBoxContainer.new()
	lb.add_child(_label("Convide pelo link:", 15))
	link_edit = LineEdit.new()
	link_edit.editable = false
	link_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb.add_child(link_edit)
	copy_btn = _button("Copiar link", _on_copy_pressed, 15)
	lb.add_child(copy_btn)
	link_box = lb
	vb.add_child(link_box)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	vb.add_child(cols)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 380
	cols.add_child(left)
	left.add_child(_label("Jogadores (máx. %d):" % G.MAX_PLAYERS, 16))
	lobby_list = VBoxContainer.new()
	left.add_child(lobby_list)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 8
	left.add_child(spacer)

	leader_box = VBoxContainer.new()
	left.add_child(leader_box)
	var rw := HBoxContainer.new()
	rw.add_child(_label("Vitórias para vencer:", 16))
	rw.add_child(_button(" - ", func(): _to_server(&"rpc_cfg", [cl_cfg_wins - 1, cl_cfg_time]), 16))
	wins_value = _label("3", 16)
	rw.add_child(wins_value)
	rw.add_child(_button(" + ", func(): _to_server(&"rpc_cfg", [cl_cfg_wins + 1, cl_cfg_time]), 16))
	leader_box.add_child(rw)
	var rt := HBoxContainer.new()
	rt.add_child(_label("Tempo da rodada:", 16))
	rt.add_child(_button(" - ", func(): _to_server(&"rpc_cfg", [cl_cfg_wins, cl_cfg_time - 30]), 16))
	time_value = _label("3:00", 16)
	rt.add_child(time_value)
	rt.add_child(_button(" + ", func(): _to_server(&"rpc_cfg", [cl_cfg_wins, cl_cfg_time + 30]), 16))
	leader_box.add_child(rt)
	var rb := HBoxContainer.new()
	rb.add_child(_button("+ Bot", func(): _to_server(&"rpc_bots", [true]), 16))
	rb.add_child(_button("- Bot", func(): _to_server(&"rpc_bots", [false]), 16))
	leader_box.add_child(rb)
	start_btn = _button("INICIAR PARTIDA", func(): _to_server(&"rpc_start"), 22)
	leader_box.add_child(start_btn)
	var close_btn := _button("Encerrar sala (expulsar todos)", func(): close_dialog.popup_centered(), 15)
	close_btn.modulate = Color(1, 0.6, 0.55)
	leader_box.add_child(close_btn)
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Encerrar sala"
	close_dialog.dialog_text = "Todos os jogadores serão desconectados e a sala será zerada.\nDeseja continuar?"
	close_dialog.ok_button_text = "Encerrar"
	close_dialog.cancel_button_text = "Cancelar"
	close_dialog.confirmed.connect(func(): _to_server(&"rpc_close_room"))
	ui.add_child(close_dialog)
	wait_label = _label("", 16)
	wait_label.modulate = Color(1, 1, 1, 0.75)
	left.add_child(wait_label)
	left.add_child(_button("Sair", _on_leave_pressed, 15))

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(_label("Itens (escondidos nos blocos):", 16))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var items_vb := VBoxContainer.new()
	items_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(items_vb)
	for i in range(1, G.ITEM_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var icon := ItemIcon.new()
		icon.item = i
		row.add_child(icon)
		var l := _label("%s — %s" % [G.ITEM_NAMES[i], G.ITEM_DESCS[i]], 14)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size.x = 360
		row.add_child(l)
		items_vb.add_child(row)


func _build_hud() -> void:
	var hud := Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)
	screens["game"] = hud
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_bottom = 46
	top.add_theme_constant_override("separation", 16)
	hud.add_child(top)
	hud_time = _label("3:00", 26)
	hud_time.custom_minimum_size.x = 80
	top.add_child(hud_time)
	hud_chips = HBoxContainer.new()
	hud_chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_chips.alignment = BoxContainer.ALIGNMENT_CENTER
	hud_chips.add_theme_constant_override("separation", 14)
	top.add_child(hud_chips)
	hud_abort = _button("Encerrar partida", func(): _to_server(&"rpc_abort"), 14)
	hud_abort.focus_mode = Control.FOCUS_NONE
	hud_abort.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(hud_abort)
	hud_stats = _label("", 16)
	hud_stats.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hud_stats.offset_top = -34
	hud_stats.offset_left = 12
	hud_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(hud_stats)


func _build_overlay() -> void:
	overlay = CenterContainer.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	ui.add_child(overlay)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	overlay_label = _label("", 28)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(overlay_label)
	winner_disp = WinnerDisplay.new()
	winner_disp.visible = false
	vb.add_child(winner_disp)
	score_label = _label("", 20)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.visible = false
	vb.add_child(score_label)
	msg_row = HBoxContainer.new()
	msg_row.visible = false
	msg_edit = LineEdit.new()
	msg_edit.max_length = WINNER_MSG_MAX
	msg_edit.placeholder_text = "Escreva algo para todos (Enter)"
	msg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msg_edit.text_submitted.connect(func(_t): _send_winner_msg())
	msg_row.add_child(msg_edit)
	msg_row.add_child(_button("Enviar", _send_winner_msg, 16))
	vb.add_child(msg_row)


func _show(which: String) -> void:
	screen = which
	for k in screens:
		screens[k].visible = (k == which)
	view.visible = which == "game"
	touch.visible = which == "game" and DisplayServer.is_touchscreen_available()
	if which != "game":
		overlay.visible = false
		dir_stack.clear()


## Modal de vitória: sprite do vencedor + placar; o vencedor humano pode mandar uma mensagem.
func _show_winner_overlay(winner: int, title: String, w: Dictionary) -> void:
	var same_winner := winner_disp.visible and cl_winner == winner
	_show_overlay(title, 0.0)
	score_label.text = _scoreboard(w)
	score_label.visible = true
	if winner == 0:
		return
	var keep_msg: String = winner_disp.message if same_winner else ""
	winner_disp.show_winner(G.PLAYER_COLORS[_color_of(winner)])
	winner_disp.message = keep_msg
	winner_disp.visible = true
	cl_winner = winner
	var can_write := winner == my_id and not _is_bot(winner)
	msg_row.visible = can_write
	if can_write:
		if not same_winner:
			msg_edit.text = ""
		dir_stack.clear()
		msg_edit.grab_focus()


func _send_winner_msg() -> void:
	var txt := msg_edit.text.strip_edges()
	if txt == "":
		return
	_to_server(&"rpc_winner_msg", [txt])
	msg_edit.text = ""


func _is_bot(id: int) -> bool:
	for e in cl_players:
		if e[0] == id:
			return e[3]
	return id < 0


func _show_overlay(text: String, secs: float) -> void:
	overlay_label.text = text
	overlay.visible = true
	winner_disp.visible = false
	score_label.visible = false
	msg_row.visible = false
	_overlay_token += 1
	var tok := _overlay_token
	if secs > 0.0:
		await get_tree().create_timer(secs).timeout
		if tok == _overlay_token:
			overlay.visible = false


func _refresh_lobby() -> void:
	for c in lobby_list.get_children():
		c.queue_free()
	for e in cl_players:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 10)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(22, 22)
		sw.color = G.PLAYER_COLORS[int(e[2]) % G.PLAYER_COLORS.size()]
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(sw)
		var txt: String = e[1]
		if e[0] == cl_leader:
			txt += "  (líder)"
		if e[0] == my_id:
			txt += "  (você)"
		hb.add_child(_label(txt, 17))
		lobby_list.add_child(hb)
	var is_leader := my_id != 0 and my_id == cl_leader
	leader_box.visible = is_leader
	wait_label.visible = not is_leader
	wait_label.text = "Aguardando o líder iniciar a partida...\nVitórias para vencer: %d • Tempo: %s" % [cl_cfg_wins, _fmt_time(cl_cfg_time)]
	wins_value.text = str(cl_cfg_wins)
	time_value.text = _fmt_time(cl_cfg_time)
	var n := cl_players.size()
	start_btn.text = "INICIAR PARTIDA (%d jogador%s)" % [n, "" if n == 1 else "es"]
	var link := _invite_link()
	link_box.visible = link != ""
	link_edit.text = link


## Link que os outros devem abrir. Usa o endereço da página, a não ser que ela
## tenha sido aberta por localhost (aí usa o IP da rede informado pelo servidor).
func _invite_link() -> String:
	if cl_share_fixed and cl_share_url != "":
		return cl_share_url
	var page := Net.page_url()
	var local := page == "" or page.contains("://localhost") or page.contains("://127.0.0.1")
	if local and cl_share_url != "":
		return cl_share_url
	return page


func _on_copy_pressed() -> void:
	Net.copy_text(link_edit.text)
	copy_btn.text = "Copiado!"
	await get_tree().create_timer(1.5).timeout
	copy_btn.text = "Copiar link"


func _rebuild_chips(ids: Array) -> void:
	chip_ids = ids.duplicate()
	for c in hud_chips.get_children():
		c.queue_free()
	chips.clear()
	for id in ids:
		var hb := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(16, 16)
		sw.color = G.PLAYER_COLORS[_color_of(id)]
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(sw)
		var lb := _label(_name_of(id), 15)
		hb.add_child(lb)
		hud_chips.add_child(hb)
		chips[id] = [hb, lb]


func _update_hud(s: Array) -> void:
	var secs := int(ceil(float(s[0])))
	hud_time.text = "%d:%02d" % [secs / 60, secs % 60]
	hud_time.modulate = Color(1, 0.35, 0.3) if s[6] else Color.WHITE
	var ids: Array = []
	for e in s[4]:
		ids.append(e[0])
	if ids != chip_ids:
		_rebuild_chips(ids)
	var mine = null
	for e in s[4]:
		var id: int = e[0]
		if chips.has(id):
			(chips[id][1] as Label).text = "%s  %d" % [_name_of(id), int(cl_wins.get(id, 0))]
			(chips[id][0] as Control).modulate.a = 1.0 if e[3] else 0.3
		if id == my_id:
			mine = e
	hud_abort.visible = my_id == cl_leader
	if mine == null:
		hud_stats.text = "Assistindo — você entra na próxima partida."
		return
	if not mine[3]:
		hud_stats.text = "Você foi eliminado — assistindo..."
		return
	var parts := PackedStringArray()
	parts.append("Bombas: %d" % mine[8])
	parts.append("Fogo: %d" % mine[9])
	parts.append("Velocidade: %d" % (int(mine[10]) + 1))
	var bits: int = mine[6]
	for i in ABILITY_NAMES.size():
		if (bits & (1 << i)) != 0:
			parts.append(ABILITY_NAMES[i])
	if (bits & 256) != 0:
		parts.append("Colete %ds" % ceili(mine[12]))
	if (bits & 1024) != 0:
		parts.append("Coração")
	if int(mine[7]) != 0:
		parts.append("Caveira: %s %ds" % [G.DISEASE_NAMES[mine[7]], ceili(mine[11])])
	hud_stats.text = "  •  ".join(parts)


func _name_of(id: int) -> String:
	for e in cl_players:
		if e[0] == id:
			return e[1]
	return str(view.names.get(id, "?"))


func _color_of(id: int) -> int:
	for e in cl_players:
		if e[0] == id:
			return int(e[2]) % G.PLAYER_COLORS.size()
	return int(view.colors.get(id, 0)) % G.PLAYER_COLORS.size()


func _scoreboard(w: Dictionary) -> String:
	var ids := w.keys()
	ids.sort_custom(func(a, b): return int(w[a]) > int(w[b]))
	var lines := PackedStringArray()
	for id in ids:
		lines.append("%s: %d" % [_name_of(id), int(w[id])])
	lines.append("(vence quem fizer %d)" % cl_cfg_wins)
	return "\n".join(lines)


func _fmt_time(t: int) -> String:
	return "%d:%02d" % [t / 60, t % 60]


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		player_name = str(cf.get_value("player", "name", ""))


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.save(SETTINGS_PATH)
