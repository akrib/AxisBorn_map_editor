## editor_ui.gd
## Builds the complete editor UI tree: TopBar / 3D Viewport / SideBar / BottomBar.
## Communicates with Editor3D via signals and direct calls.
extends Control

const MD := preload("res://scripts/map_data.gd")
const E3 := preload("res://scripts/editor_3d.gd")

# ══════════════════════════════════════════════════════════════════════════════
# REFERENCES
# ══════════════════════════════════════════════════════════════════════════════
var map_data  : MD
var editor_3d : E3

## UI nodes
var _vp_container   : SubViewportContainer
var _bottom_bar     : Control
var _side_bar       : Control
var _new_map_dialog : Window
var _tool_buttons   : Array = []
var _status_label   : Label
var _selected_atlas_path : String = ""
var _selected_atlas_col  : int    = 0
var _selected_atlas_row  : int    = 0
var _atlas_cell_size     : int    = 32
var _uv_scale_spin       : SpinBox = null
var _texture_grid_container : GridContainer
var _loaded_atlases = []  ## [{path, image, rows, cols}]

const TOOL_NAMES := ["4 Coins partagés", "Hauteur de face", "Texture", "Coin unique"]
const TOOL_ICONS := ["⊕", "↕", "🖌", "◉"]

# ══════════════════════════════════════════════════════════════════════════════
# INIT
# ══════════════════════════════════════════════════════════════════════════════
func _init(md: MD, e3: E3) -> void:
	map_data  = md
	editor_3d = e3

func _ready() -> void:
	_build_ui()
	editor_3d.selection_changed.connect(_on_selection_changed)
	editor_3d.cube_hovered.connect(func(_a,_b,_c): pass)
	_scan_texture_folder()

# ══════════════════════════════════════════════════════════════════════════════
# UI CONSTRUCTION
# ══════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	# ── Top bar ──────────────────────────────────────────────────────────────
	var top_bar := _build_top_bar()
	vbox.add_child(top_bar)

	# ── Main content (SideBar | Viewport | ?) ────────────────────────────────
	var content_split := HSplitContainer.new()
	content_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_split.split_offset = 200
	vbox.add_child(content_split)

	_side_bar = _build_side_bar()
	_side_bar.custom_minimum_size = Vector2(200, 0)
	content_split.add_child(_side_bar)

	# Viewport container
	_vp_container = SubViewportContainer.new()
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_vp_container.stretch = true
	_vp_container.add_child(editor_3d.get_sub_viewport())
	content_split.add_child(_vp_container)
	_vp_container.gui_input.connect(_on_viewport_input)

	# ── Bottom bar ───────────────────────────────────────────────────────────
	_bottom_bar = _build_bottom_bar()
	vbox.add_child(_bottom_bar)

	# ── New map dialog ───────────────────────────────────────────────────────
	_new_map_dialog = _build_new_map_dialog()
	add_child(_new_map_dialog)

func _on_viewport_input(event: InputEvent) -> void:
	editor_3d.handle_viewport_input(event)

# ══════════════════════════════════════════════════════════════════════════════
# TOP BAR
# ══════════════════════════════════════════════════════════════════════════════
func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0, 42)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	bar.add_child(hbox)

	# ── Fichier ──────────────────────────────────────────────────────────────
	_add_btn(hbox, "📄 Nouveau",  func(): show_new_map_dialog(), Color(0.25,0.55,0.9))
	_add_btn(hbox, "💾 Sauver",   func(): _save_map(),            Color(0.25,0.55,0.9))
	_add_btn(hbox, "📂 Ouvrir",   func(): _load_map(),            Color(0.25,0.55,0.9))
	_add_separator(hbox)

	# ── Outils ───────────────────────────────────────────────────────────────
	_tool_buttons.clear()
	for ti in E3.Tool.values():
		var ti_val : int = ti
		var btn := Button.new()
		btn.text        = TOOL_ICONS[ti] + " " + TOOL_NAMES[ti]
		btn.toggle_mode = true
		btn.button_group = _make_tool_group() if _tool_buttons.is_empty() else null
		btn.pressed.connect(func(): _select_tool(ti_val))
		if ti == E3.Tool.SHARED_CORNER: btn.button_pressed = true
		hbox.add_child(btn)
		_tool_buttons.append(btn)

	# Ensure button group shared
	var bg := ButtonGroup.new()
	for b in _tool_buttons: b.button_group = bg; b.toggle_mode = true
	_tool_buttons[0].button_pressed = true

	_add_separator(hbox)

	# ── Subdivision ───────────────────────────────────────────────────────────
	_add_btn(hbox, "⊞ Subdiviser", func(): _subdivide_selected(), Color(0.55,0.35,0.7))
	_add_btn(hbox, "⊟ Fusionner",  func(): _merge_selected(),     Color(0.55,0.35,0.7))
	_add_separator(hbox)

	# ── Test mode ─────────────────────────────────────────────────────────────
	var test_btn := CheckButton.new()
	test_btn.text = "Mode Test"
	test_btn.toggled.connect(func(on): editor_3d.toggle_test_mode(on))
	hbox.add_child(test_btn)

	# Status label
	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.text = "Prêt"
	hbox.add_child(_status_label)

	return bar

