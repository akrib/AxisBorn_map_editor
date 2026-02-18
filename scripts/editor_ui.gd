## editor_ui.gd  –  Version 2.4
## Fix label texture : référence directe (_sel_tex_lbl) au lieu de get_node_or_null.
## Fix clic texture : Button + TextureRect enfant avec MOUSE_FILTER_IGNORE.
## Toggle 16px / 32px pour découpage atlas.
extends Control

const MD := preload("res://scripts/map_data.gd")
const E3 := preload("res://scripts/editor_3d.gd")

# ══════════════════════════════════════════════════════════════════════════════
# RÉFÉRENCES
# ══════════════════════════════════════════════════════════════════════════════
var map_data  : MD
var editor_3d : E3

var _vp_container   : SubViewportContainer
var _bottom_bar     : Control
var _side_bar       : Control
var _new_map_dialog : Window
var _tool_buttons   : Array  = []
var _status_label   : Label

## Référence directe au label "texture active" — get_node_or_null("SelTexLbl")
## ne fonctionnait pas car le label est enfant d'un VBoxContainer intermédiaire.
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

const TOOL_NAMES := [
	"4 Coins partagés", "Hauteur de face", "Texture", "Coin unique", "Pipette"
]
const TOOL_ICONS := ["⊕", "↕", "🖌", "◉", "💧"]

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
	editor_3d.cube_hovered.connect(func(_a,_b,_c): pass)
	_scan_texture_folder()
	editor_3d.set_viewport_container(_vp_container)

func _on_status_message(msg: String) -> void:
	_status_label.text = msg

func _on_texture_picked(fc: MD.FaceConfig) -> void:
	if _sel_tex_lbl:
		_sel_tex_lbl.text = "💧 " + fc.atlas_path.get_file() + \
							"\n[col %d, row %d]" % [fc.atlas_col, fc.atlas_row]
	if _uv_scale_spin: _uv_scale_spin.value = fc.uv_scale
	_select_tool_by_idx(2)

# ══════════════════════════════════════════════════════════════════════════════
# RACCOURCIS CLAVIER
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

func _select_tool_by_idx(idx: int) -> void:
	if idx >= _tool_buttons.size(): return
	_tool_buttons[idx].button_pressed = true
	_select_tool(idx)

# ══════════════════════════════════════════════════════════════════════════════
# CONSTRUCTION DE L'UI
# ══════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root_vbox)
	root_vbox.add_child(_build_top_bar())

	var center_hbox := HBoxContainer.new()
	center_hbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_hbox.add_theme_constant_override("separation", 0)
	root_vbox.add_child(center_hbox)

	_side_bar = _build_side_bar()
	_side_bar.custom_minimum_size   = Vector2(210, 0)
	_side_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_side_bar.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.add_child(_side_bar)

	var vp_wrapper := _build_viewport_wrapper()
	vp_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_wrapper.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.add_child(vp_wrapper)

	var cam_panel := _build_right_camera_panel()
	cam_panel.custom_minimum_size   = Vector2(148, 0)
	cam_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	cam_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	center_hbox.add_child(cam_panel)

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
	_vp_container.name    = "SVPContainer"; _vp_container.stretch = true
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_vp_container.add_child(editor_3d.get_sub_viewport())
	_vp_container.gui_input.connect(_on_viewport_input)
	wrapper.add_child(_vp_container)
	return wrapper

func _on_viewport_input(event: InputEvent) -> void:
	editor_3d.handle_viewport_input(event)

