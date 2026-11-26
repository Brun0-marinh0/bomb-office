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
##   --room=Nome --room-pass=x   (testes: com --autojoin, entra na sala ou cria se não existir)

const G = preload("res://scripts/g.gd")
const Room = preload("res://scripts/room.gd")
const Codec = preload("res://scripts/snapshot_codec.gd")
const CCTV = preload("res://scripts/cctv.gd")
const ROOM_NAME_MAX := 16
const ROOM_PASS_MAX := 20
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const GameView = preload("res://scripts/game_view.gd")
const TouchControls = preload("res://scripts/touch_controls.gd")
const FullscreenButton = preload("res://scripts/fullscreen_button.gd")
const Music = preload("res://scripts/music.gd")
const SettingsMenu = preload("res://scripts/settings_menu.gd")
const ItemIcon = preload("res://scripts/item_icon.gd")
const LockButton = preload("res://scripts/lock_button.gd")
const HudItemList = preload("res://scripts/item_list.gd")
const WinnerDisplay = preload("res://scripts/winner_display.gd")
const WINNER_MSG_MAX := 20
const SETTINGS_PATH := "user://settings.cfg"
const ABILITY_NAMES := ["Chute", "Luva", "Remoto", "Perfurante", "Linha", "Super Bomba",
	"Atravessa paredes", "Atravessa bombas"]

var args := {}

# ------------------------------------------------------------- estado do servidor
var rooms := {}            # código -> Room (scripts/room.gd)
var peer_room := {}        # id do jogador -> código da sala em que está
var share_url := ""
var share_fixed := false

# ------------------------------------------------------------- estado do cliente
var my_id := 0
var player_name := ""
var cl_players: Array = []
var cl_leader := 0
var cl_state := "lobby"
var cl_cfg_wins := 3
var cl_blocked_items := 0     # itens bloqueados pelo líder (bits 1 << item)
var cl_cfg_time := 180
var cl_roster: Array = []
var cl_wins := {}
var dir_stack: Array = []
var last_dir := Vector2i.ZERO
var auto_started := false
var _snap_count := 0
var cl_map: Array = [PackedByteArray(), PackedByteArray()]   # último mapa recebido [blocos, itens]
var ping_ms := 0
var _stat_secs := 0      # --net-stats
var _stat_snaps := 0
var _stat_bytes := 0
var cl_share_url := ""
var cl_share_fixed := false
var cl_room_name := ""
var cl_room_code := ""
var cl_rooms: Array = []        # [código, nome, tem_senha, jogadores, máximo, em_jogo]
var cl_max_rooms := G.MAX_ROOMS
var invite_code := ""           # ?sala=CÓDIGO do link de convite (tenta entrar uma vez)
var _rooms_first := true        # primeira lista de salas depois de conectar
var _pw_code := ""              # sala que está pedindo senha
var _leaving := false           # saiu da sala e espera a lista de salas

# ------------------------------------------------------------- UI
var view: Node2D
var cctv: CanvasLayer      # filtro de câmera de vigilância em todas as telas (scripts/cctv.gd)
var menu_ui: Control       # telas de menu (ficam por baixo do filtro da câmera)
var boot_label: Label
var ui: Control
var screens := {}
var screen := ""
var name_edit: LineEdit
var url_edit: LineEdit
var url_box: Control
var host_box: Control
var status_label: Label
var rooms_list: VBoxContainer
var rooms_status: Label
var rooms_count: Label
var room_name_edit: LineEdit
var room_pass_edit: LineEdit
var create_btn: Button
var pw_dialog: ConfirmationDialog
var pw_edit: LineEdit
var pw_label: Label
var lobby_title: Control
var lobby_list: VBoxContainer
var link_box: Control
var link_edit: LineEdit
var leader_box: VBoxContainer
var copy_btn: Button
var close_dialog: ConfirmationDialog
var wins_value: Label
var item_rows: Array = []     # [ícone, texto] de cada item da legenda do lobby
var item_locks: Array = []    # cadeado de cada item da legenda
var time_value: Label
var wait_label: Label
var start_btn: Button
var hud_time: Label
var hud_chips: HBoxContainer
var hud_stats: Label
var hud_items: HudItemList
var hud_items_layer: CanvasLayer
var hud_ping: Label
var hud_abort: Button
var overlay: CenterContainer
var overlay_label: Label
var winner_disp: Control
var score_label: Label
var msg_row: HBoxContainer
var msg_edit: LineEdit
var cl_winner := 0
var touch: Control
var fs_btn: Button
var music: Node
var settings: Control
var gear_btn: Button
var music_vol := 0.8
var sfx_vol := 0.8
var show_fs := false        # celular com tela cheia disponível (Android)
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
	SettingsMenu.setup_buses()
	_load_settings()
	SettingsMenu.apply_volumes(music_vol, sfx_vol)
	view = GameView.new()
	view.visible = false
	add_child(view)
	music = Music.new()
	add_child(music)
	music.player.bus = SettingsMenu.BUS_MUSIC
	invite_code = Net.url_param("sala").strip_edges().to_upper()
	_build_ui()
	if args.has("autojoin"):
		_show("menu")      # testes automáticos: sem a inicialização
	else:
		_run_boot()
	var net_timer := Timer.new()
	net_timer.wait_time = 2.0
	net_timer.autostart = true
	net_timer.timeout.connect(_net_tick)
	add_child(net_timer)
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
		var r := _create_room("Teste", "")
		r.test_mode = true
		r.sim_speed = maxi(1, int(args.get("speed", "4")))
		r.cfg_wins = maxi(1, int(args.get("wins", "2")))
		for i in clampi(int(args["test-bots"]), 1, G.MAX_PLAYERS):
			r.add_bot()
		r.start_match()


func _start_server(port: int, dedicated: bool, tls: TLSOptions) -> bool:
	var err := Net.host(port, dedicated, tls)
	if err != OK:
		var msg := "Não foi possível abrir o servidor na porta %d (erro %d)." % [port, err]
		print(msg)
		if status_label != null:
			status_label.text = msg
		return false
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