func _make_tool_group() -> ButtonGroup:
	return ButtonGroup.new()

func _select_tool(ti: int) -> void:
	editor_3d.set_tool(ti)
	_update_bottom_bar_for_tool(ti)
	_status_label.text = "Outil : " + TOOL_NAMES[ti]

# ══════════════════════════════════════════════════════════════════════════════
# BOTTOM BAR
# ══════════════════════════════════════════════════════════════════════════════
func _build_bottom_bar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0, 50)
	var hbox := HBoxContainer.new()
	hbox.name = "BottomHBox"
	hbox.add_theme_constant_override("separation", 10)
	bar.add_child(hbox)

	# Height controls (always visible)
	hbox.add_child(_make_label("Hauteur :"))
	_add_btn(hbox, "▲ +0.25", func(): editor_3d.adjust_height( MD.HEIGHT_STEP), Color(0.3,0.7,0.3))
	_add_btn(hbox, "▼ -0.25", func(): editor_3d.adjust_height(-MD.HEIGHT_STEP), Color(0.7,0.3,0.3))
	_add_btn(hbox, "+1.0",    func(): editor_3d.adjust_height( 1.0), Color(0.3,0.6,0.3))
	_add_btn(hbox, "-1.0",    func(): editor_3d.adjust_height(-1.0), Color(0.6,0.3,0.3))

	_add_separator(hbox)
	hbox.add_child(_make_label("UV Scale :"))
	_uv_scale_spin = SpinBox.new()
	_uv_scale_spin.min_value = 0.1; _uv_scale_spin.max_value = 16.0
	_uv_scale_spin.step = 0.1; _uv_scale_spin.value = 1.0
	_uv_scale_spin.custom_minimum_size = Vector2(80, 0)
	_uv_scale_spin.value_changed.connect(_on_uv_scale_changed)
	hbox.add_child(_uv_scale_spin)

	_add_separator(hbox)
	_add_btn(hbox, "✗ Déselect.", func(): editor_3d.clear_selection(), Color(0.5,0.5,0.5))

	# Selection info label
	var info := Label.new(); info.name = "SelInfo"
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.text = "Aucune sélection"
	hbox.add_child(info)

	return bar

func _update_bottom_bar_for_tool(_ti: int) -> void:
	pass  ## Tool-specific bottom bar customization can be added here.

func _on_uv_scale_changed(v: float) -> void:
	# Update uv_scale on selected faces' current texture config.
	for sf in editor_3d.selected_faces:
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube: cube.face_configs[sf["face_idx"]].uv_scale = v
	for cr in editor_3d.selected_corners:
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		if cube:
			for fi in 6: cube.face_configs[fi].uv_scale = v

func _on_selection_changed() -> void:
	var bar := _bottom_bar.get_node_or_null("BottomHBox")
	if bar == null: return
	var lbl := bar.get_node_or_null("SelInfo") as Label
	if lbl == null: return
	var nc := editor_3d.selected_corners.size()
	var nf := editor_3d.selected_faces.size()
	if nc > 0:
		lbl.text = "%d coin(s) sélectionné(s)" % nc
	elif nf > 0:
		lbl.text = "%d face(s) sélectionnée(s)" % nf
	else:
		lbl.text = "Aucune sélection"

