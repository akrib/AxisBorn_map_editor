## editor_ui.gd  –  Version 3.3
## Panneau droit ANCRÉ hors du HBoxContainer (position absolue, bord droit).
## Système de favoris ⭐ avec étoile au survol + export tileset_axisborn_XXX.png.
## Layer toggle, triggers, tileset config.
extends Control

const MD := preload("res://scripts/map_data.gd")
const E3 := preload("res://scripts/editor_3d.gd")

# ══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ══════════════════════════════════════════════════════════════════════════════
const RIGHT_PANEL_W := 164

const TOOL_NAMES := [
	"4 Coins partagés", "Hauteur de face", "Texture", "Coin unique", "Pipette", "Trigger"
]
const TOOL_ICONS := ["⊕", "↕", "🖌", "◉", "💧", "⚡"]

# ══════════════════════════════════════════════════════════════════════════════
# REFERENCES
# ══════════════════════════════════════════════════════════════════════════════
var map_data  : MD
var editor_3d : E3

var _vp_container   : SubViewportContainer
var _bottom_bar     : Control
var _side_bar       : Control
var _new_map_dialog : Window
var _tool_buttons   : Array  = []
var _status_label   : Label

var _sel_tex_lbl : Label = null

var _selected_atlas_path : String = ""
var _selected_atlas_col  : int    = 0
var _selected_atlas_row  : int    = 0
var _atlas_cell_size     : int    = 32
var _uv_scale_spin       : SpinBox = null
var _texture_grid_container : GridContainer
var _loaded_atlases : Array = []
var _minimap_rect   : TextureRect = null

var _size_btn_16 : Button = null
var _size_btn_32 : Button = null

## Layer toggle
var _layer_btn_base    : Button = null
var _layer_btn_overlay : Button = null

## Trigger UI
var _trigger_type_option : OptionButton = null
var _trigger_id_edit : LineEdit = null

## Favorites  — key = "path|col|row"
var _favorites : Dictionary = {}
var _show_only_favorites : bool = false

# ══════════════════════════════════════════════════════════════════════════════
# INIT
# ══════════════════════════════════════════════════════════════════════════════
func _init(md: MD, e3: E3) -> void:
	map_data  = md
	editor_3d = e3

func _ready() -> void:
	_build_ui()
	editor_3d.selection_changed.connect(_on_selection_changed)
	editor_3d.status_message.connect(_on_status_message)
	editor_3d.map_changed.connect(_update_minimap)
	editor_3d.texture_picked.connect(_on_texture_picked)
	editor_3d.trigger_placed.connect(_on_trigger_placed)
	editor_3d.cube_hovered.connect(func(_a, _b, _c): pass)
	_scan_texture_folder()
	editor_3d.set_viewport_container(_vp_container)

func _on_status_message(msg: String) -> void:
	_status_label.text = msg

func _on_texture_picked(fc: MD.FaceConfig) -> void:
	if _sel_tex_lbl:
		var ln := "OV" if editor_3d.active_layer == MD.LAYER_OVERLAY else "BASE"
		_sel_tex_lbl.text = "💧 [%s] %s\n[%d,%d]" % [ln, fc.atlas_path.get_file(), fc.atlas_col, fc.atlas_row]
	if _uv_scale_spin: _uv_scale_spin.value = fc.uv_scale
	_select_tool_by_idx(2)

func _on_trigger_placed(_tx: int, _ty: int, _si: int, _trigger: MD.TriggerData) -> void:
	_update_minimap()

# ══════════════════════════════════════════════════════════════════════════════
# KEYBOARD
# ══════════════════════════════════════════════════════════════════════════════
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if not (event is InputEventKey): return
	if not event.pressed or event.echo: return
	match event.keycode:
		KEY_EQUAL, KEY_KP_ADD:      editor_3d.adjust_height( MD.HEIGHT_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT: editor_3d.adjust_height(-MD.HEIGHT_STEP)
		KEY_PAGEUP:                 editor_3d.adjust_height( 1.0)
		KEY_PAGEDOWN:               editor_3d.adjust_height(-1.0)
		KEY_UP:    editor_3d.pan_camera(Vector3( 0, 0,-1))
		KEY_DOWN:  editor_3d.pan_camera(Vector3( 0, 0, 1))
		KEY_LEFT:  editor_3d.pan_camera(Vector3(-1, 0, 0))
		KEY_RIGHT: editor_3d.pan_camera(Vector3( 1, 0, 0))
		KEY_1: _select_tool_by_idx(0)
		KEY_2: _select_tool_by_idx(1)
		KEY_3: _select_tool_by_idx(2)
		KEY_4: _select_tool_by_idx(3)
		KEY_5: _select_tool_by_idx(4)
		KEY_6: _select_tool_by_idx(5)
		KEY_Z:
			if event.ctrl_pressed and event.shift_pressed: editor_3d.redo()
			elif event.ctrl_pressed:                       editor_3d.undo()
		KEY_Y:
			if event.ctrl_pressed: editor_3d.redo()
		KEY_C:
			if event.ctrl_pressed: editor_3d.copy_selected()
		KEY_V:
			if event.ctrl_pressed: editor_3d.paste_selected()
		KEY_F:      editor_3d.reset_camera()
		KEY_ESCAPE: editor_3d.clear_selection()
		KEY_TAB:
			if editor_3d.active_layer == MD.LAYER_BASE:
				_set_active_layer(MD.LAYER_OVERLAY)
			else:
				_set_active_layer(MD.LAYER_BASE)

func _select_tool_by_idx(idx: int) -> void:
	if idx >= _tool_buttons.size(): return
	_tool_buttons[idx].button_pressed = true
	_select_tool(idx)

# ══════════════════════════════════════════════════════════════════════════════
# UI BUILD — RIGHT PANEL IS OUTSIDE THE HBOX
# ══════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Root VBox : top bar | center | bottom bar
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root_vbox)

	root_vbox.add_child(_build_top_bar())

	# ── Center area: a plain Control that fills vertically ────────────────────
	var center := Control.new()
	center.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(center)

	# Left sidebar + viewport in an HBox that stops RIGHT_PANEL_W before the right edge
	var center_hbox := HBoxContainer.new()
	center_hbox.anchor_left   = 0.0
	center_hbox.anchor_top    = 0.0
	center_hbox.anchor_right  = 1.0
	center_hbox.anchor_bottom = 1.0
	center_hbox.offset_right  = -RIGHT_PANEL_W   # <== leaves room for the right panel
	center_hbox.add_theme_constant_override("separation", 0)
	center.add_child(center_hbox)

	_side_bar = _build_side_bar()
	_side_bar.custom_minimum_size = Vector2(220, 0)
	_side_bar.size_flags_horizontal = 0
	_side_bar.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.add_child(_side_bar)

	var vp_wrapper := _build_viewport_wrapper()
	vp_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_wrapper.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.add_child(vp_wrapper)

	# ── RIGHT PANEL — positioned absolutely, pinned to right edge ─────────────
	var right_panel := _build_right_camera_panel()
	right_panel.anchor_left   = 1.0
	right_panel.anchor_top    = 0.0
	right_panel.anchor_right  = 1.0
	right_panel.anchor_bottom = 1.0
	right_panel.offset_left   = -RIGHT_PANEL_W
	right_panel.offset_top    = 0
	right_panel.offset_right  = 0
	right_panel.offset_bottom = 0
	center.add_child(right_panel)

	_bottom_bar = _build_bottom_bar()
	root_vbox.add_child(_bottom_bar)

	_new_map_dialog = _build_new_map_dialog()
	add_child(_new_map_dialog)