# ══════════════════════════════════════════════════════════════════════════════
# PANNEAU DROIT — CAMÉRA
# ══════════════════════════════════════════════════════════════════════════════
func _build_right_camera_panel() -> PanelContainer:
	var panel := PanelContainer.new(); panel.name = "CameraPanel"
	var margin := MarginContainer.new()
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side, 6)
	panel.add_child(margin)
	var vbox := VBoxContainer.new(); vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new(); title.text = "📷 Caméra"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 14); vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	var center_btn := Button.new(); center_btn.text = "🎯 Centrer [F]"
	center_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_btn.pressed.connect(func(): editor_3d.reset_camera()); vbox.add_child(center_btn)
	vbox.add_child(HSeparator.new())

	vbox.add_child(_cam_section_label("Élévation"))
	var elev_row := HBoxContainer.new(); elev_row.alignment = BoxContainer.ALIGNMENT_CENTER
	elev_row.add_theme_constant_override("separation", 6)
	var btn_up := Button.new(); btn_up.text="▲ +10°"; btn_up.custom_minimum_size=Vector2(62,30)
	btn_up.pressed.connect(func(): editor_3d.elevate_camera(10.0))
	var btn_dn := Button.new(); btn_dn.text="▼ -10°"; btn_dn.custom_minimum_size=Vector2(62,30)
	btn_dn.pressed.connect(func(): editor_3d.elevate_camera(-10.0))
	elev_row.add_child(btn_up); elev_row.add_child(btn_dn); vbox.add_child(elev_row)
	vbox.add_child(HSeparator.new())

	vbox.add_child(_cam_section_label("Zoom"))
	var zoom_row := HBoxContainer.new(); zoom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	zoom_row.add_theme_constant_override("separation", 6)
	var btn_zi := Button.new(); btn_zi.text="🔍 +"; btn_zi.custom_minimum_size=Vector2(55,30)
	btn_zi.pressed.connect(func(): editor_3d.zoom_in())
	var btn_zo := Button.new(); btn_zo.text="🔍 −"; btn_zo.custom_minimum_size=Vector2(55,30)
	btn_zo.pressed.connect(func(): editor_3d.zoom_out())
	zoom_row.add_child(btn_zi); zoom_row.add_child(btn_zo); vbox.add_child(zoom_row)
	vbox.add_child(HSeparator.new())

	vbox.add_child(_cam_section_label("Vue depuis…"))
	vbox.add_child(_build_compass_rose()); vbox.add_child(HSeparator.new())

	var grid_chk := CheckButton.new(); grid_chk.text="Grille"; grid_chk.button_pressed=true
	grid_chk.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	grid_chk.toggled.connect(func(on): editor_3d.toggle_grid(on)); vbox.add_child(grid_chk)

	var test_chk := CheckButton.new(); test_chk.text="Mode Test"
	test_chk.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	test_chk.toggled.connect(func(on): editor_3d.toggle_test_mode(on)); vbox.add_child(test_chk)

	var sp := Control.new(); sp.size_flags_vertical=Control.SIZE_EXPAND_FILL; vbox.add_child(sp)
	return panel

func _build_compass_rose() -> GridContainer:
	var grid := GridContainer.new(); grid.columns=3
	grid.add_theme_constant_override("h_separation",3); grid.add_theme_constant_override("v_separation",3)
	var cells:Array=[["↖",315.0,"Nord-Ouest"],["↑",0.0,"Nord"],["↗",45.0,"Nord-Est"],
		["←",270.0,"Ouest"],["⊙",-1.0,"Reset"],["→",90.0,"Est"],
		["↙",225.0,"Sud-Ouest"],["↓",180.0,"Sud"],["↘",135.0,"Sud-Est"]]
	for cell in cells:
		var btn:=Button.new(); btn.text=cell[0]; btn.custom_minimum_size=Vector2(40,36); btn.tooltip_text=cell[2]
		if cell[1]<0.0:
			btn.add_theme_color_override("font_color",Color(1.0,0.85,0.3))
			btn.pressed.connect(func(): editor_3d.reset_camera())
		else:
			var az_cap:float=cell[1]; btn.pressed.connect(func(): editor_3d.look_from_azimuth(az_cap))
		grid.add_child(btn)
	return grid

static func _cam_section_label(text:String)->Label:
	var l:=Label.new(); l.text=text; l.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color",Color(0.6,0.82,1.0)); return l

