extends Control
## Ícone de item (usado na legenda do lobby).

var item := 1


func _ready() -> void:
	custom_minimum_size = Vector2(32, 32)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _draw() -> void:
	Sprites.draw_item(self, item, Rect2(Vector2.ZERO, Vector2(32, 32)))