func _build_viewport_wrapper() -> Control:
	var wrapper := MarginContainer.new()
	wrapper.name = "ViewportWrapper"
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		wrapper.add_theme_constant_override(side, 0)
	wrapper.clip_contents = true
	_vp_container = SubViewportContainer.new()
	_vp_container.name = "SVPContainer"; _vp_container.stretch = true
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_vp_container.add_child(editor_3d.get_sub_viewport())
	_vp_container.gui_input.connect(_on_viewport_input)
	wrapper.add_child(_vp_container)
	return wrapper

func _on_viewport_input(event: InputEvent) -> void:
	editor_3d.handle_viewport_input(event)

# ══════════════════════════════════════════════════════════════════════════════
# RIGHT PANEL — CAMERA + TRIGGERS
# ══════════════════════════════════════════════════════════════════════════════
func _build_right_camera_panel() -> PanelContainer:
	var panel := PanelContainer.new(); panel.name = "RightPanel"

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)

	# ── Camera ────────────────────────────────────────────────────────────────
	var cam_title := Label.new(); cam_title.text = "📷 Caméra"
	cam_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cam_title.add_theme_font_size_override("font_size", 14); vbox.add_child(cam_title)
	vbox.add_child(HSeparator.new())

	var center_btn := Button.new(); center_btn.text = "🎯 Centrer [F]"
	center_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_btn.pressed.connect(func(): editor_3d.reset_camera()); vbox.add_child(center_btn)

	vbox.add_child(_cam_lbl("Élévation"))
	var elev_row := HBoxContainer.new(); elev_row.alignment = BoxContainer.ALIGNMENT_CENTER
	elev_row.add_theme_constant_override("separation", 4)
	var btn_up := Button.new(); btn_up.text = "▲+10°"; btn_up.custom_minimum_size = Vector2(58, 28)
	btn_up.pressed.connect(func(): editor_3d.elevate_camera(10.0))
	var btn_dn := Button.new(); btn_dn.text = "▼-10°"; btn_dn.custom_minimum_size = Vector2(58, 28)
	btn_dn.pressed.connect(func(): editor_3d.elevate_camera(-10.0))
	elev_row.add_child(btn_up); elev_row.add_child(btn_dn); vbox.add_child(elev_row)

	vbox.add_child(_cam_lbl("Zoom"))
	var zoom_row := HBoxContainer.new(); zoom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	zoom_row.add_theme_constant_override("separation", 4)
	var zi := Button.new(); zi.text = "🔍+"; zi.custom_minimum_size = Vector2(50, 28)
	zi.pressed.connect(func(): editor_3d.zoom_in())
	var zo := Button.new(); zo.text = "🔍−"; zo.custom_minimum_size = Vector2(50, 28)
	zo.pressed.connect(func(): editor_3d.zoom_out())
	zoom_row.add_child(zi); zoom_row.add_child(zo); vbox.add_child(zoom_row)

	vbox.add_child(_cam_lbl("Vue depuis…"))
	vbox.add_child(_build_compass_rose())
	vbox.add_child(HSeparator.new())

	# Toggles
	var grid_chk := CheckButton.new(); grid_chk.text = "Grille"; grid_chk.button_pressed = true
	grid_chk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_chk.toggled.connect(func(on): editor_3d.toggle_grid(on)); vbox.add_child(grid_chk)

	var trig_chk := CheckButton.new(); trig_chk.text = "Triggers"; trig_chk.button_pressed = true
	trig_chk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trig_chk.toggled.connect(func(on): editor_3d.toggle_triggers_visible(on)); vbox.add_child(trig_chk)

	var test_chk := CheckButton.new(); test_chk.text = "Mode Test"
	test_chk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_chk.toggled.connect(func(on): editor_3d.toggle_test_mode(on)); vbox.add_child(test_chk)

	vbox.add_child(HSeparator.new())

	# ── Triggers ──────────────────────────────────────────────────────────────
	var trig_title := Label.new(); trig_title.text = "⚡ Triggers"
	trig_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trig_title.add_theme_font_size_override("font_size", 14); vbox.add_child(trig_title)
	vbox.add_child(HSeparator.new())

	_trigger_type_option = OptionButton.new()
	_trigger_type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for t_type in MD.TriggerType.values():
		var icon : String = MD.TRIGGER_ICONS.get(t_type, "")
		var tname : String = MD.TRIGGER_NAMES.get(t_type, "?")
		_trigger_type_option.add_item("%s %s" % [icon, tname], t_type)
	_trigger_type_option.item_selected.connect(_on_trigger_type_selected)
	vbox.add_child(_trigger_type_option)

	var place_btn := Button.new(); place_btn.text = "⚡ Placer [6]"
	place_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	place_btn.pressed.connect(func():
		_select_tool_by_idx(5)
		_on_trigger_type_selected(_trigger_type_option.selected))
	vbox.add_child(place_btn)

	var rm_btn := Button.new(); rm_btn.text = "🗑 Supprimer"
	rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rm_btn.pressed.connect(func():
		editor_3d.set_pending_trigger(MD.TriggerType.NONE)
		_select_tool_by_idx(5)
		_status_label.text = "Cliquez pour supprimer un trigger")
	vbox.add_child(rm_btn)

	_trigger_id_edit = LineEdit.new()
	_trigger_id_edit.placeholder_text = "ID du trigger"
	_trigger_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_trigger_id_edit)

	vbox.add_child(HSeparator.new())

	# ── Tileset config ────────────────────────────────────────────────────────
	var ts_lbl := Label.new(); ts_lbl.text = "📋 Config Tileset"
	ts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ts_lbl.add_theme_font_size_override("font_size", 13); vbox.add_child(ts_lbl)

	var save_ts := Button.new(); save_ts.text = "💾 Sauver configs"
	save_ts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_ts.pressed.connect(_save_tileset_configs); vbox.add_child(save_ts)

	var load_ts := Button.new(); load_ts.text = "📂 Charger configs"
	load_ts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_ts.pressed.connect(_load_tileset_configs); vbox.add_child(load_ts)

	# Spacer
	var sp := Control.new(); sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(sp)
	return panel