# ══════════════════════════════════════════════════════════════════════════════
# SIDE BAR – TEXTURE BROWSER
# ══════════════════════════════════════════════════════════════════════════════
func _build_side_bar() -> Control:
	var panel := PanelContainer.new()
	var vbox  := VBoxContainer.new()
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Textures"
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Cell size selector
	var cs_hbox := HBoxContainer.new()
	cs_hbox.add_child(_make_label("Cellule :"))
	var cs_spin := SpinBox.new()
	cs_spin.min_value = 8; cs_spin.max_value = 512; cs_spin.step = 8
	cs_spin.value = 32; cs_spin.custom_minimum_size = Vector2(65, 0)
	cs_spin.value_changed.connect(func(v): _atlas_cell_size = int(v); _refresh_texture_grid())
	cs_hbox.add_child(cs_spin)
	vbox.add_child(cs_hbox)

	# Import button
	var import_btn := Button.new()
	import_btn.text = "📂 Importer atlas…"
	import_btn.pressed.connect(_on_import_atlas)
	vbox.add_child(import_btn)

	# Scroll container for texture grid
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_texture_grid_container = GridContainer.new()
	_texture_grid_container.columns = 4
	scroll.add_child(_texture_grid_container)

	# Selected texture info
	var sel_lbl := Label.new(); sel_lbl.name = "SelTexLbl"
	sel_lbl.text = "Aucune texture sélectionnée"
	sel_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(sel_lbl)

	return panel

func _on_import_atlas() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dlg.filters   = ["*.png, *.jpg, *.jpeg ; Images"]
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg)
	dlg.popup_centered(Vector2i(800, 600))
	dlg.files_selected.connect(func(paths: PackedStringArray):
		for p in paths: _load_atlas_file(p)
		dlg.queue_free())

func _load_atlas_file(path: String) -> void:
	var img := load(path) as Texture2D
	if img == null:
		# Try loading as Image
		var raw := Image.load_from_file(path)
		if raw == null: return
		img = ImageTexture.create_from_image(raw)
	if img == null: return
	# Check if already loaded
	for a in _loaded_atlases:
		if a["path"] == path: return
	var w := img.get_width(); var h := img.get_height()
	var cols := maxi(1, w / _atlas_cell_size)
	var rows := maxi(1, h / _atlas_cell_size)
	_loaded_atlases.append({"path": path, "texture": img, "cols": cols, "rows": rows})
	_refresh_texture_grid()

func _scan_texture_folder() -> void:
	var folder := "res://assets/textures/"
	var dir := DirAccess.open(folder)
	if dir == null: return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".png") or fname.ends_with(".jpg"):
			_load_atlas_file(folder + fname)
		fname = dir.get_next()

func _refresh_texture_grid() -> void:
	for ch in _texture_grid_container.get_children(): ch.queue_free()
	for atlas in _loaded_atlases:
		var tex    : Texture2D = atlas["texture"]
		var cols   : int       = maxi(1, tex.get_width()  / _atlas_cell_size)
		var rows   : int       = maxi(1, tex.get_height() / _atlas_cell_size)
		atlas["cols"] = cols; atlas["rows"] = rows
		for row in rows:
			for col in cols:
				var cell_btn := TextureButton.new()
				cell_btn.custom_minimum_size = Vector2(40, 40)
				cell_btn.stretch_mode = TextureButton.STRETCH_SCALE
				# Create AtlasTexture for this cell
				var at := AtlasTexture.new()
				at.atlas  = tex
				at.region = Rect2(col * _atlas_cell_size, row * _atlas_cell_size,
								  _atlas_cell_size, _atlas_cell_size)
				cell_btn.texture_normal = at
				var ap: String = atlas["path"]
				var c: int = col
				var r: int = row
				cell_btn.pressed.connect(func(): _on_texture_cell_selected(ap, c, r))
				cell_btn.tooltip_text = "%s [%d,%d]" % [ap.get_file(), col, row]
				_texture_grid_container.add_child(cell_btn)

func _on_texture_cell_selected(atlas_path: String, col: int, row: int) -> void:
	_selected_atlas_path = atlas_path
	_selected_atlas_col  = col
	_selected_atlas_row  = row

	var fc := MD.FaceConfig.new()
	fc.atlas_path = atlas_path; fc.atlas_col = col; fc.atlas_row = row
	fc.cell_size  = _atlas_cell_size
	fc.uv_scale   = _uv_scale_spin.value if _uv_scale_spin else 1.0
	editor_3d.set_pending_texture(fc)

	var lbl := _side_bar.get_node_or_null("SelTexLbl") as Label
	if lbl: lbl.text = "%s [%d,%d]" % [atlas_path.get_file(), col, row]
	_status_label.text = "Texture: %s [%d,%d]" % [atlas_path.get_file(), col, row]

# ══════════════════════════════════════════════════════════════════════════════
# NEW MAP DIALOG
# ══════════════════════════════════════════════════════════════════════════════
func show_new_map_dialog() -> void:
	if is_instance_valid(_new_map_dialog):
		_new_map_dialog.popup_centered(Vector2i(360, 220))

