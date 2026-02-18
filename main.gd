## main.gd
## Entry point. Creates MapData, Editor3D, EditorUI and wires them together.
extends Node

const MD := preload("res://scripts/map_data.gd")
const E3 := preload("res://scripts/editor_3d.gd")
const EU := preload("res://scripts/editor_ui.gd")

var map_data  : MD
var editor_3d : E3
var editor_ui : EU

func _ready() -> void:
	get_window().title        = "AxisBorn – Éditeur de carte"
	get_window().min_size     = Vector2i(900, 600)
	get_viewport().gui_embed_subwindows = true

	map_data  = MD.new()
	editor_3d = E3.new(map_data)
	add_child(editor_3d)  # must be in tree before editor_ui references its SubViewport

	editor_ui = EU.new(map_data, editor_3d)
	editor_ui.name = "EditorUI"
	add_child(editor_ui)

	# Show the "new map" dialog on startup
	editor_ui.show_new_map_dialog()