func _on_trigger_type_selected(idx: int) -> void:
	var type_id := _trigger_type_option.get_item_id(idx)
	editor_3d.set_pending_trigger(type_id)
	if type_id != MD.TriggerType.NONE:
		_select_tool_by_idx(5)
	var tname : String = MD.TRIGGER_NAMES.get(type_id, "?")
	_status_label.text = "Trigger : %s — cliquez sur une tuile" % tname

func _build_compass_rose() -> GridContainer:
	var grid := GridContainer.new(); grid.columns = 3
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	var cells : Array = [
		["↖",315.0,"NO"],["↑",0.0,"N"],["↗",45.0,"NE"],
		["←",270.0,"O"],["⊙",-1.0,"Reset"],["→",90.0,"E"],
		["↙",225.0,"SO"],["↓",180.0,"S"],["↘",135.0,"SE"]]
	for cell in cells:
		var btn := Button.new(); btn.text = cell[0]
		btn.custom_minimum_size = Vector2(38, 32); btn.tooltip_text = cell[2]
		if cell[1] < 0.0:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
			btn.pressed.connect(func(): editor_3d.reset_camera())
		else:
			var az : float = cell[1]
			btn.pressed.connect(func(): editor_3d.look_from_azimuth(az))
		grid.add_child(btn)
	return grid

static func _cam_lbl(text: String) -> Label:
	var l := Label.new(); l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.6, 0.82, 1.0))
	l.add_theme_font_size_override("font_size", 12); return l

# ══════════════════════════════════════════════════════════════════════════════
# TOP BAR
# ══════════════════════════════════════════════════════════════════════════════
func _build_top_bar() -> Control:
	var bar := PanelContainer.new(); bar.custom_minimum_size = Vector2(0, 44)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 3); bar.add_child(hbox)

	_add_btn(hbox, "📄 Nouveau", func(): show_new_map_dialog(), Color(0.25, 0.45, 0.75))
	_add_btn(hbox, "💾 Sauver",  func(): _save_map(),           Color(0.25, 0.45, 0.75))
	_add_btn(hbox, "📂 Ouvrir",  func(): _load_map(),           Color(0.25, 0.45, 0.75))
	_add_separator(hbox)
	_add_btn(hbox, "↶ Annuler",  func(): editor_3d.undo(), Color(0.30, 0.30, 0.45))
	_add_btn(hbox, "↷ Rétablir", func(): editor_3d.redo(), Color(0.30, 0.30, 0.45))
	_add_separator(hbox)

	_tool_buttons.clear()
	var bg := ButtonGroup.new()
	for ti in E3.Tool.values():
		var ti_val : int = ti
		var btn := Button.new()
		btn.text = TOOL_ICONS[ti]; btn.toggle_mode = true; btn.button_group = bg
		btn.tooltip_text = TOOL_NAMES[ti] + "  [%d]" % (ti + 1)
		btn.custom_minimum_size = Vector2(36, 0)
		btn.pressed.connect(func(): _select_tool(ti_val))
		if ti == E3.Tool.SHARED_CORNER: btn.button_pressed = true
		hbox.add_child(btn); _tool_buttons.append(btn)
	_add_separator(hbox)

	_add_btn(hbox, "📋 Copier",  func(): editor_3d.copy_selected(),  Color(0.35, 0.35, 0.20))
	_add_btn(hbox, "📌 Coller",  func(): editor_3d.paste_selected(), Color(0.35, 0.35, 0.20))
	_add_separator(hbox)
	_add_btn(hbox, "⊞ Subdiv.",  func(): _subdivide_selected(), Color(0.50, 0.30, 0.65))
	_add_btn(hbox, "⊟ Fusion",   func(): _merge_selected(),     Color(0.50, 0.30, 0.65))
	_add_separator(hbox)

	var snap_btn := CheckButton.new(); snap_btn.text = "Snap ↕"
	snap_btn.tooltip_text = "Arrondir les hauteurs au pas (%.2f)" % MD.HEIGHT_STEP
	snap_btn.toggled.connect(func(on): editor_3d.set_snap(on)); hbox.add_child(snap_btn)
	_add_separator(hbox)

	_add_btn(hbox, "⬇ HMap", func(): _import_heightmap_dialog(), Color(0.30, 0.40, 0.30))
	_add_btn(hbox, "⬆ HMap", func(): _export_heightmap_dialog(), Color(0.30, 0.40, 0.30))
	_add_separator(hbox)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_status_label.text = "Prêt"
	hbox.add_child(_status_label)
	return bar

func _select_tool(ti: int) -> void:
	editor_3d.set_tool(ti)
	_status_label.text = "Outil : " + TOOL_NAMES[ti]

