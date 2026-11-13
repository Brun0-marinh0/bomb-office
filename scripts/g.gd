extends RefCounted
## Constantes e regras do jogo, compartilhadas entre servidor e clientes.
## Use com: const G = preload("res://scripts/g.gd")

const TILE := 32          # tamanho do sprite/tile em pixels
const W := 17             # largura da arena em tiles (inclui bordas)
const H := 13             # altura da arena em tiles (inclui bordas)
const MAX_PLAYERS := 8
const DEFAULT_PORT := 9080

# ---------------------------------------------------------------- tiles
const T_EMPTY := 0
const T_HARD := 1         # bloco indestrutível (borda e pilares)
const T_SOFT := 2         # bloco destrutível
const T_BURNING := 3      # bloco destrutível pegando fogo (vira vazio)
const T_FALLEN := 4       # bloco que caiu na morte súbita

# ---------------------------------------------------------------- itens
const I_NONE := 0
const I_BOMB_UP := 1
const I_FIRE_UP := 2
const I_FULL_FIRE := 3
const I_SPEED_UP := 4
const I_KICK := 5
const I_PUNCH := 6
const I_REMOTE := 7
const I_PIERCE := 8
const I_LINE := 9
const I_POWER := 10
const I_WALL_PASS := 11
const I_BOMB_PASS := 12
const I_VEST := 13
const I_HEART := 14
const I_SKULL := 15
const ITEM_COUNT := 16

# nome do arquivo de sprite: assets/sprites/item_<key>.png
const ITEM_KEYS := ["", "bomb_up", "fire_up", "full_fire", "speed_up", "kick", "punch", "remote",
	"pierce", "line", "power", "wall_pass", "bomb_pass", "vest", "heart", "skull"]
const ITEM_NAMES := ["", "Bomba +1", "Fogo +1", "Fogo Máximo", "Patins", "Chute", "Luva",
	"Controle Remoto", "Bomba Perfurante", "Bomba em Linha", "Super Bomba", "Atravessa Paredes",
	"Atravessa Bombas", "Colete", "Coração", "Caveira"]
const ITEM_LABELS := ["", "B+", "F+", "FM", "S+", "CH", "LV", "RC", "PF", "LN", "SB", "AP", "AB",
	"CL", "CR", ":("]
const ITEM_DESCS := ["",
	"+1 bomba ao mesmo tempo",
	"+1 de alcance da explosão",
	"Alcance máximo da explosão",
	"Anda mais rápido",
	"Ande contra uma bomba para chutá-la",
	"AÇÃO: arremessa a bomba à frente por 3 casas",
	"Bombas só explodem quando você aperta AÇÃO",
	"Explosão atravessa blocos destrutíveis",
	"Aperte BOMBA em cima de uma bomba: solta todas em linha",
	"Sua primeira bomba tem alcance máximo",
	"Atravessa blocos destrutíveis",
	"Passa por cima de bombas",
	"Invencível por 10 segundos",
	"Aguenta uma explosão",
	"Doença aleatória! Passa para quem encostar em você"]
const ITEM_COLORS := [Color(0, 0, 0, 0),
	Color(0.30, 0.30, 0.40), Color(1.00, 0.55, 0.15), Color(0.90, 0.15, 0.10), Color(0.30, 0.75, 1.00),
	Color(0.55, 0.35, 0.20), Color(0.95, 0.70, 0.55), Color(0.20, 0.45, 0.95), Color(0.65, 0.30, 0.90),
	Color(0.90, 0.80, 0.20), Color(0.85, 0.10, 0.45), Color(0.45, 0.35, 0.25), Color(0.45, 0.45, 0.55),
	Color(0.20, 0.75, 0.45), Color(1.00, 0.40, 0.55), Color(0.10, 0.10, 0.10)]
# chance relativa de cada item aparecer embaixo de um bloco
const ITEM_WEIGHTS := [0, 14, 14, 2, 10, 5, 4, 3, 3, 3, 3, 2, 3, 2, 3, 5]