# =================================================================== SERVIDOR: salas
func _clean_name(s: String) -> String:
	var out := _clean_text(s, 12)
	return out if out != "" else "Jogador"


func _clean_text(s: String, max_len: int) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.unicode_at(0) >= 32:
			out += ch
	return out.substr(0, max_len).strip_edges()


func _room_of(id: int) -> Node:
	return rooms.get(peer_room.get(id, ""), null)


func _new_code() -> String:
	while true:
		var c := ""
		for i in 4:
			c += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not rooms.has(c):
			return c
	return ""


func _create_room(rname: String, pw: String) -> Node:
	var r := Room.new()
	r.main = self
	r.code = _new_code()
	r.room_name = rname
	r.password = pw
	r.name = "Room_" + r.code
	add_child(r)
	rooms[r.code] = r
	r.changed.connect(_push_rooms)
	r.emptied.connect(_delete_room.bind(r.code))
	return r


func _delete_room(code: String) -> void:
	var r: Node = rooms.get(code, null)
	if r == null:
		return
	rooms.erase(code)
	for id in peer_room.keys():
		if peer_room[id] == code:
			peer_room.erase(id)
	r.closed = true
	r.sim.running = false
	print("[servidor] sala \"%s\" excluída (%d/%d salas)" % [r.room_name, rooms.size(), G.MAX_ROOMS])
	# libera depois: a sala pode ter rodadas aguardando um timer
	get_tree().create_timer(20.0).timeout.connect(r.queue_free)
	_push_rooms()


## Lista de salas para quem está fora de sala (a senha nunca sai do servidor).
func _rooms_list() -> Array:
	var list: Array = []
	for c in rooms:
		var r: Node = rooms[c]
		if r.test_mode:
			continue
		list.append([c, r.room_name, r.password != "", r.players_count(), G.MAX_PLAYERS, r.state != "lobby"])
	return list


func _push_rooms(to: int = 0) -> void:
	var list := _rooms_list()
	if to != 0:
		_send_to(to, &"rpc_rooms", [list, G.MAX_ROOMS])
		return
	var targets: Array = multiplayer.get_peers()
	if not Net.is_dedicated:
		targets.append(multiplayer.get_unique_id())   # host que também joga
	for id in targets:
		if not peer_room.has(id):
			_send_to(id, &"rpc_rooms", [list, G.MAX_ROOMS])


func _room_error(id: int, msg: String, code := "", need_pw := false) -> void:
	_send_to(id, &"rpc_room_error", [msg, code, need_pw])


func _server_create_room(id: int, rname: String, pw: String, pname: String) -> void:
	rname = _clean_text(rname, ROOM_NAME_MAX)
	pw = _clean_text(pw, ROOM_PASS_MAX)
	if rname == "":
		_room_error(id, "Dê um nome para a sala.")
		return
	if rooms.size() >= G.MAX_ROOMS:
		_room_error(id, "Limite de %d salas atingido. Entre em uma sala existente." % G.MAX_ROOMS)
		return
	for c in rooms:
		if String(rooms[c].room_name).to_lower() == rname.to_lower():
			_room_error(id, "Já existe uma sala chamada \"%s\"." % rname)
			return
	_server_leave(id)
	var r := _create_room(rname, pw)
	print("[servidor] sala \"%s\" criada%s, código %s (%d/%d salas)" % [rname, " com senha" if pw != "" else "", r.code, rooms.size(), G.MAX_ROOMS])
	peer_room[id] = r.code
	r.join(id, pname)


func _server_join_room(id: int, code: String, pw: String, pname: String) -> void:
	code = code.strip_edges().to_upper()
	var r: Node = rooms.get(code, null)
	if r == null or r.test_mode:
		_room_error(id, "Essa sala não existe mais.", code)
		_push_rooms(id)
		return
	if peer_room.get(id, "") == code:
		r.push_lobby()
		return
	if r.password != "" and pw != r.password:
		_room_error(id, "Senha incorreta." if pw != "" else "A sala \"%s\" tem senha." % r.room_name, code, true)
		return
	if r.is_full():
		_room_error(id, "A sala \"%s\" está cheia (máximo de %d jogadores)." % [r.room_name, G.MAX_PLAYERS], code)
		return
	_server_leave(id)
	peer_room[id] = code
	if not r.join(id, pname):
		peer_room.erase(id)
		_room_error(id, "A sala \"%s\" está cheia." % r.room_name, code)


func _server_leave(id: int) -> void:
	var r := _room_of(id)
	peer_room.erase(id)
	if r != null:
		r.remove_member(id)


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


func _on_peer_disconnected(id: int) -> void:
	if Net.is_server:
		_server_leave(id)


# =================================================================== RPC: cliente -> servidor
@rpc("any_peer", "reliable")
func rpc_list_rooms() -> void:
	if Net.is_server:
		_push_rooms(_sender())


@rpc("any_peer", "reliable")
func rpc_create_room(rname: String, pw: String, pname: String) -> void:
	if Net.is_server:
		_server_create_room(_sender(), rname, pw, pname)


@rpc("any_peer", "reliable")
func rpc_join_room(code: String, pw: String, pname: String) -> void:
	if Net.is_server:
		_server_join_room(_sender(), code, pw, pname)


@rpc("any_peer", "reliable")
func rpc_leave_room() -> void:
	if Net.is_server:
		var id := _sender()
		_server_leave(id)
		_push_rooms(id)


@rpc("any_peer", "reliable")
func rpc_cfg(w: int, t: int) -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.cfg(_sender(), w, t)


@rpc("any_peer", "reliable")
func rpc_toggle_item(item: int) -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.toggle_item(_sender(), item)


@rpc("any_peer", "reliable")
func rpc_bots(add: bool) -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.bots(_sender(), add)


@rpc("any_peer", "reliable")
func rpc_start() -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.start(_sender())


@rpc("any_peer", "reliable")
func rpc_winner_msg(text: String) -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.winner_msg(_sender(), text)


## Botão "Encerrar sala" do líder: todos voltam para a lista de salas e a sala é excluída.
@rpc("any_peer", "reliable")
func rpc_close_room() -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null and _sender() == r.leader() and r.state == "lobby":
		r.close("A sala foi encerrada pelo líder.")
		_delete_room(r.code)