# ══════════════════════════════════════════════════════════════════════════════
# BOTTOM BAR
# ══════════════════════════════════════════════════════════════════════════════
func _build_bottom_bar() -> Control:
	var bar := PanelContainer.new(); bar.custom_minimum_size = Vector2(0, 50)
	var hbox := HBoxContainer.new(); hbox.name = "BottomHBox"
	hbox.add_theme_constant_override("separation", 6); bar.add_child(hbox)

	hbox.add_child(_make_label("Hauteur :"))
	_add_btn(hbox, "▲+0.25", func(): editor_3d.adjust_height( MD.HEIGHT_STEP), Color(0.25, 0.60, 0.25))
	_add_btn(hbox, "▼-0.25", func(): editor_3d.adjust_height(-MD.HEIGHT_STEP), Color(0.60, 0.25, 0.25))
	_add_btn(hbox, "+1.0",   func(): editor_3d.adjust_height( 1.0), Color(0.25, 0.50, 0.25))
	_add_btn(hbox, "-1.0",   func(): editor_3d.adjust_height(-1.0), Color(0.50, 0.25, 0.25))
	_add_separator(hbox)

	hbox.add_child(_make_label("Couche :"))
	var lg := ButtonGroup.new()
	_layer_btn_base = Button.new()
	_layer_btn_base.text = "Base"; _layer_btn_base.toggle_mode = true
	_layer_btn_base.button_group = lg; _layer_btn_base.button_pressed = true
	_layer_btn_base.custom_minimum_size = Vector2(60, 0)
	_layer_btn_base.pressed.connect(func(): _set_active_layer(MD.LAYER_BASE))
	hbox.add_child(_layer_btn_base)

	_layer_btn_overlay = Button.new()
	_layer_btn_overlay.text = "Overlay"; _layer_btn_overlay.toggle_mode = true
	_layer_btn_overlay.button_group = lg
	_layer_btn_overlay.tooltip_text = "[Tab]"
	_layer_btn_overlay.custom_minimum_size = Vector2(70, 0)
	_layer_btn_overlay.pressed.connect(func(): _set_active_layer(MD.LAYER_OVERLAY))
	hbox.add_child(_layer_btn_overlay)
	_add_separator(hbox)

	hbox.add_child(_make_label("UV :"))
	_uv_scale_spin = SpinBox.new()
	_uv_scale_spin.min_value = 0.1; _uv_scale_spin.max_value = 16.0
	_uv_scale_spin.step = 0.1; _uv_scale_spin.value = 1.0
	_uv_scale_spin.custom_minimum_size = Vector2(70, 0)
	_uv_scale_spin.value_changed.connect(_on_uv_scale_changed)
	hbox.add_child(_uv_scale_spin)
	_add_separator(hbox)

	_add_btn(hbox, "✗ Déselect.", func(): editor_3d.clear_selection(), Color(0.4, 0.4, 0.4))
	_add_separator(hbox)

	var info := Label.new(); info.name = "SelInfo"
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.text = "Aucune sélection"
	info.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	hbox.add_child(info)
	return bar

func _set_active_layer(layer: int) -> void:
	editor_3d.set_active_layer(layer)
	if layer == MD.LAYER_OVERLAY:
		_layer_btn_overlay.button_pressed = true
	else:
		_layer_btn_base.button_pressed = true

func _on_uv_scale_changed(v: float) -> void:
	var layer := editor_3d.active_layer
	for sf in editor_3d.selected_faces:
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube: cube.get_face_config(sf["face_idx"], layer).uv_scale = v
	for cr in editor_3d.selected_corners:
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		if cube:
			for fi in 6: cube.get_face_config(fi, layer).uv_scale = v

func _on_selection_changed() -> void:
	var bar := _bottom_bar.get_node_or_null("BottomHBox")
	if bar == null: return
	var lbl := bar.get_node_or_null("SelInfo") as Label
	if lbl == null: return
	var nc := editor_3d.selected_corners.size()
	var nf := editor_3d.selected_faces.size()
	var lt := " [OV]" if editor_3d.active_layer == MD.LAYER_OVERLAY else " [BASE]"
	if nc > 0:    lbl.text = "🔵 %d coin(s)%s" % [nc, lt]
	elif nf > 0:  lbl.text = "🟦 %d face(s)%s" % [nf, lt]
	else:         lbl.text = "Aucune sélection"
	_update_minimap()

# ══════════════════════════════════════════════════════════════════════════════
# LEFT SIDEBAR
# ══════════════════════════════════════════════════════════════════════════════
func _build_side_bar() -> Control:
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4); panel.add_child(vbox)

	var title := Label.new(); title.text = "Textures"
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; vbox.add_child(title)

	# Cell size toggle
	var size_lbl := Label.new(); size_lbl.text = "Taille cellule :"
	size_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	vbox.add_child(size_lbl)

	var size_row := HBoxContainer.new()
	size_row.alignment = BoxContainer.ALIGNMENT_CENTER
	size_row.add_theme_constant_override("separation", 4); vbox.add_child(size_row)
	var sg := ButtonGroup.new()
	_size_btn_16 = Button.new(); _size_btn_16.text = "16px"
	_size_btn_16.toggle_mode = true; _size_btn_16.button_group = sg
	_size_btn_16.custom_minimum_size = Vector2(60, 26)
	_size_btn_16.pressed.connect(func(): _set_cell_size(16))
	size_row.add_child(_size_btn_16)
	_size_btn_32 = Button.new(); _size_btn_32.text = "32px"
	_size_btn_32.toggle_mode = true; _size_btn_32.button_group = sg
	_size_btn_32.button_pressed = true; _size_btn_32.custom_minimum_size = Vector2(60, 26)
	_size_btn_32.pressed.connect(func(): _set_cell_size(32))
	size_row.add_child(_size_btn_32)

	# ── Favoris row ───────────────────────────────────────────────────────────
	var fav_row := HBoxContainer.new()
	fav_row.add_theme_constant_override("separation", 4); vbox.add_child(fav_row)

	var fav_chk := CheckButton.new(); fav_chk.text = "⭐ Favoris"
	fav_chk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fav_chk.toggled.connect(func(on):
		_show_only_favorites = on
		_refresh_texture_grid())
	fav_row.add_child(fav_chk)

	var export_btn := Button.new(); export_btn.text = "⬆ Export ⭐"
	export_btn.tooltip_text = "Export favoris → res://export/tileset_axisborn_XXX.png"
	export_btn.pressed.connect(_export_favorites_png)
	fav_row.add_child(export_btn)

	# Import
	var import_btn := Button.new(); import_btn.text = "📂 Importer atlas…"
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.pressed.connect(_on_import_atlas); vbox.add_child(import_btn)

	# Scrollable texture grid
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_texture_grid_container = GridContainer.new()
	_texture_grid_container.columns = 4
	scroll.add_child(_texture_grid_container)

	_sel_tex_lbl = Label.new()
	_sel_tex_lbl.text = "Aucune texture"
	_sel_tex_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sel_tex_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(_sel_tex_lbl)
	vbox.add_child(HSeparator.new())

	# Minimap
	var mm := Label.new(); mm.text = "Minimap"
	mm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mm.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(mm)

	_minimap_rect = TextureRect.new()
	_minimap_rect.custom_minimum_size = Vector2(190, 190)
	_minimap_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_minimap_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_minimap_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	vbox.add_child(_minimap_rect)
	return panel