# ══════════════════════════════════════════════════════════════════════════════
# BARRE DU HAUT
# ══════════════════════════════════════════════════════════════════════════════
func _build_top_bar() -> Control:
	var bar:=PanelContainer.new(); bar.custom_minimum_size=Vector2(0,44)
	var hbox:=HBoxContainer.new(); hbox.add_theme_constant_override("separation",3); bar.add_child(hbox)

	_add_btn(hbox,"📄 Nouveau",func(): show_new_map_dialog(),Color(0.25,0.45,0.75))
	_add_btn(hbox,"💾 Sauver", func(): _save_map(),          Color(0.25,0.45,0.75))
	_add_btn(hbox,"📂 Ouvrir", func(): _load_map(),          Color(0.25,0.45,0.75))
	_add_separator(hbox)
	_add_btn(hbox,"↶ Annuler", func(): editor_3d.undo(),Color(0.30,0.30,0.45))
	_add_btn(hbox,"↷ Rétablir",func(): editor_3d.redo(),Color(0.30,0.30,0.45))
	_add_separator(hbox)

	_tool_buttons.clear()
	var bg:=ButtonGroup.new()
	for ti in E3.Tool.values():
		var ti_val:int=ti; var btn:=Button.new()
		btn.text=TOOL_ICONS[ti]; btn.toggle_mode=true; btn.button_group=bg
		btn.tooltip_text=TOOL_NAMES[ti]+"  [touche %d]"%(ti+1); btn.custom_minimum_size=Vector2(36,0)
		btn.pressed.connect(func(): _select_tool(ti_val))
		if ti==E3.Tool.SHARED_CORNER: btn.button_pressed=true
		hbox.add_child(btn); _tool_buttons.append(btn)
	_add_separator(hbox)

	_add_btn(hbox,"📋 Copier",func(): editor_3d.copy_selected(), Color(0.35,0.35,0.20))
	_add_btn(hbox,"📌 Coller",func(): editor_3d.paste_selected(),Color(0.35,0.35,0.20))
	_add_separator(hbox)
	_add_btn(hbox,"⊞ Subdiviser",func(): _subdivide_selected(),Color(0.50,0.30,0.65))
	_add_btn(hbox,"⊟ Fusionner", func(): _merge_selected(),    Color(0.50,0.30,0.65))
	_add_separator(hbox)

	var snap_btn:=CheckButton.new(); snap_btn.text="Snap ↕"
	snap_btn.tooltip_text="Arrondir les hauteurs au pas (%.2f)"%MD.HEIGHT_STEP
	snap_btn.toggled.connect(func(on): editor_3d.set_snap(on)); hbox.add_child(snap_btn)
	_add_separator(hbox)

	_add_btn(hbox,"⬇ HMap",func(): _import_heightmap_dialog(),Color(0.30,0.40,0.30))
	_add_btn(hbox,"⬆ HMap",func(): _export_heightmap_dialog(),Color(0.30,0.40,0.30))
	_add_separator(hbox)

	_status_label=Label.new(); _status_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_status_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.add_theme_color_override("font_color",Color(0.7,0.7,0.7))
	_status_label.text="Prêt  |  Clic gauche : sélectionner  |  Clic droit : orbiter  |  Molette : zoom"
	hbox.add_child(_status_label)
	return bar

func _select_tool(ti:int)->void:
	editor_3d.set_tool(ti)
	var names:=["4 Coins partagés","Hauteur de face","Texture","Coin unique","Pipette 💧"]
	_status_label.text="Outil : "+names[ti]+"  |  1-5 : outils  |  F : centrer  |  +/- : hauteur"