# ---------------------------------------------------------------- doenças (caveira)
const D_NONE := 0
const D_SLOW := 1
const D_FAST := 2
const D_DIARRHEA := 3
const D_CONSTIPATION := 4
const D_SHORT_FIRE := 5
const D_REVERSE := 6
const D_SHORT_FUSE := 7
const DISEASE_COUNT := 8
const DISEASE_NAMES := ["", "Lentidão", "Hiper velocidade", "Diarreia de bombas", "Não solta bombas",
	"Fogo fraco", "Controles invertidos", "Pavio curto"]

# ---------------------------------------------------------------- ajustes de jogo
const FUSE := 2.5               # segundos até a bomba explodir
const SHORT_FUSE := 1.0
const CHAIN_DELAY := 0.06       # atraso da reação em cadeia
const FLAME_TIME := 0.55        # duração do fogo
const START_BOMBS := 1
const START_FIRE := 2
const MAX_BOMBS := 10
const MAX_FIRE := 10
const POWER_RANGE := 20
const BASE_SPEED := 3.6         # tiles por segundo
const SPEED_STEP := 0.55
const MAX_SPEED_LVL := 8
const SLOW_SPEED := 1.6
const FAST_SPEED := 9.0
const KICK_SPEED := 9.0
const PUNCH_DIST := 3
const PUNCH_TIME_PER_TILE := 0.12
const DISEASE_TIME := 15.0
const VEST_TIME := 10.0
const HEART_INVULN := 2.0
const SOFT_DENSITY := 0.72      # chance de um tile livre ter bloco destrutível
const ITEM_CHANCE := 0.40       # chance de um bloco esconder um item
const SUDDEN_DEATH_AT := 60.0   # segundos restantes quando começa a morte súbita
const SUDDEN_STEP := 0.3        # intervalo entre blocos caindo
const CORNER_ASSIST := 0.12     # quanto desalinhado ainda "escorrega" para o corredor
const ROUND_END_DELAY := 2.0    # espera para detectar mortes simultâneas (empate)

const PLAYER_COLORS := [Color(0.95, 0.95, 0.95), Color(0.92, 0.22, 0.22), Color(0.25, 0.45, 1.0),
	Color(0.20, 0.85, 0.30), Color(1.0, 0.85, 0.15), Color(1.0, 0.45, 0.80), Color(0.25, 0.92, 0.95),
	Color(0.62, 0.38, 0.95)]
const PLAYER_COLOR_NAMES := ["Branco", "Vermelho", "Azul", "Verde", "Amarelo", "Rosa", "Ciano", "Roxo"]

# 4 cantos primeiro, depois o meio de cada lado
const SPAWNS := [Vector2i(1, 1), Vector2i(15, 11), Vector2i(15, 1), Vector2i(1, 11),
	Vector2i(8, 1), Vector2i(8, 11), Vector2i(1, 6), Vector2i(15, 6)]

const DIRS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]


static func idx(c: Vector2i) -> int:
	return c.y * W + c.x


static func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H


static func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))


static func center_of(c: Vector2i) -> Vector2:
	return Vector2(c) + Vector2(0.5, 0.5)


static func is_pillar(c: Vector2i) -> bool:
	if c.x == 0 or c.y == 0 or c.x == W - 1 or c.y == H - 1:
		return true
	return c.x % 2 == 0 and c.y % 2 == 0


## Ordem em que os blocos caem na morte súbita: espiral de fora para dentro.
static func spiral_cells() -> Array:
	var res: Array = []
	var left := 1
	var top := 1
	var right := W - 2
	var bottom := H - 2
	while left <= right and top <= bottom:
		for x in range(left, right + 1):
			res.append(Vector2i(x, top))
		for y in range(top + 1, bottom + 1):
			res.append(Vector2i(right, y))
		if top < bottom:
			for x in range(right - 1, left - 1, -1):
				res.append(Vector2i(x, bottom))
		if left < right:
			for y in range(bottom - 1, top, -1):
				res.append(Vector2i(left, y))
		left += 1
		top += 1
		right -= 1
		bottom -= 1
	return res