func _set_cell_size(sz: int) -> void:
	_atlas_cell_size = sz; _refresh_texture_grid()
	_status_label.text = "Cellule atlas : %d×%d px" % [sz, sz]

func _update_minimap() -> void:
	if _minimap_rect == null or map_data == null: return
	if map_data.grid_width == 0 or map_data.grid_height == 0: return
	var w := map_data.grid_width; var h := map_data.grid_height
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for tx in w:
		for ty in h:
			var td := map_data.get_tile(tx, ty)
			if td == null:
				img.set_pixel(tx, ty, Color(0.15, 0.15, 0.15)); continue
			var avg_h : float = 0.0
			if td.subdivided:
				for si in 4: avg_h += td.cubes[si].top_max()
				avg_h /= 4.0
			else:
				avg_h = td.cubes[0].top_max()
			var t := (avg_h - MD.MIN_H) / (MD.MAX_H - MD.MIN_H)
			var col := Color(t * 0.4 + 0.05, t * 0.60 + 0.15, t * 0.25 + 0.03, 1.0)
			# Orange tint for triggers
			var has_trig := false
			if td.subdivided:
				for si in 4:
					if td.cubes[si].trigger != null and td.cubes[si].trigger.type != MD.TriggerType.NONE:
						has_trig = true; break
			else:
				if td.cubes[0].trigger != null and td.cubes[0].trigger.type != MD.TriggerType.NONE:
					has_trig = true
			if has_trig:
				col = col.lerp(Color(1.0, 0.5, 0.0), 0.4)
			img.set_pixel(tx, ty, col)
	var sel_col := Color(0.2, 0.65, 1.0, 1.0)
	for cr in editor_3d.selected_corners:
		if cr["tx"] < w and cr["ty"] < h: img.set_pixel(cr["tx"], cr["ty"], sel_col)
	for sf in editor_3d.selected_faces:
		if sf["tx"] < w and sf["ty"] < h: img.set_pixel(sf["tx"], sf["ty"], sel_col)
	_minimap_rect.texture = ImageTexture.create_from_image(img)

# ══════════════════════════════════════════════════════════════════════════════
# FAVORITES
# ══════════════════════════════════════════════════════════════════════════════
func _fav_key(path: String, col: int, row: int) -> String:
	return "%s|%d|%d" % [path, col, row]

func _is_fav(path: String, col: int, row: int) -> bool:
	return _favorites.has(_fav_key(path, col, row))

func _toggle_fav(path: String, col: int, row: int, star: Label) -> void:
	var key := _fav_key(path, col, row)
	if _favorites.has(key):
		_favorites.erase(key)
		star.text = "☆"
		star.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.7))
		_status_label.text = "☆ Retiré des favoris (%d)" % _favorites.size()
	else:
		_favorites[key] = true
		star.text = "★"
		star.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
		_status_label.text = "★ Ajouté aux favoris (%d)" % _favorites.size()
	if _show_only_favorites:
		_refresh_texture_grid()

## Export all favorites into a single tileset PNG
func _export_favorites_png() -> void:
	if _favorites.is_empty():
		_status_label.text = "✗ Aucun favori à exporter"; return

	var fav_images : Array = []
	var cell_px : int = 32

	for fk in _favorites:
		var parts : PackedStringArray = fk.split("|")
		if parts.size() < 3: continue
		var fpath : String = parts[0]
		var fcol : int = int(parts[1])
		var frow : int = int(parts[2])

		# Find loaded atlas
		var tex : Texture2D = null
		var cfg : MD.TilesetConfig = null
		for atlas in _loaded_atlases:
			if atlas["path"] == fpath:
				tex = atlas["texture"]; cfg = atlas.get("config"); break
		if tex == null:
			tex = load(fpath) as Texture2D
			if tex == null: continue

		var src := tex.get_image()
		if src == null: continue

		var cs : int
		var px : int
		var py : int
		if cfg != null:
			cs = cfg.cell_size
			px = cfg.x_start + fcol * (cs + cfg.x_spacing)
			py = cfg.y_start + frow * (cs + cfg.y_spacing)
		else:
			cs = _atlas_cell_size
			px = fcol * cs; py = frow * cs

		cell_px = cs
		var ci := Image.create(cs, cs, false, Image.FORMAT_RGBA8)
		ci.blit_rect(src, Rect2i(px, py, cs, cs), Vector2i.ZERO)
		fav_images.append(ci)

	if fav_images.is_empty():
		_status_label.text = "✗ Aucune image trouvée"; return

	# Grid layout
	var count : int = fav_images.size()
	var gcols : int = ceili(sqrt(float(count)))
	var grows : int = ceili(float(count) / float(gcols))
	var ow : int = gcols * cell_px
	var oh : int = grows * cell_px
	var out := Image.create(ow, oh, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))

	for i in count:
		var gx : int = (i % gcols) * cell_px
		var gy : int = (i / gcols) * cell_px
		out.blit_rect(fav_images[i], Rect2i(0, 0, cell_px, cell_px), Vector2i(gx, gy))

	# Find next available filename in res://export/
	var edir := "res://export"
	if not DirAccess.dir_exists_absolute(edir):
		DirAccess.make_dir_recursive_absolute(edir)

	var idx := 1
	var opath := ""
	while idx <= 999:
		opath = "%s/tileset_axisborn_%03d.png" % [edir, idx]
		if not FileAccess.file_exists(opath): break
		idx += 1
	if idx > 999:
		_status_label.text = "✗ Trop de fichiers (max 999)"; return

	var err := out.save_png(opath)
	if err == OK:
		_status_label.text = "✓ %d favoris → %s (%dx%d)" % [count, opath.get_file(), ow, oh]
	else:
		_status_label.text = "✗ Erreur export : %d" % err