# ══════════════════════════════════════════════════════════════════════════════
# BARRE DU BAS
# ══════════════════════════════════════════════════════════════════════════════
func _build_bottom_bar()->Control:
	var bar:=PanelContainer.new(); bar.custom_minimum_size=Vector2(0,50)
	var hbox:=HBoxContainer.new(); hbox.name="BottomHBox"
	hbox.add_theme_constant_override("separation",8); bar.add_child(hbox)

	hbox.add_child(_make_label("Hauteur :"))
	_add_btn(hbox,"▲ +0.25 [+]",func(): editor_3d.adjust_height( MD.HEIGHT_STEP),Color(0.25,0.60,0.25))
	_add_btn(hbox,"▼ -0.25 [-]",func(): editor_3d.adjust_height(-MD.HEIGHT_STEP),Color(0.60,0.25,0.25))
	_add_btn(hbox,"+1.0 [PgUp]",func(): editor_3d.adjust_height( 1.0),Color(0.25,0.50,0.25))
	_add_btn(hbox,"-1.0 [PgDn]",func(): editor_3d.adjust_height(-1.0),Color(0.50,0.25,0.25))
	_add_separator(hbox)

	hbox.add_child(_make_label("UV Scale :"))
	_uv_scale_spin=SpinBox.new(); _uv_scale_spin.min_value=0.1; _uv_scale_spin.max_value=16.0
	_uv_scale_spin.step=0.1; _uv_scale_spin.value=1.0; _uv_scale_spin.custom_minimum_size=Vector2(80,0)
	_uv_scale_spin.value_changed.connect(_on_uv_scale_changed); hbox.add_child(_uv_scale_spin)
	_add_separator(hbox)

	_add_btn(hbox,"✗ Déselect. [Esc]",func(): editor_3d.clear_selection(),Color(0.4,0.4,0.4))
	_add_separator(hbox)

	var info:=Label.new(); info.name="SelInfo"; info.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	info.text="Aucune sélection  |  Clic gauche : sélectionner  |  Flèches : paner caméra"
	info.add_theme_color_override("font_color",Color(0.8,0.8,0.8)); hbox.add_child(info)
	return bar

func _on_uv_scale_changed(v:float)->void:
	for sf in editor_3d.selected_faces:
		var cube:=map_data.get_cube(sf["tx"],sf["ty"],sf["si"])
		if cube: cube.face_configs[sf["face_idx"]].uv_scale=v
	for cr in editor_3d.selected_corners:
		var cube:=map_data.get_cube(cr["tx"],cr["ty"],cr["si"])
		if cube: for fi in 6: cube.face_configs[fi].uv_scale=v

func _on_selection_changed()->void:
	var bar:=_bottom_bar.get_node_or_null("BottomHBox"); if bar==null: return
	var lbl:=bar.get_node_or_null("SelInfo") as Label; if lbl==null: return
	var nc:=editor_3d.selected_corners.size(); var nf:=editor_3d.selected_faces.size()
	if nc>0: lbl.text="🔵 %d coin(s)  |  +/- ou ▲▼ : hauteur  |  Ctrl+C/V : copier/coller"%nc
	elif nf>0: lbl.text="🟦 %d face(s)  |  +/- ou ▲▼ : hauteur  |  Ctrl+C/V : copier/coller"%nf
	else: lbl.text="Aucune sélection  |  Clic gauche : sélectionner  |  Flèches : paner caméra"
	_update_minimap()