@rpc("any_peer", "reliable")
func rpc_abort() -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.abort(_sender())


@rpc("any_peer", "reliable")
func rpc_input(x: int, y: int) -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.input(_sender(), Vector2i(clampi(x, -1, 1), clampi(y, -1, 1)))


@rpc("any_peer", "reliable")
func rpc_bomb() -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.bomb(_sender())


@rpc("any_peer", "reliable")
func rpc_action() -> void:
	var r: Node = _room_of(_sender()) if Net.is_server else null
	if r != null:
		r.action(_sender())


# =================================================================== RPC: servidor -> clientes
@rpc("authority", "reliable")
func rpc_lobby(list: Array, leader: int, st: String, w: int, t: int, share: String, share_fixed: bool,
		room_name: String, code: String, blocked: int) -> void:
	if Net.is_dedicated or view == null or _leaving:
		return
	cl_room_name = room_name
	cctv.set_room(room_name)
	cl_room_code = code
	cl_share_url = share
	cl_share_fixed = share_fixed
	cl_players = list
	cl_leader = leader
	cl_cfg_wins = w
	cl_cfg_time = t
	cl_blocked_items = blocked
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


## Lista de salas (só chega para quem está fora de sala).
@rpc("authority", "reliable")
func rpc_rooms(list: Array, max_rooms: int) -> void:
	if Net.is_dedicated or view == null:
		return
	_leaving = false
	cl_rooms = list
	cl_max_rooms = max_rooms
	if screen == "menu":
		_show("rooms")
		rooms_status.text = ""
	_refresh_rooms()
	if not _rooms_first:
		return
	_rooms_first = false
	if invite_code != "":
		# link de convite: entra direto na sala (pede a senha se tiver)
		var code := invite_code
		invite_code = ""
		var e := _room_entry(code)
		if e.is_empty():
			rooms_status.text = "A sala do convite não existe mais. Escolha outra ou crie uma."
		else:
			_on_room_pressed(e)
	elif args.has("autojoin"):
		# teste: entra na sala --room (ou cria, se não existir)
		var rname := str(args.get("room", "Teste"))
		for e in list:
			if String(e[1]).to_lower() == rname.to_lower():
				_to_server(&"rpc_join_room", [e[0], str(args.get("room-pass", "")), player_name])
				return
		_to_server(&"rpc_create_room", [rname, str(args.get("room-pass", "")), player_name])


@rpc("authority", "reliable")
func rpc_room_error(msg: String, code: String, need_pw: bool) -> void:
	if Net.is_dedicated or view == null:
		return
	if screen != "rooms":
		_show("rooms")
	rooms_status.text = msg
	if args.has("autojoin"):
		print("[cliente] erro de sala: %s" % msg)
	if need_pw and code != "":
		_ask_password(code, msg)


## Saiu da sala por ordem do servidor (líder encerrou a sala): volta para a lista.
@rpc("authority", "reliable")
func rpc_left_room(msg: String) -> void:
	if view == null:
		return
	_reset_room_state()
	_show("rooms")
	rooms_status.text = msg
	if args.has("autojoin"):
		print("[cliente] removido da sala: %s" % msg)
		if args.has("autoquit"):
			get_tree().quit(0)


@rpc("authority", "reliable")
func rpc_round_start(n: int, ids: Array, w: Dictionary) -> void:
	if Net.is_dedicated or view == null or _leaving:
		return
	cl_roster = ids
	cl_wins = w
	cl_state = "round"
	cl_map = [PackedByteArray(), PackedByteArray()]
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
	cctv.round_cut(n)
	if args.has("autojoin"):
		print("[cliente] rodada %d começou" % n)
	if args.has("test-suicide"):   # teste: solta uma bomba e fica parado
		await get_tree().create_timer(1.0).timeout
		_to_server(&"rpc_bomb")


## Snapshot compacto (scripts/snapshot_codec.gd). O mapa só vem quando muda: fica em cl_map.
@rpc("authority", "unreliable_ordered")
func rpc_snapshot(data: PackedByteArray) -> void:
	if Net.is_dedicated or view == null or _leaving:
		return
	_snap_count += 1
	_stat_snaps += 1
	_stat_bytes += data.size()
	var r := Codec.decode(data, cl_map)
	if r.is_empty():
		return
	view.push_snapshot(r[0], r[1])
	_update_hud(r[1])


## Ping: o cliente manda o próprio relógio e o servidor devolve só para ele.
@rpc("any_peer", "unreliable")
func rpc_ping(ms: int) -> void:
	if Net.is_server:
		_send_to(_sender(), &"rpc_pong", [ms])


@rpc("authority", "unreliable")
func rpc_pong(ms: int) -> void:
	if view == null:
		return
	ping_ms = Time.get_ticks_msec() - ms
	hud_ping.text = "ping %d ms" % ping_ms
	hud_ping.modulate = Color(0.5, 1, 0.5) if ping_ms < 80 else (Color(1, 0.9, 0.3) if ping_ms < 160 else Color(1, 0.4, 0.35))


func _net_tick() -> void:
	if Net.is_server or multiplayer.multiplayer_peer == null \
			or multiplayer.multiplayer_peer is OfflineMultiplayerPeer \
			or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		hud_ping.text = ""
		return
	_to_server(&"rpc_ping", [Time.get_ticks_msec()])
	_stat_secs += 2
	if args.has("net-stats") and _stat_secs >= 6:
		print("[rede] %.1f snapshots/s • %d B em média • buffer %d • engasgos %d • ping %d ms" % [
			_stat_snaps / float(_stat_secs), _stat_bytes / maxi(1, _stat_snaps),
			view._buf.size(), view.underruns, ping_ms])
		_stat_secs = 0
		_stat_snaps = 0
		_stat_bytes = 0


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
	_rooms_first = true
	_to_server(&"rpc_list_rooms")
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
	_reset_room_state()
	_leaving = false
	_show("menu")
	status_label.text = "A conexão com o servidor caiu."
	if args.has("autoquit"):
		get_tree().quit(1)