# ══════════════════════════════════════════════════════════════════════════════
# TEXTURE GRID WITH STAR HOVER
# ══════════════════════════════════════════════════════════════════════════════
func _refresh_texture_grid() -> void:
	for ch in _texture_grid_container.get_children(): ch.queue_free()

	for atlas in _loaded_atlases:
		var tex : Texture2D = atlas["texture"]
		var cfg : MD.TilesetConfig = atlas.get("config")
		var cols : int; var rows : int
		if cfg != null:
			var gs := cfg.get_grid_size(tex.get_width(), tex.get_height())
			cols = gs.x; rows = gs.y
		else:
			cols = maxi(1, tex.get_width() / _atlas_cell_size)
			rows = maxi(1, tex.get_height() / _atlas_cell_size)
		atlas["cols"] = cols; atlas["rows"] = rows

		for r in rows:
			for c in cols:
				var ap : String = atlas["path"]
				var faved := _is_fav(ap, c, r)
				if _show_only_favorites and not faved: continue
				_make_tex_cell(tex, ap, c, r, cfg, faved)

func _make_tex_cell(tex: Texture2D, ap: String, col: int, row: int,
					cfg: MD.TilesetConfig, faved: bool) -> void:
	# Container 48x48
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(48, 48)

	var cs : int = cfg.cell_size if cfg else _atlas_cell_size
	var px_x : int = (cfg.x_start + col * (cs + cfg.x_spacing)) if cfg else (col * cs)
	var px_y : int = (cfg.y_start + row * (cs + cfg.y_spacing)) if cfg else (row * cs)

	# Main texture button (fills the cell)
	var btn := Button.new()
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var at := AtlasTexture.new(); at.atlas = tex
	at.region = Rect2(px_x, px_y, cs, cs)
	var tr := TextureRect.new(); tr.texture = at
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_child(tr)

	# Capture for lambdas
	var ap_c : String = ap
	var col_c : int = col
	var row_c : int = row
	var cfg_c = cfg
	btn.pressed.connect(func(): _on_tex_cell_selected(ap_c, col_c, row_c, cfg_c))
	btn.tooltip_text = "%s [%d,%d] %dpx" % [ap.get_file(), col, row, cs]
	cell.add_child(btn)

	# ── Star label (top-right corner) ─────────────────────────────────────────
	var star := Label.new()
	star.text = "★" if faved else "☆"
	star.add_theme_font_size_override("font_size", 16)
	star.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.1) if faved else Color(0.8, 0.8, 0.8, 0.7))
	star.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	star.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	star.position = Vector2(30, 0)
	star.size = Vector2(18, 18)
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star.visible = faved   # visible when fav, hidden otherwise
	cell.add_child(star)

	# Invisible click zone over the star
	var star_btn := Button.new()
	star_btn.flat = true
	star_btn.self_modulate = Color(1, 1, 1, 0)   # fully transparent
	star_btn.position = Vector2(28, 0)
	star_btn.size = Vector2(20, 20)
	star_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	star_btn.tooltip_text = "⭐ Favori"
	var star_ref : Label = star
	star_btn.pressed.connect(func(): _toggle_fav(ap_c, col_c, row_c, star_ref))
	cell.add_child(star_btn)

	# Show star on hover, hide on leave (keep visible if fav)
	btn.mouse_entered.connect(func(): star.visible = true)
	btn.mouse_exited.connect(func():
		if not _is_fav(ap_c, col_c, row_c):
			star.visible = false)

	_texture_grid_container.add_child(cell)

func _on_tex_cell_selected(atlas_path: String, col: int, row: int, cfg) -> void:
	_selected_atlas_path = atlas_path
	_selected_atlas_col = col
	_selected_atlas_row = row

	var fc := MD.FaceConfig.new()
	fc.atlas_path = atlas_path; fc.atlas_col = col; fc.atlas_row = row
	fc.uv_scale = _uv_scale_spin.value if _uv_scale_spin else 1.0

	if cfg != null and cfg is MD.TilesetConfig:
		fc.cell_size = cfg.cell_size
		fc.tileset_x_start = cfg.x_start
		fc.tileset_y_start = cfg.y_start
		fc.tileset_x_spacing = cfg.x_spacing
		fc.tileset_y_spacing = cfg.y_spacing
	else:
		fc.cell_size = _atlas_cell_size

	editor_3d.set_pending_texture(fc)

	var ln := "OV" if editor_3d.active_layer == MD.LAYER_OVERLAY else "BASE"
	if _sel_tex_lbl:
		_sel_tex_lbl.text = "✓ [%s] %s\n[%d,%d] · %dpx" % [ln, atlas_path.get_file(), col, row, fc.cell_size]
	_status_label.text = "🖌 [%s] %s [%d,%d] · %dpx" % [ln, atlas_path.get_file(), col, row, fc.cell_size]
	_select_tool_by_idx(2)

# ══════════════════════════════════════════════════════════════════════════════
# HEIGHTMAP
# ══════════════════════════════════════════════════════════════════════════════
func _import_heightmap_dialog() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = ["*.png, *.jpg, *.jpeg, *.bmp ; Images"]
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String): _import_heightmap(path); dlg.queue_free())