# ══════════════════════════════════════════════════════════════════════════════
# SIDEBAR GAUCHE
# ══════════════════════════════════════════════════════════════════════════════
func _build_side_bar()->Control:
	var panel:=PanelContainer.new()
	var vbox:=VBoxContainer.new(); vbox.add_theme_constant_override("separation",4); panel.add_child(vbox)

	var title:=Label.new(); title.text="Textures"; title.add_theme_font_size_override("font_size",14)
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER; vbox.add_child(title)

	# ── Toggle 16 / 32 px ─────────────────────────────────────────────────────
	var size_lbl:=Label.new(); size_lbl.text="Taille cellule atlas :"
	size_lbl.add_theme_color_override("font_color",Color(0.65,0.65,0.65)); vbox.add_child(size_lbl)

	var size_row:=HBoxContainer.new(); size_row.alignment=BoxContainer.ALIGNMENT_CENTER
	size_row.add_theme_constant_override("separation",4); vbox.add_child(size_row)
	var size_group:=ButtonGroup.new()

	_size_btn_16=Button.new(); _size_btn_16.text="16 × 16"; _size_btn_16.toggle_mode=true
	_size_btn_16.button_group=size_group; _size_btn_16.custom_minimum_size=Vector2(86,28)
	_size_btn_16.tooltip_text="Cellule 16×16 px — idéal pour les tuiles subdivisées"
	_size_btn_16.pressed.connect(func(): _set_cell_size(16)); size_row.add_child(_size_btn_16)

	_size_btn_32=Button.new(); _size_btn_32.text="32 × 32"; _size_btn_32.toggle_mode=true
	_size_btn_32.button_group=size_group; _size_btn_32.button_pressed=true
	_size_btn_32.custom_minimum_size=Vector2(86,28)
	_size_btn_32.tooltip_text="Cellule 32×32 px — tuiles normales"
	_size_btn_32.pressed.connect(func(): _set_cell_size(32)); size_row.add_child(_size_btn_32)

	# ── Import ─────────────────────────────────────────────────────────────────
	var import_btn:=Button.new(); import_btn.text="📂 Importer atlas…"
	import_btn.pressed.connect(_on_import_atlas); vbox.add_child(import_btn)

	# ── Grille scrollable ──────────────────────────────────────────────────────
	var scroll:=ScrollContainer.new(); scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; vbox.add_child(scroll)
	_texture_grid_container=GridContainer.new(); _texture_grid_container.columns=4
	scroll.add_child(_texture_grid_container)

	# ── Label texture active — RÉFÉRENCE DIRECTE ──────────────────────────────
	_sel_tex_lbl = Label.new()
	_sel_tex_lbl.text = "Aucune texture sélectionnée"
	_sel_tex_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sel_tex_lbl.add_theme_color_override("font_color", Color(0.7,0.7,0.7))
	vbox.add_child(_sel_tex_lbl)

	vbox.add_child(HSeparator.new())

	# ── Minimap ────────────────────────────────────────────────────────────────
	var mm_lbl:=Label.new(); mm_lbl.text="Minimap (hauteurs)"
	mm_lbl.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	mm_lbl.add_theme_color_override("font_color",Color(0.6,0.6,0.6)); vbox.add_child(mm_lbl)

	_minimap_rect=TextureRect.new(); _minimap_rect.custom_minimum_size=Vector2(190,190)
	_minimap_rect.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	_minimap_rect.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_minimap_rect.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST; vbox.add_child(_minimap_rect)
	return panel

func _set_cell_size(size:int)->void:
	_atlas_cell_size=size; _refresh_texture_grid()
	_status_label.text="Cellule atlas : %d×%d px"%[size,size]

func _update_minimap()->void:
	if _minimap_rect==null or map_data==null: return
	if map_data.grid_width==0 or map_data.grid_height==0: return
	var w:=map_data.grid_width; var h:=map_data.grid_height
	var img:=Image.create(w,h,false,Image.FORMAT_RGBA8)
	for tx in w:
		for ty in h:
			var td:=map_data.get_tile(tx,ty)
			if td==null: img.set_pixel(tx,ty,Color(0.15,0.15,0.15)); continue
			var avg_h:float=0.0
			if td.subdivided:
				for si in 4: avg_h+=td.cubes[si].top_max(); avg_h/=4.0
			else: avg_h=td.cubes[0].top_max()
			var t:=(avg_h-MD.MIN_H)/(MD.MAX_H-MD.MIN_H)
			img.set_pixel(tx,ty,Color(t*0.4+0.05,t*0.60+0.15,t*0.25+0.03,1.0))
	var sel_color:=Color(0.2,0.65,1.0,1.0)
	for cr in editor_3d.selected_corners:
		if cr["tx"]<w and cr["ty"]<h: img.set_pixel(cr["tx"],cr["ty"],sel_color)
	for sf in editor_3d.selected_faces:
		if sf["tx"]<w and sf["ty"]<h: img.set_pixel(sf["tx"],sf["ty"],sel_color)
	_minimap_rect.texture=ImageTexture.create_from_image(img)

# ══════════════════════════════════════════════════════════════════════════════
# HEIGHTMAP
# ══════════════════════════════════════════════════════════════════════════════
func _import_heightmap_dialog()->void:
	var dlg:=FileDialog.new(); dlg.file_mode=FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters=["*.png, *.jpg, *.jpeg, *.bmp ; Images"]; dlg.access=FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800,600))
	dlg.file_selected.connect(func(path:String): _import_heightmap(path); dlg.queue_free())

