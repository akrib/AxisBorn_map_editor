extends Node2D

## Carte de la Ville - Zone de départ sans ennemis

signal map_ready()

func _ready():
	map_ready.emit()
	print("🏘️ Ville chargée - Zone sûre")

func get_spawn_position() -> Vector2:
	# Position de spawn au centre de la ville
	return Vector2(0, 0)
