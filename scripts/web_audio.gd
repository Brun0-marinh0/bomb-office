extends RefCounted
## Som na web sem HTTPS.
##
## O áudio do Godot 4.3 na web depende do AudioWorklet, que o navegador só libera
## em HTTPS ou localhost. Abrindo o jogo por http://IP-DA-REDE, o Godot fica mudo.
## Nesse caso, a música e os efeitos tocam por este script, via Web Audio API
## (funciona em http://), lendo os arquivos soltos que o build copia para o site
## (assets/sounds/...). Em HTTPS/localhost/desktop nada muda: active() é false.
##
## Uso: const WebAudio = preload("res://scripts/web_audio.gd")

static var _active := -1   # -1 = ainda não verificado


## true quando o jogo roda na web e o navegador bloqueou o AudioWorklet.
static func active() -> bool:
	if _active == -1:
		_active = 0
		if OS.has_feature("web"):
			# devolve texto: o Godot 4.3 converte booleano do JS em inteiro
			var res = JavaScriptBridge.eval(
				"(function(){try{var C=window.AudioContext||window.webkitAudioContext;" +
				"if(!C)return 'no';var c=new C();var w=typeof c.audioWorklet!=='undefined';" +
				"c.close();return w?'no':'yes';}catch(e){return 'no';}})()", true)
			if str(res) == "yes":
				_active = 1
				_install()
				print("[audio] navegador sem AudioWorklet (http): usando Web Audio direto")
	return _active == 1


## Música em loop com fade de entrada. volume = 0..1 (antes do volume de Configurações).
static func play_music(res_path: String, volume: float, fade_secs: float) -> void:
	if active():
		_call("playMusic(%s, %f, %f)" % [JSON.stringify(_url(res_path)), volume, fade_secs])


## Leva o volume da música até `volume` em `secs`; com stop_after, para no fim.
static func fade_music(volume: float, secs: float, stop_after: bool) -> void:
	if active():
		_call("fadeMusic(%f, %f, %s)" % [volume, secs, "true" if stop_after else "false"])


static func play_sfx(res_path: String) -> void:
	if active():
		_call("playSfx(%s)" % JSON.stringify(_url(res_path)))


## Baixa e decodifica o arquivo antes, para o primeiro efeito não atrasar.
static func preload_sound(res_path: String) -> void:
	if active():
		_call("load(%s)" % JSON.stringify(_url(res_path)))


## Volumes de Configurações (0..1).
static func set_volumes(music: float, sfx: float) -> void:
	if active():
		_call("setVolumes(%f, %f)" % [music, sfx])


static func _url(res_path: String) -> String:
	return res_path.trim_prefix("res://")


static func _call(js: String) -> void:
	JavaScriptBridge.eval("window.__bombAudio && window.__bombAudio." + js + ";", true)


static func _install() -> void:
	JavaScriptBridge.eval("""
	(function () {
		if (window.__bombAudio) return;
		var A = window.__bombAudio = {
			ctx: null, buffers: {}, loading: {}, vol: { music: 0.8, sfx: 0.8 },
			musicGain: null, sfxGain: null, track: null, trackGain: null,
			token: 0,      // invalida músicas ainda carregando
			stopToken: 0   // invalida paradas agendadas por um fade-out
		};
		A.ensure = function () {
			if (!A.ctx) {
				var C = window.AudioContext || window.webkitAudioContext;
				A.ctx = new C();
				A.musicGain = A.ctx.createGain(); A.musicGain.connect(A.ctx.destination);
				A.sfxGain = A.ctx.createGain(); A.sfxGain.connect(A.ctx.destination);
				A.applyVolumes();
			}
			if (A.ctx.state === 'suspended') A.ctx.resume();
			return A.ctx;
		};
		A.applyVolumes = function () {
			if (!A.ctx) return;
			A.musicGain.gain.value = A.vol.music;
			A.sfxGain.gain.value = A.vol.sfx;
		};
		A.setVolumes = function (m, s) { A.vol.music = m; A.vol.sfx = s; A.applyVolumes(); };
		A.load = function (url) {
			if (!A.loading[url]) {
				A.loading[url] = fetch(url)
					.then(function (r) { if (!r.ok) throw new Error(r.status); return r.arrayBuffer(); })
					.then(function (b) {
						return new Promise(function (res, rej) { A.ensure().decodeAudioData(b, res, rej); });
					})
					.then(function (buf) { A.buffers[url] = buf; return buf; })
					.catch(function (e) { console.warn('[audio] falha ao carregar ' + url, e); });
			}
			return A.loading[url];
		};
		A.playSfx = function (url) {
			var ctx = A.ensure();
			var buf = A.buffers[url];
			if (!buf) { A.load(url); return; }
			var src = ctx.createBufferSource();
			src.buffer = buf; src.connect(A.sfxGain); src.start();
		};
		A.stopTrack = function () {
			if (A.track) { try { A.track.stop(); } catch (e) {} }
			A.track = null; A.trackGain = null;
		};
		A.playMusic = function (url, volume, fade) {
			var token = ++A.token;
			++A.stopToken;
			A.stopTrack();
			A.load(url).then(function (buf) {
				if (!buf || token !== A.token) return;
				var ctx = A.ensure();
				var g = ctx.createGain();
				g.gain.setValueAtTime(0, ctx.currentTime);
				g.gain.linearRampToValueAtTime(volume, ctx.currentTime + fade);
				g.connect(A.musicGain);
				var src = ctx.createBufferSource();
				src.buffer = buf; src.loop = true; src.connect(g); src.start();
				A.track = src; A.trackGain = g;
			});
		};
		A.fadeMusic = function (volume, secs, stopAfter) {
			var st = ++A.stopToken;
			if (!A.trackGain) {
				if (stopAfter) ++A.token;   // música ainda carregando: cancela
				return;
			}
			var ctx = A.ensure(), g = A.trackGain.gain;
			g.cancelScheduledValues(ctx.currentTime);
			g.setValueAtTime(g.value, ctx.currentTime);
			g.linearRampToValueAtTime(volume, ctx.currentTime + secs);
			if (stopAfter) setTimeout(function () { if (st === A.stopToken) A.stopTrack(); }, secs * 1000 + 50);
		};
		// navegadores só liberam som depois de um toque/clique/tecla
		['pointerdown', 'touchstart', 'keydown'].forEach(function (ev) {
			document.addEventListener(ev, function () {
				if (A.ctx && A.ctx.state === 'suspended') A.ctx.resume();
				else if (!A.ctx) A.ensure();
			}, { capture: true, passive: true });
		});
	})();
	""", true)