func _import_heightmap(path:String)->void:
	var img:=Image.load_from_file(path)
	if img==null: _status_label.text="✗ Impossible de charger : "+path.get_file(); return
	img.convert(Image.FORMAT_L8)
	var iw:=img.get_width(); var ih:=img.get_height()
	var w:=map_data.grid_width; var h:=map_data.grid_height
	for tx in w:
		for ty in h:
			var px:=clampi(int(float(tx)/float(w)*iw),0,iw-1)
			var py:=clampi(int(float(ty)/float(h)*ih),0,ih-1)
			var height:=snappedf(MD.MIN_H+img.get_pixel(px,py).r*(MD.MAX_H-MD.MIN_H),MD.HEIGHT_STEP)
			var td:=map_data.get_tile(tx,ty); if td==null: continue
			if td.subdivided:
				for si in 4:
					for ci in 4: td.cubes[si].corners[ci]=height
			else:
				for ci in 4: td.cubes[0].corners[ci]=height
	editor_3d.build_all(); _status_label.text="✓ Heightmap importée : "+path.get_file()

func _export_heightmap_dialog()->void:
	var dlg:=FileDialog.new(); dlg.file_mode=FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters=["*.png ; PNG Image"]; dlg.access=FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800,600))
	dlg.file_selected.connect(func(path:String): _export_heightmap(path); dlg.queue_free())

func _export_heightmap(path:String)->void:
	var w:=map_data.grid_width; var h:=map_data.grid_height; if w==0 or h==0: return
	var img:=Image.create(w,h,false,Image.FORMAT_L8)
	for tx in w:
		for ty in h:
			var td:=map_data.get_tile(tx,ty); var height:=MD.MIN_H
			if td:
				if td.subdivided:
					var mx:=0.0; for si in 4: mx=maxf(mx,td.cubes[si].top_max()); height=mx
				else: height=td.cubes[0].top_max()
			img.set_pixel(tx,ty,Color.from_hsv(0,0,clampf((height-MD.MIN_H)/(MD.MAX_H-MD.MIN_H),0,1)))
	if img.save_png(path)==OK: _status_label.text="✓ Heightmap exportée : "+path.get_file()
	else: _status_label.text="✗ Erreur d'export heightmap"

# ══════════════════════════════════════════════════════════════════════════════
# NAVIGATEUR TEXTURES
# ══════════════════════════════════════════════════════════════════════════════
func _on_import_atlas()->void:
	var dlg:=FileDialog.new(); dlg.file_mode=FileDialog.FILE_MODE_OPEN_FILES
	dlg.filters=["*.png, *.jpg, *.jpeg ; Images"]; dlg.access=FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800,600))
	dlg.files_selected.connect(func(paths:PackedStringArray):
		for p in paths: _load_atlas_file(p); dlg.queue_free())

func _load_atlas_file(path:String)->void:
	var img:=load(path) as Texture2D
	if img==null:
		var raw:=Image.load_from_file(path); if raw==null: return
		img=ImageTexture.create_from_image(raw)
	if img==null: return
	for a in _loaded_atlases:
		if a["path"]==path: return
	_loaded_atlases.append({"path":path,"texture":img,
		"cols":maxi(1,img.get_width()/_atlas_cell_size),
		"rows":maxi(1,img.get_height()/_atlas_cell_size)})
	_refresh_texture_grid()

func _scan_texture_folder()->void:
	var dir:=DirAccess.open("res://assets/textures/"); if dir==null: return
	dir.list_dir_begin(); var fname:=dir.get_next()
	while fname!="":
		if fname.ends_with(".png") or fname.ends_with(".jpg"):
			_load_atlas_file("res://assets/textures/"+fname)
		fname=dir.get_next()