func _on_join_pressed() -> void:
	if show_fs:
		Net.set_fullscreen(true)   # celular: some a barra de endereço ao entrar
	player_name = _clean_name(name_edit.text)
	_save_settings()
	_connect_to(url_edit.text.strip_edges())


func _on_host_pressed() -> void:
	player_name = _clean_name(name_edit.text)
	_save_settings()
	if _start_server(G.DEFAULT_PORT, false, null):
		my_id = 1
		_rooms_first = true
		_to_server(&"rpc_list_rooms")


func _on_dedicated_pressed() -> void:
	if _start_server(G.DEFAULT_PORT, true, null):
		host_box.visible = false
		status_label.text = "Servidor dedicado rodando na porta %d.\nAbra o jogo em outra janela/navegador para jogar." % G.DEFAULT_PORT


## "SAIR" da sala de espera: volta para a lista de salas (continua conectado).
func _on_leave_room_pressed() -> void:
	_reset_room_state()
	_leaving = true   # ignora mensagens da sala que ainda estejam a caminho
	_to_server(&"rpc_leave_room")
	_show("rooms")
	rooms_status.text = ""


func _reset_room_state() -> void:
	cl_players = []
	cl_roster = []
	cl_leader = 0
	cl_room_name = ""
	cl_room_code = ""
	cl_state = "lobby"
	auto_started = false
	if view != null:
		view.reset()


## "VOLTAR" na lista de salas: desconecta e volta ao menu.
func _on_back_pressed() -> void:
	Net.leave()
	for c in rooms:
		rooms[c].queue_free()
	rooms.clear()
	peer_room.clear()
	_reset_room_state()
	_leaving = false
	my_id = 0
	host_box.visible = not OS.has_feature("web")
	_show("menu")
	status_label.text = ""


# =================================================================== CLIENTE: entrada
func _physics_process(_delta: float) -> void:
	# (a simulação de cada sala roda em room.gd; aqui só o envio dos comandos)
	if view != null and screen == "game" and my_id in cl_roster:
		_send_input()


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
	if settings != null and settings.visible:
		return   # painel de configurações aberto: teclado não controla o jogador
	if screen == "boot" and event is InputEventKey and event.pressed:
		_end_boot()   # qualquer tecla pula a inicialização
		return
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
	# painel "SEUS ITENS" encostado no lado direito da arena, alinhado com o topo dela.
	# Em tela estreita (sem sobra) fica por cima da arena, encostado na borda da tela.
	var panel_w := clampf(vs.x - (view.position.x + map.x * s) - 10.0, 170.0, 280.0)
	var x0 := minf(view.position.x + map.x * s + 6.0, vs.x - panel_w - 10.0)
	hud_items.offset_left = x0
	hud_items.offset_right = x0 + panel_w
	hud_items.offset_top = view.position.y


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
	# camadas: 0 arena | 1 telas de menu | 2 câmera de vigilância (filtro + OSD, por cima da
	# arena e dos menus) | 3 UI que fica nítida por cima do filtro (HUD, modal, configurações)
	var menu_layer := CanvasLayer.new()
	menu_layer.layer = 1
	add_child(menu_layer)
	menu_ui = Control.new()
	menu_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_layer.add_child(menu_ui)
	cctv = CCTV.new()
	cctv.layer = 2
	add_child(cctv)
	view.boomed.connect(func(): cctv.glitch())
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font_size = 18
	ui.theme = th
	menu_ui.theme = th
	layer.add_child(ui)
	show_fs = Net.is_touch() and Net.fullscreen_supported()
	_build_boot()
	_build_menu()
	_build_rooms()
	_build_lobby()
	_build_hud()
	_build_overlay()
	touch = TouchControls.new()
	touch.visible = false
	ui.add_child(touch)
	touch.bomb_pressed.connect(func(): _to_server(&"rpc_bomb"))
	touch.action_pressed.connect(func(): _to_server(&"rpc_action"))
	fs_btn = FullscreenButton.new()
	fs_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	fs_btn.offset_left = -FullscreenButton.SIZE - 10
	fs_btn.offset_right = -10
	fs_btn.offset_top = 8
	fs_btn.offset_bottom = 8 + FullscreenButton.SIZE
	fs_btn.visible = show_fs
	ui.add_child(fs_btn)
	# engrenagem: volume da música e dos efeitos (fica à esquerda do botão de tela cheia)
	var gs: float = SettingsMenu.HudIconButton.SIZE
	var right := -10.0 - (FullscreenButton.SIZE + 10.0 if show_fs else 0.0)
	gear_btn = SettingsMenu.GearButton.new()
	gear_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	gear_btn.offset_left = right - gs
	gear_btn.offset_right = right
	gear_btn.offset_top = 8
	gear_btn.offset_bottom = 8 + gs
	ui.add_child(gear_btn)
	settings = SettingsMenu.new()
	settings.music_vol = music_vol
	settings.sfx_vol = sfx_vol
	settings.test_sfx = func(): view.play_boom()
	ui.add_child(settings)
	gear_btn.pressed.connect(settings.open)
	settings.visibility_changed.connect(func():
		# com o painel aberto, os controles de toque não podem mover o jogador
		touch.visible = screen == "game" and DisplayServer.is_touchscreen_available() and not settings.visible)
	settings.changed.connect(func(m: float, f: float):
		music_vol = m
		sfx_vol = f
		_save_settings())


