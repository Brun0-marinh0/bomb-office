extends RefCounted
## Snapshot compacto (servidor -> clientes), em bytes em vez de Arrays de Variants.
##
## Antes cada snapshot tinha ~2 KB (mapa, fogo e itens inteiros + 13 Variants por jogador),
## 30x por segundo para cada jogador. Agora:
##   cabeçalho (9 B): tempo do servidor (ms), tempo da rodada, flags
##   mapa (442 B):    blocos + itens visíveis, só quando mudou (ou 1x por segundo)
##   fogo (28 B):     1 bit por casa, só quando há fogo
##   jogador (~19 B), bomba (~13 B)
##
## decode() devolve o mesmo Array de sempre para o resto do jogo:
##   [time_left, tiles, flames, items, players, bombs, sudden, largura, altura]

const G = preload("res://scripts/g.gd")

const F_SUDDEN := 1
const F_MAP := 2
const F_FIRE := 4
const POS_OFFSET := 4.0      # posições podem passar um pouco da borda (arremesso que dá a volta)
const POS_SCALE := 256.0


## s = ServerGame.snapshot()
static func encode(ms: int, s: Array, with_map: bool) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	var fl: PackedByteArray = s[2]
	var has_fire := fl.has(1)
	var flags := 0
	if s[6]:
		flags |= F_SUDDEN
	if with_map:
		flags |= F_MAP
	if has_fire:
		flags |= F_FIRE
	b.put_u32(ms)
	b.put_float(float(s[0]))
	b.put_u8(flags)
	if with_map:
		b.put_u8(int(s[7]))    # largura e altura do mapa (mudam com a quantidade de jogadores)
		b.put_u8(int(s[8]))
		b.put_data(s[1])
		b.put_data(s[3])
	if has_fire:
		b.put_data(_pack_bits(fl))
	var pl: Array = s[4]
	b.put_u8(pl.size())
	for p in pl:
		b.put_32(int(p[0]))
		b.put_u16(_fx(p[1]))
		b.put_u16(_fx(p[2]))
		b.put_u8((1 if p[3] else 0) | ((int(p[4]) + 1) << 1) | ((int(p[5]) + 1) << 3))
		b.put_u16(int(p[6]))
		b.put_u8(int(p[7]))
		b.put_u8(int(p[8]))
		b.put_u8(int(p[9]))
		b.put_u8(int(p[10]))
		b.put_u8(clampi(ceili(float(p[11])), 0, 255))
		b.put_u8(clampi(ceili(float(p[12])), 0, 255))
		b.put_u8(clampi(ceili(float(p[13])), 0, 255))
		b.put_u8(clampi(ceili(float(p[14])), 0, 255))
		b.put_u8(clampi(int(p[15]), 0, 255))
	var bl: Array = s[5]
	b.put_u16(bl.size())
	for e in bl:
		b.put_u32(int(e[0]))
		b.put_u16(_fx(e[1]))
		b.put_u16(_fx(e[2]))
		b.put_u8(clampi(int(round(float(e[3]) * 100.0)), 0, 255))
		b.put_u8(int(e[4]))
		b.put_u8(clampi(int(round(float(e[5]) * 255.0)), 0, 255))
	return b.data_array


## map = [tiles, items, largura, altura] do último mapa recebido (atualizado aqui quando o
## snapshot traz o mapa). Retorna [ms, snapshot] ou [] se ainda não chegou nenhum mapa.
static func decode(data: PackedByteArray, map: Array) -> Array:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	var ms := b.get_u32()
	var time_left := b.get_float()
	var flags := b.get_u8()
	if map.size() < 4:
		map.resize(4)
		map[2] = 0
		map[3] = 0
	if flags & F_MAP:
		map[2] = b.get_u8()
		map[3] = b.get_u8()
		var mn: int = map[2] * map[3]
		map[0] = b.get_data(mn)[1]
		map[1] = b.get_data(mn)[1]
	var n: int = int(map[2]) * int(map[3])
	if n == 0 or not (map[0] is PackedByteArray) or (map[0] as PackedByteArray).size() != n:
		return []
	var fl := PackedByteArray()
	fl.resize(n)
	if flags & F_FIRE:
		var bits: PackedByteArray = b.get_data((n + 7) / 8)[1]
		for k in n:
			if bits[k >> 3] & (1 << (k & 7)):
				fl[k] = 1
	var pl: Array = []
	for i in b.get_u8():
		var id := b.get_32()
		var x := _unfx(b.get_u16())
		var y := _unfx(b.get_u16())
		var st := b.get_u8()
		var bits := b.get_u16()
		var disease := b.get_u8()
		var bombs := b.get_u8()
		var fire := b.get_u8()
		var speed := b.get_u8()
		var disease_t := float(b.get_u8())
		var vest_t := float(b.get_u8())
		var wall_t := float(b.get_u8())
		var bomb_pass_t := float(b.get_u8())
		var bombs_out := b.get_u8()   # bombas dele no mapa agora
		pl.append([id, x, y, (st & 1) != 0, ((st >> 1) & 3) - 1, ((st >> 3) & 3) - 1, bits,
			disease, bombs, fire, speed, disease_t, vest_t, wall_t, bomb_pass_t, bombs_out])
	var bl: Array = []
	for i in b.get_u16():
		var id := b.get_u32()
		var x := _unfx(b.get_u16())
		var y := _unfx(b.get_u16())
		var z := b.get_u8() / 100.0
		var kind := b.get_u8()
		var frac := b.get_u8() / 255.0
		bl.append([id, x, y, z, kind, frac])
	return [ms, [time_left, map[0], fl, map[1], pl, bl, (flags & F_SUDDEN) != 0, map[2], map[3]]]


static func _fx(v) -> int:
	return clampi(int(round((float(v) + POS_OFFSET) * POS_SCALE)), 0, 65535)


static func _unfx(v: int) -> float:
	return v / POS_SCALE - POS_OFFSET


static func _pack_bits(fl: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize((fl.size() + 7) / 8)
	for k in fl.size():
		if fl[k] != 0:
			out[k >> 3] |= 1 << (k & 7)
	return out
