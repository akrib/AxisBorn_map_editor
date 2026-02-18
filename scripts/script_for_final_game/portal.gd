extends Area2D
class_name Portal

## Portail de téléportation avec effet visuel circulaire amélioré

@export var destination_map: String = "forest"
@export var portal_color: Color = Color(0.3, 0.9, 0.4)

var cooldown_active: bool = false
var rotation_speed: float = 1.0
var pulse_time: float = 0.0

@onready var visual_node = $PortalVisual
@onready var outer_circle = $PortalVisual/OuterCircle
@onready var middle_circle = $PortalVisual/MiddleCircle
@onready var inner_circle = $PortalVisual/InnerCircle

func _ready():
	body_entered.connect(_on_body_entered)
	
	# Configurer les couleurs des cercles avec transparence
	if outer_circle:
		outer_circle.color = Color(portal_color.r * 0.7, portal_color.g * 0.7, portal_color.b * 0.7, 0.5)
	if middle_circle:
		middle_circle.color = Color(portal_color.r * 0.85, portal_color.g * 0.85, portal_color.b * 0.85, 0.65)
	if inner_circle:
		inner_circle.color = Color(portal_color.r, portal_color.g, portal_color.b, 0.8)

func _process(delta):
	# Rotation du portail
	if visual_node:
		visual_node.rotation += rotation_speed * delta
	
	# Effet de pulsation
	pulse_time += delta * 2.0
	var pulse = sin(pulse_time) * 0.15 + 1.0
	
	if visual_node:
		visual_node.scale = Vector2.ONE * pulse

func _on_body_entered(body):
	if body.is_in_group("player") and not cooldown_active:
		teleport_player(body)

func teleport_player(player):
	cooldown_active = true
	
	var map_manager = get_tree().root.get_node_or_null("Main/MapManager")
	if map_manager:
		map_manager.change_map(destination_map, player)
	
	# Cooldown de 1 seconde
	await get_tree().create_timer(1.0).timeout
	cooldown_active = false

## Fonction pour créer un portail par script (utilitaire)
static func create_portal(pos: Vector2, dest: String, color: Color) -> Portal:
	var portal = Portal.new()
	portal.position = pos
	portal.destination_map = dest
	portal.portal_color = color
	
	# Créer le nœud visuel
	var visual = Node2D.new()
	visual.name = "PortalVisual"
	portal.add_child(visual)
	
	# Créer les trois cercles
	var outer = ColorRect.new()
	outer.name = "OuterCircle"
	outer.offset_left = -60
	outer.offset_top = -60
	outer.offset_right = 60
	outer.offset_bottom = 60
	outer.color = Color(color.r * 0.7, color.g * 0.7, color.b * 0.7, 0.5)
	visual.add_child(outer)
	
	var middle = ColorRect.new()
	middle.name = "MiddleCircle"
	middle.offset_left = -45
	middle.offset_top = -45
	middle.offset_right = 45
	middle.offset_bottom = 45
	middle.color = Color(color.r * 0.85, color.g * 0.85, color.b * 0.85, 0.65)
	visual.add_child(middle)
	
	var inner = ColorRect.new()
	inner.name = "InnerCircle"
	inner.offset_left = -30
	inner.offset_top = -30
	inner.offset_right = 30
	inner.offset_bottom = 30
	inner.color = Color(color.r, color.g, color.b, 0.8)
	visual.add_child(inner)
	
	# Collision shape
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = 50
	collision.shape = shape
	portal.add_child(collision)
	
	# Label
	var label = Label.new()
	label.offset_left = -50
	label.offset_top = -90
	label.offset_right = 50
	label.offset_bottom = -70
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	portal.add_child(label)
	
	return portal