## Inicialização do "sistema de câmeras" ao abrir o jogo (clique/toque/tecla pula).
func _build_boot() -> void:
	var root := ColorRect.new()
	root.color = Color(0.01, 0.012, 0.012)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_ui.add_child(root)
	screens["boot"] = root
	boot_label = MenuStyle.label("", 22, MenuStyle.AMBER, 0)
	boot_label.position = Vector2(80, 70)
	root.add_child(boot_label)
	root.gui_input.connect(func(e):
		if (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed:
			_end_boot())


func _run_boot() -> void:
	_show("boot")
	var lines := ["BOMBOFFICE DVR v1.0", "", "INICIALIZANDO SISTEMA DE CÂMERAS..."]
	for i in 4:
		lines.append("CAM %02d .......... OK" % (i + 1))
	lines.append("")
	lines.append("● GRAVANDO")
	var shown := PackedStringArray()
	for l in lines:
		if screen != "boot":
			return
		shown.append(l)
		boot_label.text = "\n".join(shown)
		await get_tree().create_timer(0.16 if l != "" else 0.05).timeout
	await get_tree().create_timer(0.45).timeout
	_end_boot()


func _end_boot() -> void:
	if screen == "boot":
		_show("menu")


func _build_menu() -> void:
	# central de monitoramento: mosaico de câmeras, painel de acesso (scripts/menu_style.gd)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_ui.add_child(root)
	screens["menu"] = root
	root.add_child(MenuStyle.CameraWall.new())
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vb)
	var title := MenuStyle.Title.new()
	title.custom_minimum_size.x = 900
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "SISTEMA DE MONITORAMENTO  •  BATALHA DE BOMBAS  •  2 A 8 JOGADORES"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.style_label(sub, 18, MenuStyle.TEXT)
	vb.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size.y = 8
	vb.add_child(gap)
	# painel de "login" do DVR
	var login := MenuStyle.panel(MenuStyle.MUTED)
	login.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(login)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.custom_minimum_size.x = 440
	login.add_child(col)
	col.add_child(MenuStyle.label("▸ ACESSO AO SISTEMA", 18, MenuStyle.AMBER))
	var nl := Label.new()
	nl.text = "SEU NOME"
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.style_label(nl, 18, MenuStyle.MUTED)
	col.add_child(nl)
	name_edit = LineEdit.new()
	name_edit.max_length = 12
	name_edit.text = player_name
	name_edit.placeholder_text = "digite seu nome"
	name_edit.text_submitted.connect(func(_t): _on_join_pressed())
	MenuStyle.style_line_edit(name_edit)
	col.add_child(name_edit)
	var ub := VBoxContainer.new()
	var sl := Label.new()
	sl.text = "SERVIDOR"
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.style_label(sl, 15, MenuStyle.MUTED)
	ub.add_child(sl)
	url_edit = LineEdit.new()
	url_edit.text = Net.default_url()
	MenuStyle.style_line_edit(url_edit, 18)
	ub.add_child(url_edit)
	url_box = ub
	url_box.visible = not Net.url_has_server_param()
	col.add_child(url_box)
	var enter := MenuStyle.DvrButton.new("ENTRAR", 34, true)
	enter.pressed.connect(_on_join_pressed)
	col.add_child(enter)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 30)
	var h1 := MenuStyle.DvrButton.new("HOSPEDAR E JOGAR", 24)
	h1.pressed.connect(_on_host_pressed)
	var h2 := MenuStyle.DvrButton.new("SERVIDOR DEDICADO", 24)
	h2.pressed.connect(_on_dedicated_pressed)
	hb.add_child(h1)
	hb.add_child(h2)
	host_box = hb
	host_box.visible = not OS.has_feature("web")
	col.add_child(host_box)
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.x = 440
	MenuStyle.style_label(status_label, 16, MenuStyle.AMBER)
	col.add_child(status_label)
	var help := Label.new()
	help.text = "Teclado: Setas/WASD movem • Espaço solta bomba • Shift/E ação\nCelular: direcional à esquerda, botões à direita"
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.style_label(help, 15, MenuStyle.TEXT)
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	help.offset_top = -56
	help.offset_bottom = -10
	root.add_child(help)


## Tela de salas: entrar em uma sala da lista ou criar uma nova (nome + senha opcional).
func _build_rooms() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_ui.add_child(root)
	screens["rooms"] = root
	root.add_child(MenuStyle.CameraWall.new())
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	var title := MenuStyle.Title.new()
	title.text = "SALAS"
	title.font_size = 58
	title.custom_minimum_size.x = 960
	vb.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	vb.add_child(cols)

	# ---- esquerda: salas criadas
	var lp := MenuStyle.panel(MenuStyle.AMBER)
	lp.custom_minimum_size.x = 560
	cols.add_child(lp)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	lp.add_child(left)
	left.add_child(MenuStyle.label("ENTRAR EM UMA SALA", 20, MenuStyle.AMBER))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	MenuStyle.style_scroll(scroll)
	left.add_child(scroll)
	rooms_list = VBoxContainer.new()
	rooms_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rooms_list.add_theme_constant_override("separation", 8)
	scroll.add_child(rooms_list)

	# ---- direita: criar sala
	var rp := MenuStyle.panel(MenuStyle.MUTED)
	rp.custom_minimum_size.x = 380
	cols.add_child(rp)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	rp.add_child(right)
	right.add_child(MenuStyle.label("CRIAR SALA", 20, MenuStyle.AMBER))
	right.add_child(MenuStyle.label("NOME DA SALA", 16, MenuStyle.MUTED, 4))
	room_name_edit = LineEdit.new()
	room_name_edit.max_length = ROOM_NAME_MAX
	room_name_edit.placeholder_text = "ex.: Sala do TI"
	MenuStyle.style_line_edit(room_name_edit, 20)
	right.add_child(room_name_edit)
	right.add_child(MenuStyle.label("SENHA (OPCIONAL)", 16, MenuStyle.MUTED, 4))
	room_pass_edit = LineEdit.new()
	room_pass_edit.max_length = ROOM_PASS_MAX
	room_pass_edit.secret = true
	room_pass_edit.placeholder_text = "deixe vazio para sala aberta"
	MenuStyle.style_line_edit(room_pass_edit, 20)
	right.add_child(room_pass_edit)
	room_name_edit.text_submitted.connect(func(_t): _on_create_pressed())
	room_pass_edit.text_submitted.connect(func(_t): _on_create_pressed())
	var gap := Control.new()
	gap.custom_minimum_size.y = 6
	right.add_child(gap)
	create_btn = MenuStyle.DvrButton.new("CRIAR SALA", 28, true)
	create_btn.pressed.connect(_on_create_pressed)
	right.add_child(create_btn)
	rooms_count = MenuStyle.label("", 16, Color(1, 1, 1, 0.85), 4)
	rooms_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(rooms_count)

	rooms_status = MenuStyle.label("", 17, MenuStyle.AMBER, 5)
	rooms_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rooms_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rooms_status.custom_minimum_size.x = 900
	vb.add_child(rooms_status)
	var back := MenuStyle.DvrButton.new("VOLTAR", 22)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_on_back_pressed)
	vb.add_child(back)

	# diálogo de senha (sala protegida)
	pw_dialog = ConfirmationDialog.new()
	pw_dialog.title = "Sala com senha"
	pw_dialog.ok_button_text = "Entrar"
	pw_dialog.cancel_button_text = "Cancelar"
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 8)
	pw_label = Label.new()
	pv.add_child(pw_label)
	pw_edit = LineEdit.new()
	pw_edit.secret = true
	pw_edit.max_length = ROOM_PASS_MAX
	pw_edit.custom_minimum_size.x = 320
	pv.add_child(pw_edit)
	pw_dialog.add_child(pv)
	pw_dialog.register_text_enter(pw_edit)
	pw_dialog.confirmed.connect(func():
		_to_server(&"rpc_join_room", [_pw_code, pw_edit.text, player_name]))
	pw_dialog.theme = MenuStyle.dialog_theme()
	ui.add_child(pw_dialog)


