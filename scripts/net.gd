extends Node
## Autoload "Net": cria/encerra a conexão WebSocket (servidor ou cliente).

const G = preload("res://scripts/g.gd")

var is_server := false
var is_dedicated := false


func host(port: int, dedicated: bool, tls: TLSOptions = null) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port, "*", tls)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_dedicated = dedicated
	return OK


func join(url: String) -> Error:
	leave()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	return OK


func leave() -> void:
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_server = false
	is_dedicated = false


## Endereço do servidor sugerido no menu.
## Na web: usa ?server=wss://... da URL; senão deduz pelo endereço da página.
func default_url() -> String:
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('server') || ''", true)
		if q is String and q != "":
			return q
		var proto = JavaScriptBridge.eval("window.location.protocol", true)
		var host_name = JavaScriptBridge.eval("window.location.hostname", true)
		if proto == "https:":
			# atrás do Caddy (docker compose --profile https): mesmo domínio, rota /ws
			return "wss://%s/ws" % JavaScriptBridge.eval("window.location.host", true)
		return "ws://%s:%d" % [host_name, G.DEFAULT_PORT]
	return "ws://localhost:%d" % G.DEFAULT_PORT


func url_has_server_param() -> bool:
	return url_param("server") != ""


## Parâmetro da URL da página (?server=..., ?sala=...). Fora da web, "".
func url_param(name: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var q = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get(%s) || ''" % JSON.stringify(name), true)
	return q if q is String else ""


## Copia texto. Na web funciona também sem HTTPS (fallback com execCommand).
func copy_text(text: String) -> void:
	if not OS.has_feature("web"):
		DisplayServer.clipboard_set(text)
		return
	var js := """
		(function (t) {
			function fallback() {
				var a = document.createElement('textarea');
				a.value = t; a.style.position = 'fixed'; a.style.opacity = '0';
				document.body.appendChild(a); a.focus(); a.select();
				try { document.execCommand('copy'); } catch (e) {}
				document.body.removeChild(a);
				var c = document.getElementById('canvas'); if (c) c.focus();
			}
			if (navigator.clipboard && window.isSecureContext && location.protocol === 'https:') {
				navigator.clipboard.writeText(t).catch(fallback);
			} else { fallback(); }
		})(%s);
	""" % JSON.stringify(text)
	JavaScriptBridge.eval(js, true)


func page_url() -> String:
	if OS.has_feature("web"):
		var href = JavaScriptBridge.eval("window.location.href", true)
		if href is String:
			return href
	return ""


# ------------------------------------------------------------- tela cheia (celular)
## Celular/tablet: tela de toque. Usado para mostrar os controles e o botão de tela cheia.
func is_touch() -> bool:
	return DisplayServer.is_touchscreen_available()


## O navegador permite tela cheia na página? (iPhone não permite; lá use "Adicionar à Tela de Início")
func fullscreen_supported() -> bool:
	if not OS.has_feature("web"):
		return false
	# (o eval do Godot 4.3 devolve null para booleanos do JS, por isso 1/0)
	return int(JavaScriptBridge.eval("(document.fullscreenEnabled || document.webkitFullscreenEnabled) ? 1 : 0", true)) == 1


func is_fullscreen() -> bool:
	if not OS.has_feature("web"):
		return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	return int(JavaScriptBridge.eval("(document.fullscreenElement || document.webkitFullscreenElement) ? 1 : 0", true)) == 1


## Precisa ser chamado logo após um toque/clique do jogador (regra do navegador).
## Em tela cheia também trava a tela na horizontal, quando o celular deixa.
func set_fullscreen(on: bool) -> void:
	if not OS.has_feature("web"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on
			else DisplayServer.WINDOW_MODE_WINDOWED)
		return
	var js := """
		(function (on) {
			var d = document, el = d.documentElement;
			try {
				if (on) {
					if (d.fullscreenElement || d.webkitFullscreenElement) return;
					var req = el.requestFullscreen || el.webkitRequestFullscreen;
					if (!req) return;
					var p = req.call(el, { navigationUI: 'hide' });
					var lock = function () {
						if (screen.orientation && screen.orientation.lock)
							screen.orientation.lock('landscape').catch(function () {});
					};
					if (p && p.then) p.then(lock).catch(function () {}); else lock();
				} else {
					if (!(d.fullscreenElement || d.webkitFullscreenElement)) return;
					var ex = d.exitFullscreen || d.webkitExitFullscreen;
					if (ex) { var q = ex.call(d); if (q && q.catch) q.catch(function () {}); }
				}
			} catch (e) {}
		})(%s);
	""" % ("true" if on else "false")
	JavaScriptBridge.eval(js, true)