# ── FIX CLIC : Button + TextureRect(MOUSE_FILTER_IGNORE) ─────────────────────
func _refresh_texture_grid()->void:
	for ch in _texture_grid_container.get_children(): ch.queue_free()
	for atlas in _loaded_atlases:
		var tex:Texture2D=atlas["texture"]
		var cols:=maxi(1,tex.get_width()/_atlas_cell_size)
		var rows:=maxi(1,tex.get_height()/_atlas_cell_size)
		atlas["cols"]=cols; atlas["rows"]=rows
		for row in rows:
			for col in cols:
				var btn:=Button.new(); btn.custom_minimum_size=Vector2(44,44)

				# Aperçu : AtlasTexture dans un TextureRect transparent aux clics
				var at:=AtlasTexture.new(); at.atlas=tex
				at.region=Rect2(col*_atlas_cell_size,row*_atlas_cell_size,
								_atlas_cell_size,_atlas_cell_size)
				var tr:=TextureRect.new(); tr.texture=at
				tr.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tr.expand_mode=TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				tr.mouse_filter=Control.MOUSE_FILTER_IGNORE  # ← le Button reçoit les clics
				tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				btn.add_child(tr)

				var ap:String=atlas["path"]; var c:int=col; var r:int=row
				btn.pressed.connect(func(): _on_texture_cell_selected(ap,c,r))
				btn.tooltip_text="%s  [col %d, row %d]  (%dpx)"%[ap.get_file(),col,row,_atlas_cell_size]
				_texture_grid_container.add_child(btn)

func _on_texture_cell_selected(atlas_path:String,col:int,row:int)->void:
	_selected_atlas_path=atlas_path; _selected_atlas_col=col; _selected_atlas_row=row

	var fc:=MD.FaceConfig.new()
	fc.atlas_path=atlas_path; fc.atlas_col=col; fc.atlas_row=row
	fc.cell_size=_atlas_cell_size
	fc.uv_scale=_uv_scale_spin.value if _uv_scale_spin else 1.0
	editor_3d.set_pending_texture(fc)

	# FIX : utilise la référence directe stockée à la construction
	if _sel_tex_lbl:
		_sel_tex_lbl.text="✓ %s\n[col %d, row %d] · %dpx"%[atlas_path.get_file(),col,row,_atlas_cell_size]

	_status_label.text="🖌 Texture : %s [%d,%d] · %d px"%[atlas_path.get_file(),col,row,_atlas_cell_size]
	_select_tool_by_idx(2)

# ══════════════════════════════════════════════════════════════════════════════
# DIALOGUE NOUVELLE CARTE
# ══════════════════════════════════════════════════════════════════════════════
func show_new_map_dialog()->void:
	if is_instance_valid(_new_map_dialog): _new_map_dialog.popup_centered(Vector2i(360,240))

func _build_new_map_dialog()->Window:
	var win:=Window.new(); win.title="Nouvelle carte"; win.size=Vector2i(360,260); win.unresizable=true
	win.close_requested.connect(func(): win.hide())
	var margin:=MarginContainer.new(); margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,16)
	var vbox:=VBoxContainer.new(); vbox.add_theme_constant_override("separation",12)
	margin.add_child(vbox); win.add_child(margin)

	var lbl:=Label.new(); lbl.text="Créer une nouvelle carte"
	lbl.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER; lbl.add_theme_font_size_override("font_size",16)
	vbox.add_child(lbl)

	var w_hbox:=HBoxContainer.new(); w_hbox.add_child(_make_label("Largeur (X) :"))
	var w_spin:=SpinBox.new(); w_spin.min_value=2; w_spin.max_value=64; w_spin.value=10
	w_spin.size_flags_horizontal=Control.SIZE_EXPAND_FILL; w_hbox.add_child(w_spin); vbox.add_child(w_hbox)

	var h_hbox:=HBoxContainer.new(); h_hbox.add_child(_make_label("Hauteur (Z) :"))
	var h_spin:=SpinBox.new(); h_spin.min_value=2; h_spin.max_value=64; h_spin.value=10
	h_spin.size_flags_horizontal=Control.SIZE_EXPAND_FILL; h_hbox.add_child(h_spin); vbox.add_child(h_hbox)

	vbox.add_child(HSeparator.new())
	var btn_row:=HBoxContainer.new(); btn_row.alignment=BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation",16); vbox.add_child(btn_row)
	var cancel:=Button.new(); cancel.text="Annuler"; cancel.pressed.connect(func(): win.hide())
	btn_row.add_child(cancel)
	var ok:=Button.new(); ok.text="✓  Créer"
	ok.pressed.connect(func(): win.hide(); _create_new_map(int(w_spin.value),int(h_spin.value)))
	btn_row.add_child(ok)
	return win