func _room_entry(code: String) -> Array:
	for e in cl_rooms:
		if e[0] == code:
			return e
	return []


func _refresh_rooms() -> void:
	for c in rooms_list.get_children():
		c.queue_free()
	if cl_rooms.is_empty():
		var l := MenuStyle.label("NENHUMA SALA CRIADA AINDA.\nCRIE A SUA AO LADO!", 18, Color(1, 1, 1, 0.75), 4)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size.y = 120
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rooms_list.add_child(l)
	for e in cl_rooms:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 12)
		var info := VBoxContainer.new()
		info.add_theme_constant_override("separation", 0)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_child(MenuStyle.label(String(e[1]).to_upper(), 20))
		var parts := PackedStringArray()
		parts.append("%d/%d JOGADORES" % [int(e[3]), int(e[4])])
		parts.append("EM JOGO" if e[5] else "ESPERANDO")
		if e[2]:
			parts.append("COM SENHA")
		info.add_child(MenuStyle.label("  •  ".join(parts), 14,
			MenuStyle.REC if e[5] else MenuStyle.AMBER, 3))
		hb.add_child(info)
		var btn := MenuStyle.DvrButton.new("ENTRAR", 22, false, MenuStyle.AMBER)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(_on_room_pressed.bind(e))
		btn.disabled = int(e[3]) >= int(e[4]) and e[5]
		hb.add_child(btn)
		rooms_list.add_child(hb)
	rooms_count.text = "SALAS CRIADAS: %d/%d" % [cl_rooms.size(), cl_max_rooms]
	create_btn.disabled = cl_rooms.size() >= cl_max_rooms
	create_btn.modulate.a = 0.4 if create_btn.disabled else 1.0


func _on_room_pressed(e: Array) -> void:
	rooms_status.text = ""
	if e[2]:
		_ask_password(e[0], "")
	else:
		_to_server(&"rpc_join_room", [e[0], "", player_name])


func _ask_password(code: String, msg: String) -> void:
	_pw_code = code
	var e := _room_entry(code)
	var rname: String = e[1] if not e.is_empty() else code
	var txt := "Digite a senha da sala \"%s\":" % rname
	if msg.begins_with("Senha incorreta"):
		txt = "Senha incorreta. Tente de novo:"
	pw_label.text = txt
	pw_edit.text = ""
	pw_dialog.popup_centered()
	pw_edit.grab_focus()


func _on_create_pressed() -> void:
	var rname := room_name_edit.text.strip_edges()
	if rname == "":
		rooms_status.text = "Dê um nome para a sala."
		room_name_edit.grab_focus()
		return
	rooms_status.text = ""
	_to_server(&"rpc_create_room", [rname, room_pass_edit.text, player_name])
	room_pass_edit.text = ""


