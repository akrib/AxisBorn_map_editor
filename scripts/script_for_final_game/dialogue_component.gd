extends Node
class_name DialogueComponent

## Composant de dialogue simple pour les PNJ

signal dialogue_started()
signal dialogue_ended()

@export var npc_name: String = "Villageois"
@export_multiline var dialogue_text: String = "Hello World!"
@export var interaction_range: float = 50.0

var is_player_nearby: bool = false
var player_ref = null

func _ready():
	# Le dialogue_trigger sera géré par le PNJ parent
	pass

func can_interact() -> bool:
	return is_player_nearby

func start_dialogue():
	if can_interact():
		dialogue_started.emit()
		show_dialogue()
		return true
	return false

func show_dialogue():
	# Créer une simple boîte de dialogue
	var dialogue_box = create_dialogue_box()
	get_tree().root.add_child(dialogue_box)
	
	# Auto-fermeture après 3 secondes
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(dialogue_box):
		dialogue_box.queue_free()
	dialogue_ended.emit()

func create_dialogue_box() -> Control:
	var panel = Panel.new()
	panel.custom_minimum_size = Vector2(400, 100)
	panel.position = Vector2(200, 450)
	panel.z_index = 100
	
	# Background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.border_width_all = 2
	style.border_color = Color(0.8, 0.7, 0.3, 1.0)
	style.corner_radius_all = 5
	panel.add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	vbox.position = Vector2(10, 10)
	vbox.size = Vector2(380, 80)
	panel.add_child(vbox)
	
	# NPC Name
	var name_label = Label.new()
	name_label.text = npc_name
	name_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5, 1.0))
	name_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(name_label)
	
	# Dialogue text
	var text_label = Label.new()
	text_label.text = dialogue_text
	text_label.add_theme_font_size_override("font_size", 14)
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(text_label)
	
	return panel

func set_player_nearby(nearby: bool, player = null):
	is_player_nearby = nearby
	player_ref = player