func _import_heightmap(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null: _status_label.text = "✗ " + path.get_file(); return
	img.convert(Image.FORMAT_L8)
	var iw := img.get_width(); var ih := img.get_height()
	var w := map_data.grid_width; var h := map_data.grid_height
	for tx in w:
		for ty in h:
			var px := clampi(int(float(tx) / float(w) * iw), 0, iw - 1)
			var py := clampi(int(float(ty) / float(h) * ih), 0, ih - 1)
			var height := snappedf(MD.MIN_H + img.get_pixel(px, py).r * (MD.MAX_H - MD.MIN_H), MD.HEIGHT_STEP)
			var td := map_data.get_tile(tx, ty)
			if td == null: continue
			if td.subdivided:
				for si in 4:
					for ci in 4: td.cubes[si].corners[ci] = height
			else:
				for ci in 4: td.cubes[0].corners[ci] = height
	editor_3d.build_all()
	_status_label.text = "✓ Heightmap : " + path.get_file()

func _export_heightmap_dialog() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = ["*.png ; PNG"]; dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String): _export_heightmap(path); dlg.queue_free())

func _export_heightmap(path: String) -> void:
	var w := map_data.grid_width; var h := map_data.grid_height
	if w == 0 or h == 0: return
	var img := Image.create(w, h, false, Image.FORMAT_L8)
	for tx in w:
		for ty in h:
			var td := map_data.get_tile(tx, ty)
			var height := MD.MIN_H
			if td:
				if td.subdivided:
					var mx := 0.0
					for si in 4: mx = maxf(mx, td.cubes[si].top_max())
					height = mx
				else:
					height = td.cubes[0].top_max()
			img.set_pixel(tx, ty, Color.from_hsv(0, 0, clampf((height - MD.MIN_H) / (MD.MAX_H - MD.MIN_H), 0, 1)))
	if img.save_png(path) == OK:
		_status_label.text = "✓ Heightmap → " + path.get_file()
	else:
		_status_label.text = "✗ Erreur export"

# ══════════════════════════════════════════════════════════════════════════════
# ATLAS IMPORT + TILESET CONFIG
# ══════════════════════════════════════════════════════════════════════════════
func _on_import_atlas() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dlg.filters = ["*.png, *.jpg, *.jpeg ; Images"]
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.files_selected.connect(func(paths: PackedStringArray):
		dlg.queue_free()
		for p in paths: _show_tileset_config_dialog(p))

func _show_tileset_config_dialog(path: String) -> void:
	var win := Window.new(); win.title = "Config : " + path.get_file()
	win.size = Vector2i(420, 360)
	win.close_requested.connect(func(): win.queue_free())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	win.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10); margin.add_child(vbox)

	var vt := Label.new(); vt.text = "📋 Configuration du tileset"
	vt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vt.add_theme_font_size_override("font_size", 15); vbox.add_child(vt)

	var fl := Label.new(); fl.text = path.get_file()
	fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fl.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0)); vbox.add_child(fl)
	vbox.add_child(HSeparator.new())

	var existing := map_data.get_tileset_config(path)
	var cs_sp := _make_spin_row(vbox, "Taille cellule (px) :", 8, 128,
		existing.cell_size if existing else _atlas_cell_size)
	var xs_sp := _make_spin_row(vbox, "X départ (px) :", 0, 512,
		existing.x_start if existing else 0)
	var ys_sp := _make_spin_row(vbox, "Y départ (px) :", 0, 512,
		existing.y_start if existing else 0)
	var xsp_sp := _make_spin_row(vbox, "X espacement (px) :", 0, 64,
		existing.x_spacing if existing else 0)
	var ysp_sp := _make_spin_row(vbox, "Y espacement (px) :", 0, 64,
		existing.y_spacing if existing else 0)

	vbox.add_child(HSeparator.new())
	var br := HBoxContainer.new(); br.alignment = BoxContainer.ALIGNMENT_CENTER
	br.add_theme_constant_override("separation", 16); vbox.add_child(br)

	var cancel := Button.new(); cancel.text = "Annuler"
	cancel.pressed.connect(func(): win.queue_free()); br.add_child(cancel)

	var ok := Button.new(); ok.text = "✓ Importer"
	ok.pressed.connect(func():
		var cfg := MD.TilesetConfig.new()
		cfg.path = path; cfg.cell_size = int(cs_sp.value)
		cfg.x_start = int(xs_sp.value); cfg.y_start = int(ys_sp.value)
		cfg.x_spacing = int(xsp_sp.value); cfg.y_spacing = int(ysp_sp.value)
		map_data.add_tileset_config(cfg)
		_load_atlas_with_cfg(path, cfg)
		win.queue_free()
		_status_label.text = "✓ Atlas : %s (%dpx, offset %d,%d, gap %d,%d)" % [
			path.get_file(), cfg.cell_size, cfg.x_start, cfg.y_start, cfg.x_spacing, cfg.y_spacing])
	br.add_child(ok)

	add_child(win); win.popup_centered(Vector2i(420, 360))

func _make_spin_row(parent: VBoxContainer, label_text: String,
					min_val: int, max_val: int, default_val: int) -> SpinBox:
	var row := HBoxContainer.new()
	var lbl := Label.new(); lbl.text = label_text; lbl.custom_minimum_size = Vector2(170, 0)
	row.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = min_val; spin.max_value = max_val
	spin.value = default_val; spin.step = 1
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin); parent.add_child(row)
	return spin

func _load_atlas_with_cfg(path: String, cfg: MD.TilesetConfig) -> void:
	var img : Texture2D = load(path) as Texture2D
	if img == null:
		var raw := Image.load_from_file(path)
		if raw == null: return
		img = ImageTexture.create_from_image(raw)
	if img == null: return
	for i in range(_loaded_atlases.size() - 1, -1, -1):
		if _loaded_atlases[i]["path"] == path: _loaded_atlases.remove_at(i)
	var gs := cfg.get_grid_size(img.get_width(), img.get_height())
	_loaded_atlases.append({
		"path": path, "texture": img,
		"cols": gs.x, "rows": gs.y, "config": cfg
	})
	_refresh_texture_grid()

