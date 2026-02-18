extends StaticBody2D
class_name NPC

## PNJ interactif simple

@onready var dialogue_component: DialogueComponent = $DialogueComponent
@onready var interaction_area: Area2D = $InteractionArea

var player_in_range: bool = false

func _ready():
	# Connecter les signaux de la zone d'interaction
	if interaction_area:
		interaction_area.body_entered.connect(_on_body_entered)
		interaction_area.body_exited.connect(_on_body_exited)

func _process(_delta):
	# Vérifier si le joueur appuie sur E pour interagir
	if player_in_range and Input.is_action_just_pressed("ui_accept"):
		if dialogue_component:
			dialogue_component.start_dialogue()

func _on_body_entered(body):
	if body.is_in_group("player"):
		player_in_range = true
		if dialogue_component:
			dialogue_component.set_player_nearby(true, body)
		show_interaction_hint(true)

func _on_body_exited(body):
	if body.is_in_group("player"):
		player_in_range = false
		if dialogue_component:
			dialogue_component.set_player_nearby(false)
		show_interaction_hint(false)

func show_interaction_hint(show: bool):
	# Afficher un petit indicateur "E"
	var hint = get_node_or_null("InteractionHint")
	if hint:
		hint.visible = show