func _create_new_map(w:int,h:int)->void:
	map_data.init_grid(w,h); editor_3d.build_all(); _update_minimap()
	_status_label.text="✓ Carte %d×%d créée  |  Clic droit : orbiter  |  Molette : zoom"%[w,h]

# ══════════════════════════════════════════════════════════════════════════════
# SUBDIVISION
# ══════════════════════════════════════════════════════════════════════════════
func _subdivide_selected()->void:
	var done:={}
	for cr in editor_3d.selected_corners:
		var k:="%d,%d"%[cr["tx"],cr["ty"]]; if not done.has(k): done[k]=true; editor_3d.subdivide_tile(cr["tx"],cr["ty"])
	for sf in editor_3d.selected_faces:
		var k:="%d,%d"%[sf["tx"],sf["ty"]]; if not done.has(k): done[k]=true; editor_3d.subdivide_tile(sf["tx"],sf["ty"])
	if done.is_empty(): _status_label.text="Sélectionnez d'abord une tuile."

func _merge_selected()->void:
	var done:={}
	for cr in editor_3d.selected_corners:
		var k:="%d,%d"%[cr["tx"],cr["ty"]]; if not done.has(k): done[k]=true; editor_3d.merge_tile(cr["tx"],cr["ty"])
	for sf in editor_3d.selected_faces:
		var k:="%d,%d"%[sf["tx"],sf["ty"]]; if not done.has(k): done[k]=true; editor_3d.merge_tile(sf["tx"],sf["ty"])
	if done.is_empty(): _status_label.text="Sélectionnez d'abord une tuile."

# ══════════════════════════════════════════════════════════════════════════════
# SAVE / LOAD
# ══════════════════════════════════════════════════════════════════════════════
func _save_map()->void:
	var dlg:=FileDialog.new(); dlg.file_mode=FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters=["*.json ; Map JSON"]; dlg.access=FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800,600))
	dlg.file_selected.connect(func(path:String):
		var f:=FileAccess.open(path,FileAccess.WRITE)
		if f: f.store_string(map_data.to_json()); f.close()
		_status_label.text="✓ Carte sauvegardée : "+path.get_file(); dlg.queue_free())

func _load_map()->void:
	var dlg:=FileDialog.new(); dlg.file_mode=FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters=["*.json ; Map JSON"]; dlg.access=FileDialog.ACCESS_FILESYSTEM
	add_child(dlg); dlg.popup_centered(Vector2i(800,600))
	dlg.file_selected.connect(func(path:String):
		var f:=FileAccess.open(path,FileAccess.READ)
		if f:
			var ok:=map_data.from_json(f.get_as_text()); f.close()
			if ok: editor_3d.build_all(); _update_minimap()
			_status_label.text=("✓ Carte chargée : " if ok else "✗ Erreur : ")+path.get_file()
		dlg.queue_free())

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════
static func _make_label(text:String)->Label:
	var l:=Label.new(); l.text=text; l.vertical_alignment=VERTICAL_ALIGNMENT_CENTER; return l

static func _add_btn(parent:Control,text:String,cb:Callable,color:Color=Color(0.3,0.3,0.35))->Button:
	var btn:=Button.new(); btn.text=text
	var style:=StyleBoxFlat.new(); style.bg_color=color
	style.corner_radius_top_left=4; style.corner_radius_top_right=4
	style.corner_radius_bottom_left=4; style.corner_radius_bottom_right=4
	style.content_margin_left=8; style.content_margin_right=8
	style.content_margin_top=4; style.content_margin_bottom=4
	btn.add_theme_stylebox_override("normal",style); btn.pressed.connect(cb)
	parent.add_child(btn); return btn

static func _add_separator(parent:Control)->void:
	parent.add_child(VSeparator.new())
