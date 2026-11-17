extends RefCounted
## Som no navegador direto pela Web Audio API.
##
## Música (sempre, na web): as faixas de assets/sounds/intro/ NÃO vão dentro do pacote
## do jogo (index.pck), para o jogo abrir mais rápido. Tocam em streaming (<audio>),
## sem decodificar a música inteira na memória — a lista vem de assets/sounds/intro/index.json
## (gerado no build do Docker / servido pelo servidor_web.py).
##
## Efeitos: o áudio do Godot 4.3 na web depende do AudioWorklet, que o navegador só libera
## em HTTPS ou localhost. Abrindo por http://IP-DA-REDE, active() fica true e os efeitos
## tocam por aqui também, lendo os arquivos soltos (assets/sounds/...).
##
## Uso: const WebAudio = preload("res://scripts/web_audio.gd")

const INTRO_LIST := "assets/sounds/intro/index.json"

static var _active := -1   # -1 = ainda não verificado
static var _installed := false


## Rodando no navegador? (a música usa sempre este caminho na web)
static func web() -> bool:
	return OS.has_feature("web")


## true quando o navegador bloqueou o AudioWorklet: os efeitos também tocam por aqui.
static func active() -> bool:
	if _active == -1:
		_active = 0
		if web():
			# devolve texto: o Godot 4.3 converte booleano do JS em inteiro
			var res = JavaScriptBridge.eval(
				"(function(){try{var C=window.AudioContext||window.webkitAudioContext;" +
				"if(!C)return 'no';var c=new C();var w=typeof c.audioWorklet!=='undefined';" +
				"c.close();return w?'no':'yes';}catch(e){return 'no';}})()", true)
			if str(res) == "yes":
				_active = 1
				print("[audio] navegador sem AudioWorklet (http): efeitos pelo Web Audio direto")
	return _active == 1


## Sorteia uma faixa de entrada (sem repetir a anterior) e toca em loop com fade de entrada.
static func play_random_intro(volume: float, fade_secs: float) -> void:
	if web():
		_call("playRandomIntro(%s, %f, %f)" % [JSON.stringify(INTRO_LIST), volume, fade_secs])


## Leva o volume da música até `volume` em `secs`; com stop_after, para no fim.
static func fade_music(volume: float, secs: float, stop_after: bool) -> void:
	if web():
		_call("fadeMusic(%f, %f, %s)" % [volume, secs, "true" if stop_after else "false"])


static func play_sfx(res_path: String) -> void:
	if active():
		_call("playSfx(%s)" % JSON.stringify(_url(res_path)))


## Baixa e decodifica o efeito antes, para o primeiro não atrasar.
static func preload_sound(res_path: String) -> void:
	if active():
		_call("load(%s)" % JSON.stringify(_url(res_path)))


## Volumes de Configurações (0..1).
static func set_volumes(music: float, sfx: float) -> void:
	if web():
		_call("setVolumes(%f, %f)" % [music, sfx])


static func _url(res_path: String) -> String:
	return res_path.trim_prefix("res://")


static func _call(js: String) -> void:
	if not _installed:
		_installed = true
		_install()
	JavaScriptBridge.eval("window.__bombAudio && window.__bombAudio." + js + ";", true)


static func _install() -> void:
	JavaScriptBridge.eval("""
	(function () {
		if (window.__bombAudio) return;
		var A = window.__bombAudio = {
			ctx: null, buffers: {}, loading: {}, vol: { music: 0.8, sfx: 0.8 },
			musicGain: null, sfxGain: null,
			track: null, trackGain: null, trackSrc: null,   // música atual (<audio> em streaming)
			tracks: null, lastTrack: '',
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
		// ---- efeitos (curtos): decodificados uma vez e reaproveitados
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
		// ---- música (longa): streaming por <audio>, sem decodificar tudo na memória
		A.stopTrack = function () {
			if (A.track) {
				try { A.track.pause(); A.track.removeAttribute('src'); A.track.load(); } catch (e) {}
			}
			if (A.trackSrc) { try { A.trackSrc.disconnect(); } catch (e) {} }
			A.track = null; A.trackGain = null; A.trackSrc = null;
		};
		A.startTrack = function (url, volume, fade) {
			var ctx = A.ensure();
			A.stopTrack();
			var el = new Audio();
			el.loop = true; el.preload = 'auto'; el.src = url;
			var src = ctx.createMediaElementSource(el);
			var g = ctx.createGain();
			g.gain.setValueAtTime(0, ctx.currentTime);
			g.gain.linearRampToValueAtTime(volume, ctx.currentTime + fade);
			src.connect(g); g.connect(A.musicGain);
			A.track = el; A.trackGain = g; A.trackSrc = src;
			var p = el.play();
			if (p && p.catch) p.catch(function () {});   // sem toque ainda: tenta de novo no primeiro toque
			console.log('[musica] tocando ' + url.split('/').pop() + ' (streaming)');
		};
		A.playRandomIntro = function (listUrl, volume, fade) {
			var token = ++A.token;
			++A.stopToken;
			var go = function (list) {
				if (token !== A.token || !list || !list.length) return;
				var choices = list.length > 1 ? list.filter(function (u) { return u !== A.lastTrack; }) : list;
				var url = choices[Math.floor(Math.random() * choices.length)];
				A.lastTrack = url;
				A.startTrack(url, volume, fade);
			};
			if (A.tracks) { go(A.tracks); return; }
			var base = listUrl.substring(0, listUrl.lastIndexOf('/') + 1);
			fetch(listUrl, { cache: 'no-cache' })
				.then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
				.then(function (names) {
					A.tracks = names.map(function (n) { return base + encodeURIComponent(n); });
					go(A.tracks);
				})
				.catch(function (e) { console.warn('[musica] lista de faixas indisponivel', e); });
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
				A.ensure();
				if (A.track && A.track.paused) { var p = A.track.play(); if (p && p.catch) p.catch(function () {}); }
			}, { capture: true, passive: true });
		});
	})();
	""", true)