func _load_atlas_file(path: String) -> void:
	var cfg := map_data.get_tileset_config(path)
	if cfg != null: _load_atlas_with_cfg(path, cfg); return
	var img := load(path) as Texture2D
	if img == null:
		var raw := Image.load_from_file(path)
		if raw == null: return
		img = ImageTexture.create_from_image(raw)
	if img == null: return
	for a in _loaded_atlases:
		if a["path"] == path: return
	_loaded_atlases.append({"path": path, "texture": img,
		"cols": maxi(1, img.get_width() / _atlas_cell_size),
		"rows": maxi(1, img.get_height() / _atlas_cell_size),
		"config": null})
	_refresh_texture_grid()

func _scan_texture_folder() -> void:
	var dir := DirAccess.open("res://assets/textures/")
	if dir == null: return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".png") or fname.ends_with(".jpg"):
			_load_atlas_file("res://assets/textures/" + fname)
		fname = dir.get_next()

# ══════════════════════════════════════════════════════════════════════════════
# TILESET CONFIG SAVE / LOAD
# ══════════════════════════════════════════════════════════════════════════════
func _save_tileset_configs() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = ["*.json ; JSON"]; dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		if map_data.save_tileset_configs(path):
			_status_label.text = "✓ Configs sauvées : " + path.get_file()
		else:
			_status_label.text = "✗ Erreur"
		dlg.queue_free())

func _load_tileset_configs() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = ["*.json ; JSON"]; dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		if map_data.load_tileset_configs(path):
			_status_label.text = "✓ Configs chargées : " + path.get_file()
			for cfg in map_data.tileset_configs:
				_load_atlas_with_cfg(cfg.path, cfg)
		else:
			_status_label.text = "✗ Erreur"
		dlg.queue_free())

# ══════════════════════════════════════════════════════════════════════════════
# NEW MAP
# ══════════════════════════════════════════════════════════════════════════════
func show_new_map_dialog() -> void:
	if is_instance_valid(_new_map_dialog):
		_new_map_dialog.popup_centered(Vector2i(360, 240))

func _build_new_map_dialog() -> Window:
	var win := Window.new(); win.title = "Nouvelle carte"
	win.size = Vector2i(360, 260); win.unresizable = true
	win.close_requested.connect(func(): win.hide())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox); win.add_child(margin)

	var lbl := Label.new(); lbl.text = "Créer une nouvelle carte"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16); vbox.add_child(lbl)

	var wh := HBoxContainer.new(); wh.add_child(_make_label("Largeur (X) :"))
	var ws := SpinBox.new(); ws.min_value = 2; ws.max_value = 64; ws.value = 10
	ws.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wh.add_child(ws); vbox.add_child(wh)

	var hh := HBoxContainer.new(); hh.add_child(_make_label("Hauteur (Z) :"))
	var hs := SpinBox.new(); hs.min_value = 2; hs.max_value = 64; hs.value = 10
	hs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(hs); vbox.add_child(hh)

	vbox.add_child(HSeparator.new())
	var br := HBoxContainer.new(); br.alignment = BoxContainer.ALIGNMENT_CENTER
	br.add_theme_constant_override("separation", 16); vbox.add_child(br)

	var cancel := Button.new(); cancel.text = "Annuler"
	cancel.pressed.connect(func(): win.hide()); br.add_child(cancel)
	var ok := Button.new(); ok.text = "✓  Créer"
	ok.pressed.connect(func():
		win.hide(); _create_new_map(int(ws.value), int(hs.value)))
	br.add_child(ok)
	return win

func _create_new_map(w: int, h: int) -> void:
	map_data.init_grid(w, h); editor_3d.build_all(); _update_minimap()
	_status_label.text = "✓ Carte %d×%d créée" % [w, h]

# ══════════════════════════════════════════════════════════════════════════════
# SUBDIVISION
# ══════════════════════════════════════════════════════════════════════════════
func _subdivide_selected() -> void:
	var done := {}
	for cr in editor_3d.selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k): done[k] = true; editor_3d.subdivide_tile(cr["tx"], cr["ty"])
	for sf in editor_3d.selected_faces:
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k): done[k] = true; editor_3d.subdivide_tile(sf["tx"], sf["ty"])
	if done.is_empty(): _status_label.text = "Sélectionnez d'abord une tuile."

func _merge_selected() -> void:
	var done := {}
	for cr in editor_3d.selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k): done[k] = true; editor_3d.merge_tile(cr["tx"], cr["ty"])
	for sf in editor_3d.selected_faces:
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k): done[k] = true; editor_3d.merge_tile(sf["tx"], sf["ty"])
	if done.is_empty(): _status_label.text = "Sélectionnez d'abord une tuile."

# ══════════════════════════════════════════════════════════════════════════════
# SAVE / LOAD MAP
# ══════════════════════════════════════════════════════════════════════════════
func _save_map() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = ["*.json ; Map JSON"]; dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f: f.store_string(map_data.to_json()); f.close()
		_status_label.text = "✓ Sauvé : " + path.get_file(); dlg.queue_free())

func _load_map() -> void:
	var dlg := FileDialog.new(); dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = ["*.json ; Map JSON"]; dlg.access = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var ok := map_data.from_json(f.get_as_text()); f.close()
			if ok:
				editor_3d.build_all(); _update_minimap()
				for cfg in map_data.tileset_configs:
					_load_atlas_with_cfg(cfg.path, cfg)
			_status_label.text = ("✓ Chargé : " if ok else "✗ Erreur : ") + path.get_file()
		dlg.queue_free())

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════
static func _make_label(text: String) -> Label:
	var l := Label.new(); l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER; return l

static func _add_btn(parent: Control, text: String, cb: Callable,
					 color: Color = Color(0.3, 0.3, 0.35)) -> Button:
	var btn := Button.new(); btn.text = text
	var style := StyleBoxFlat.new(); style.bg_color = color
	style.corner_radius_top_left = 4; style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4; style.corner_radius_bottom_right = 4
	style.content_margin_left = 6; style.content_margin_right = 6
	style.content_margin_top = 3; style.content_margin_bottom = 3
	btn.add_theme_stylebox_override("normal", style)
	btn.pressed.connect(cb); parent.add_child(btn); return btn

static func _add_separator(parent: Control) -> void:
	parent.add_child(VSeparator.new())