func _build_lobby() -> void:
	# mesmo visual neon do menu (scripts/menu_style.gd)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_ui.add_child(root)
	screens["lobby"] = root
	root.add_child(MenuStyle.CameraWall.new())
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	var title := MenuStyle.Title.new()
	title.text = "SALA DE ESPERA"
	title.font_size = 58
	title.custom_minimum_size.x = 960
	vb.add_child(title)
	lobby_title = title

	var lb := HBoxContainer.new()
	lb.add_theme_constant_override("separation", 12)
	lb.add_child(MenuStyle.label("CONVIDE PELO LINK", 17, MenuStyle.MUTED))
	link_edit = LineEdit.new()
	link_edit.editable = false
	link_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MenuStyle.style_line_edit(link_edit, 17)
	lb.add_child(link_edit)
	copy_btn = MenuStyle.DvrButton.new("COPIAR LINK", 20)
	copy_btn.pressed.connect(_on_copy_pressed)
	lb.add_child(copy_btn)
	link_box = lb
	vb.add_child(link_box)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	vb.add_child(cols)

	# ---- esquerda: jogadores + configuração do líder
	var lp := MenuStyle.panel(MenuStyle.AMBER)
	lp.custom_minimum_size.x = 430
	cols.add_child(lp)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	lp.add_child(left)
	left.add_child(MenuStyle.label("JOGADORES  (MÁX. %d)" % G.MAX_PLAYERS, 20, MenuStyle.AMBER))
	lobby_list = VBoxContainer.new()
	lobby_list.add_theme_constant_override("separation", 6)
	left.add_child(lobby_list)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 6
	left.add_child(spacer)

	leader_box = VBoxContainer.new()
	leader_box.add_theme_constant_override("separation", 4)
	left.add_child(leader_box)
	var cfg_row := func(text: String, minus: Callable, plus: Callable) -> Label:
		var row := HBoxContainer.new()
		var l := MenuStyle.label(text, 18, Color.WHITE, 5)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var bm := MenuStyle.DvrButton.new(" - ", 24)
		bm.pressed.connect(minus)
		row.add_child(bm)
		var v := MenuStyle.label("", 22, MenuStyle.AMBER)
		v.custom_minimum_size.x = 64
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(v)
		var bp := MenuStyle.DvrButton.new(" + ", 24)
		bp.pressed.connect(plus)
		row.add_child(bp)
		leader_box.add_child(row)
		return v
	wins_value = cfg_row.call("VITÓRIAS PARA VENCER",
		func(): _to_server(&"rpc_cfg", [cl_cfg_wins - 1, cl_cfg_time]),
		func(): _to_server(&"rpc_cfg", [cl_cfg_wins + 1, cl_cfg_time]))
	time_value = cfg_row.call("TEMPO DA RODADA",
		func(): _to_server(&"rpc_cfg", [cl_cfg_wins, cl_cfg_time - 30]),
		func(): _to_server(&"rpc_cfg", [cl_cfg_wins, cl_cfg_time + 30]))
	var rb := HBoxContainer.new()
	rb.alignment = BoxContainer.ALIGNMENT_CENTER
	rb.add_theme_constant_override("separation", 40)
	var add_bot := MenuStyle.DvrButton.new("+ BOT", 24)
	add_bot.pressed.connect(func(): _to_server(&"rpc_bots", [true]))
	rb.add_child(add_bot)
	var del_bot := MenuStyle.DvrButton.new("- BOT", 24)
	del_bot.pressed.connect(func(): _to_server(&"rpc_bots", [false]))
	rb.add_child(del_bot)
	leader_box.add_child(rb)
	start_btn = MenuStyle.DvrButton.new("INICIAR PARTIDA", 28, true)
	start_btn.pressed.connect(func(): _to_server(&"rpc_start"))
	leader_box.add_child(start_btn)
	var close_btn := MenuStyle.DvrButton.new("ENCERRAR SALA (EXPULSAR TODOS)", 17, false, MenuStyle.REC)
	close_btn.pressed.connect(func(): close_dialog.popup_centered())
	leader_box.add_child(close_btn)
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Encerrar sala"
	close_dialog.dialog_text = "Todos os jogadores voltam para a lista de salas e esta sala será excluída.\nDeseja continuar?"
	close_dialog.ok_button_text = "Encerrar"
	close_dialog.cancel_button_text = "Cancelar"
	close_dialog.confirmed.connect(func(): _to_server(&"rpc_close_room"))
	close_dialog.theme = MenuStyle.dialog_theme()
	ui.add_child(close_dialog)
	wait_label = MenuStyle.label("", 18, Color(1, 1, 1, 0.85), 5)
	wait_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(wait_label)
	var leave := MenuStyle.DvrButton.new("SAIR", 22)
	leave.pressed.connect(_on_leave_room_pressed)
	left.add_child(leave)

	# ---- direita: legenda dos itens
	var rp := MenuStyle.panel(MenuStyle.MUTED)
	rp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(rp)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	rp.add_child(right)
	right.add_child(MenuStyle.label("ITENS  (ESCONDIDOS NAS MESAS)", 20, MenuStyle.AMBER))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(470, 340)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	MenuStyle.style_scroll(scroll)
	right.add_child(scroll)
	var items_vb := VBoxContainer.new()
	items_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_vb.add_theme_constant_override("separation", 8)
	scroll.add_child(items_vb)
	item_rows.clear()
	item_locks.clear()
	for i in range(1, G.ITEM_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var icon := ItemIcon.new()
		icon.item = i
		row.add_child(icon)
		item_rows.append(icon)
		var txt := VBoxContainer.new()
		txt.add_theme_constant_override("separation", 0)
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		txt.add_child(MenuStyle.label(String(G.ITEM_NAMES[i]).to_upper(), 16, MenuStyle.AMBER, 4))
		var d := MenuStyle.label(G.ITEM_DESCS[i], 14, Color(1, 1, 1, 0.9), 3)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size.x = 340
		txt.add_child(d)
		row.add_child(txt)
		item_rows.append(txt)
		# cadeado: o líder bloqueia/libera o item para as partidas desta sala
		var lock := LockButton.new()
		var it := i
		lock.pressed.connect(func(): _to_server(&"rpc_toggle_item", [it]))
		row.add_child(lock)
		item_locks.append(lock)
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
	top.offset_right = -12 - (SettingsMenu.HudIconButton.SIZE + 10) * 2 - (FullscreenButton.SIZE + 10 if show_fs else 0)
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
	# encerrar partida (só o líder): ícone de sair à esquerda da engrenagem, no mesmo estilo
	var gs: float = SettingsMenu.HudIconButton.SIZE
	var right := -10.0 - (gs + 10.0) - (FullscreenButton.SIZE + 10.0 if show_fs else 0.0)
	hud_abort = SettingsMenu.ExitButton.new()
	hud_abort.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	hud_abort.offset_left = right - gs
	hud_abort.offset_right = right
	hud_abort.offset_top = 8
	hud_abort.offset_bottom = 8 + gs
	hud_abort.pressed.connect(func(): _to_server(&"rpc_abort"))
	hud.add_child(hud_abort)
	hud_stats = _label("", 16)
	hud_stats.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hud_stats.offset_top = -34
	hud_stats.offset_left = 12
	hud_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(hud_stats)
	hud_items = HudItemList.new()
	hud_items.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud_items.visible = false
	# fica abaixo do filtro de câmera (camada 2), para entrar no olho-de-peixe junto com a arena
	hud_items_layer = CanvasLayer.new()
	hud_items_layer.layer = 1
	hud_items_layer.visible = false
	add_child(hud_items_layer)
	hud_items_layer.add_child(hud_items)
	hud_ping = _label("", 13)
	hud_ping.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	hud_ping.offset_left = -110
	hud_ping.offset_top = -26
	hud_ping.offset_right = -12
	hud_ping.offset_bottom = -6
	hud_ping.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud.add_child(hud_ping)


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
	var changed := which != screen
	screen = which
	for k in screens:
		screens[k].visible = (k == which)
	view.visible = which == "game"
	hud_items_layer.visible = which == "game"
	cctv.set_screen(which)
	if changed and which != "boot":
		cctv.screen_cut()    # troca de tela: a câmera falha por um instante
	touch.visible = which == "game" and DisplayServer.is_touchscreen_available() and not settings.visible
	gear_btn.visible = which != "boot"
	if which == "game":
		music.fade_out()     # a partida começou: a música some aos poucos
	elif which != "boot":
		music.play_intro()   # menu / sala de espera: sorteia e toca em loop
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
		var sw := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = G.PLAYER_COLORS[int(e[2]) % G.PLAYER_COLORS.size()]
		sb.border_color = MenuStyle.INK
		sb.set_border_width_all(2)
		sb.skew = Vector2(0.25, 0)
		sw.add_theme_stylebox_override("panel", sb)
		sw.custom_minimum_size = Vector2(26, 22)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(sw)
		hb.add_child(MenuStyle.label(String(e[1]).to_upper(), 20))
		if e[0] == cl_leader:
			hb.add_child(MenuStyle.label("LÍDER", 15, MenuStyle.AMBER, 4))
		if e[0] == my_id:
			hb.add_child(MenuStyle.label("VOCÊ", 15, MenuStyle.TEXT, 4))
		lobby_list.add_child(hb)
	var is_leader := my_id != 0 and my_id == cl_leader
	leader_box.visible = is_leader
	wait_label.visible = not is_leader
	wait_label.text = "AGUARDANDO O LÍDER INICIAR A PARTIDA...\nVitórias para vencer: %d  •  Tempo: %s" % [cl_cfg_wins, _fmt_time(cl_cfg_time)]
	wins_value.text = str(cl_cfg_wins)
	# itens bloqueados: ícone e texto apagados, cadeado fechado (só o líder pode mexer)
	for i in range(1, G.ITEM_COUNT):
		var off := (cl_blocked_items & (1 << i)) != 0
		var a := 0.3 if off else 1.0
		(item_rows[(i - 1) * 2] as Control).modulate.a = a
		(item_rows[(i - 1) * 2 + 1] as Control).modulate.a = a
		var lock: LockButton = item_locks[i - 1]
		lock.locked = off
		lock.disabled = not is_leader
		lock.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if is_leader else Control.CURSOR_ARROW
	time_value.text = _fmt_time(cl_cfg_time)
	var n := cl_players.size()
	start_btn.text = "INICIAR PARTIDA (%d JOGADOR%s)" % [n, "" if n == 1 else "ES"]
	lobby_title.text = "SALA " + cl_room_name.to_upper() if cl_room_name != "" else "SALA DE ESPERA"
	var link := _invite_link()
	link_box.visible = link != ""
	link_edit.text = link


## Link que os outros devem abrir (já entra direto nesta sala: ?sala=CÓDIGO).
## Usa o endereço da página, a não ser que ela tenha sido aberta por localhost
## (aí usa o IP da rede informado pelo servidor).
func _invite_link() -> String:
	var base := Net.page_url()
	var local := base == "" or base.contains("://localhost") or base.contains("://127.0.0.1")
	if cl_share_fixed and cl_share_url != "":
		base = cl_share_url
	elif local and cl_share_url != "":
		base = cl_share_url
	if base == "":
		return ""
	return _with_param(base, "sala", cl_room_code) if cl_room_code != "" else base


## Troca/acrescenta ?chave=valor numa URL, mantendo os outros parâmetros (ex.: ?server=).
func _with_param(url: String, key: String, val: String) -> String:
	var h := url.find("#")
	if h >= 0:
		url = url.substr(0, h)
	var q := url.find("?")
	var base := url if q < 0 else url.substr(0, q)
	var parts := PackedStringArray()
	if q >= 0:
		for p in url.substr(q + 1).split("&", false):
			if not p.begins_with(key + "="):
				parts.append(p)
	parts.append("%s=%s" % [key, val.uri_encode()])
	return base + "?" + "&".join(parts)


func _on_copy_pressed() -> void:
	Net.copy_text(link_edit.text)
	copy_btn.text = "COPIADO!"
	await get_tree().create_timer(1.5).timeout
	copy_btn.text = "COPIAR LINK"


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
		hud_items.visible = false
		hud_items.clear_now()
		return
	hud_items.visible = true
	if not mine[3]:
		hud_stats.text = "Você foi eliminado — assistindo..."
		hud_items.set_entries([])
		return
	hud_stats.text = ""
	# lista de itens coletados (cada linha aparece/some com animação no painel)
	var list: Array = []
	if int(mine[8]) > G.START_BOMBS:
		list.append({key = "bombs", text = "Bombas +%d" % (int(mine[8]) - G.START_BOMBS)})
	if int(mine[9]) >= G.MAX_FIRE:
		list.append({key = "fire", text = "Fogo máximo"})
	elif int(mine[9]) > G.START_FIRE:
		list.append({key = "fire", text = "Fogo +%d" % (int(mine[9]) - G.START_FIRE)})
	if int(mine[10]) > 0:
		list.append({key = "speed", text = "Patins +%d" % int(mine[10])})
	var bits: int = mine[6]
	for i in ABILITY_NAMES.size():
		if (bits & (1 << i)) != 0:
			list.append({key = "ab%d" % i, text = ABILITY_NAMES[i]})
	if (bits & 256) != 0:
		list.append({key = "vest", text = "Colete %ds" % ceili(mine[12]), timer = float(mine[12])})
	if (bits & 1024) != 0:
		list.append({key = "heart", text = "Coração"})
	if int(mine[7]) != 0:
		list.append({key = "skull%d" % int(mine[7]),
			text = "Caveira: %s %ds" % [G.DISEASE_NAMES[mine[7]], ceili(mine[11])], timer = float(mine[11])})
	hud_items.set_entries(list)


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
		music_vol = clampf(float(cf.get_value("audio", "music", 0.8)), 0.0, 1.0)
		sfx_vol = clampf(float(cf.get_value("audio", "sfx", 0.8)), 0.0, 1.0)


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("audio", "music", music_vol)
	cf.set_value("audio", "sfx", sfx_vol)
	cf.save(SETTINGS_PATH)