func _build_new_map_dialog() -> Window:
	var win := Window.new()
	win.title   = "Nouvelle carte"
	win.size    = Vector2i(360, 240)
	win.unresizable = true
	win.close_requested.connect(func(): win.hide())

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_child(vbox)
	win.add_child(margin)

	# Title
	var lbl := Label.new()
	lbl.text = "Créer une nouvelle carte"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(lbl)

	# Width
	var w_hbox := HBoxContainer.new()
	w_hbox.name = "WidthHBox"
	w_hbox.add_child(_make_label("Largeur (X) :"))

	var w_spin := SpinBox.new()
	w_spin.name = "WidthSpin"
	w_spin.min_value = 2
	w_spin.max_value = 64
	w_spin.value = 10
	w_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	w_hbox.add_child(w_spin)
	vbox.add_child(w_hbox)

	# Height
	var h_hbox := HBoxContainer.new()
	h_hbox.name = "HeightHBox"
	h_hbox.add_child(_make_label("Hauteur (Z) :"))

	var h_spin := SpinBox.new()
	h_spin.name = "HeightSpin"
	h_spin.min_value = 2
	h_spin.max_value = 64
	h_spin.value = 10
	h_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	h_hbox.add_child(h_spin)
	vbox.add_child(h_hbox)

	var sep := HSeparator.new(); vbox.add_child(sep)

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var cancel := Button.new(); cancel.text = "Annuler"
	cancel.pressed.connect(func(): win.hide())
	btn_row.add_child(cancel)

	var ok := Button.new(); ok.text = "Créer"
	ok.pressed.connect(func():
		#var w := int((win.get_node("MarginContainer/VBoxContainer/WidthSpin") as SpinBox).value)
		#var h := int((win.get_node("MarginContainer/VBoxContainer/HeightSpin") as SpinBox).value)
		var w := int(w_spin.value)
		var h := int(h_spin.value)
		win.hide()
		_create_new_map(w, h))
	btn_row.add_child(ok)

	return win

func _create_new_map(w: int, h: int) -> void:
	map_data.init_grid(w, h)
	editor_3d.build_all()
	_status_label.text = "Carte %d×%d créée." % [w, h]

# ══════════════════════════════════════════════════════════════════════════════
# SUBDIVISION helpers (called from tool context or top bar)
# ══════════════════════════════════════════════════════════════════════════════
func _subdivide_selected() -> void:
	var done := {}
	for cr in editor_3d.selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k):
			done[k] = true; editor_3d.subdivide_tile(cr["tx"], cr["ty"])
	for sf in editor_3d.selected_faces:
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k):
			done[k] = true; editor_3d.subdivide_tile(sf["tx"], sf["ty"])
	if done.is_empty():
		_status_label.text = "Sélectionner d'abord une tuile."

func _merge_selected() -> void:
	var done := {}
	for cr in editor_3d.selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k):
			done[k] = true; editor_3d.merge_tile(cr["tx"], cr["ty"])
	for sf in editor_3d.selected_faces:
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k):
			done[k] = true; editor_3d.merge_tile(sf["tx"], sf["ty"])
	if done.is_empty():
		_status_label.text = "Sélectionner d'abord une tuile."

# ══════════════════════════════════════════════════════════════════════════════
# SAVE / LOAD
# ══════════════════════════════════════════════════════════════════════════════
func _save_map() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters   = ["*.json ; Map JSON"]
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg)
	dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f: f.store_string(map_data.to_json()); f.close()
		_status_label.text = "Carte sauvegardée : " + path.get_file()
		dlg.queue_free())

func _load_map() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters   = ["*.json ; Map JSON"]
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	add_child(dlg)
	dlg.popup_centered(Vector2i(800, 600))
	dlg.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var ok := map_data.from_json(f.get_as_text()); f.close()
			if ok:
				editor_3d.build_all()
				_status_label.text = "Carte chargée : " + path.get_file()
			else:
				_status_label.text = "Erreur de lecture du fichier."
		dlg.queue_free())

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════
static func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text; l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l

static func _add_btn(parent: Control, text: String, cb: Callable,
					  color: Color = Color(0.3, 0.3, 0.35)) -> Button:
	var btn := Button.new()
	btn.text = text
	var style := StyleBoxFlat.new()
	style.bg_color       = color
	style.corner_radius_top_left     = 4; style.corner_radius_top_right     = 4
	style.corner_radius_bottom_left  = 4; style.corner_radius_bottom_right  = 4
	style.content_margin_left  = 8; style.content_margin_right = 8
	style.content_margin_top   = 4; style.content_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", style)
	btn.pressed.connect(cb)
	parent.add_child(btn)
	return btn

static func _add_separator(parent: Control) -> void:
	var s := VSeparator.new(); parent.add_child(s)
