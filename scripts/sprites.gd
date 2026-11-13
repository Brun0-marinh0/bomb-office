extends Node
## Autoload "Sprites".
## Carrega res://assets/sprites/<nome>.png (32x32) se existir.
## Se não existir, gera um bloco colorido 32x32 como placeholder.
## Para trocar os blocos por arte de verdade basta colocar os PNGs na pasta
## (veja assets/sprites/LEIA-ME.md com a lista de nomes).

const G = preload("res://scripts/g.gd")
const SPRITE_DIR := "res://assets/sprites/"

var _cache := {}
var _custom := {}


func tex(key: String) -> Texture2D:
	if _cache.has(key):
		return _cache[key]
	var path := SPRITE_DIR + key + ".png"
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path)
	if t != null:
		_custom[key] = true
	else:
		t = _placeholder(key)
	_cache[key] = t
	return t


func is_custom(key: String) -> bool:
	if not _cache.has(key):
		tex(key)
	return _custom.get(key, false)


## Desenha um item (sprite + sigla quando for placeholder) dentro de rect.
func draw_item(ci: CanvasItem, item: int, rect: Rect2) -> void:
	if item <= 0 or item >= G.ITEM_COUNT:
		return
	var key: String = "item_" + G.ITEM_KEYS[item]
	ci.draw_texture_rect(tex(key), rect, false)
	if not is_custom(key):
		var font := ThemeDB.fallback_font
		var fs := int(rect.size.y * 0.38)
		var pos := Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + fs * 0.36)
		var label: String = G.ITEM_LABELS[item]
		ci.draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs, 3, Color(0, 0, 0, 0.9))
		ci.draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs, Color.WHITE)


func _placeholder(key: String) -> Texture2D:
	match key:
		"floor":
			return _block(Color(0.24, 0.55, 0.32), 0, false)
		"floor_alt":
			return _block(Color(0.22, 0.51, 0.30), 0, false)
		"hard":
			return _block(Color(0.52, 0.54, 0.60), 0, true)
		"fallen":
			return _block(Color(0.30, 0.28, 0.34), 0, true)
		"soft":
			return _block(Color(0.74, 0.52, 0.30), 1, true)
		"bomb":
			return _block(Color(0.12, 0.12, 0.16), 5, true)
		"player":
			return _block(Color(1, 1, 1), 3, true)
		"flame":
			return _flame()
	if key.begins_with("item_"):
		var i: int = G.ITEM_KEYS.find(key.substr(5))
		if i > 0:
			return _block(G.ITEM_COLORS[i], 3, true)
	return _block(Color.MAGENTA, 0, false)


func _block(c: Color, inset: int, bevel: bool) -> Texture2D:
	var s := G.TILE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := Rect2i(inset, inset, s - inset * 2, s - inset * 2)
	img.fill_rect(r, c)
	if bevel:
		var light := c.lightened(0.3)
		var dark := c.darkened(0.4)
		for i in range(r.size.x):
			img.set_pixel(r.position.x + i, r.position.y, light)
			img.set_pixel(r.position.x + i, r.end.y - 1, dark)
		for i in range(r.size.y):
			img.set_pixel(r.position.x, r.position.y + i, light)
			img.set_pixel(r.end.x - 1, r.position.y + i, dark)
	return ImageTexture.create_from_image(img)


func _flame() -> Texture2D:
	var s := G.TILE
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(1, 1, s - 2, s - 2), Color(1.0, 0.45, 0.08))
	img.fill_rect(Rect2i(7, 7, s - 14, s - 14), Color(1.0, 0.82, 0.2))
	img.fill_rect(Rect2i(12, 12, s - 24, s - 24), Color(1.0, 1.0, 0.85))
	return ImageTexture.create_from_image(img)
