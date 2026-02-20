## editor_3d.gd  –  Version 3.0
## Supports dual texture layers (base + overlay), trigger placement, tileset configs.
extends Node

const MD := preload("res://scripts/map_data.gd")
const MB := preload("res://scripts/mesh_builder.gd")

# ══════════════════════════════════════════════════════════════════════════════
# SIGNALS
# ══════════════════════════════════════════════════════════════════════════════
signal cube_hovered(tx: int, ty: int, si: int)
signal cube_clicked(tx: int, ty: int, si: int, face_idx: int)
signal corner_hovered(corners: Array)
signal selection_changed
signal status_message(msg: String)
signal texture_picked(fc: MD.FaceConfig)
signal map_changed
signal trigger_placed(tx: int, ty: int, si: int, trigger: MD.TriggerData)

# ══════════════════════════════════════════════════════════════════════════════
# TOOL ENUM
# ══════════════════════════════════════════════════════════════════════════════
enum Tool {
	SHARED_CORNER,  # 0
	FACE_HEIGHT,    # 1
	TEXTURE,        # 2
	SINGLE_CORNER,  # 3
	EYEDROPPER,     # 4
	TRIGGER,        # 5
}

# ══════════════════════════════════════════════════════════════════════════════
# STATE
# ══════════════════════════════════════════════════════════════════════════════
var map_data       : MD
var current_tool   : int = Tool.SHARED_CORNER
var selected_faces   : Array = []
var selected_corners : Array = []
var pending_texture  : MD.FaceConfig = null
var pending_trigger_type : int = MD.TriggerType.NONE

## Active texture layer: LAYER_BASE or LAYER_OVERLAY
var active_layer : int = MD.LAYER_BASE

var undo_redo    : UndoRedo
var snap_enabled : bool = false

var _clipboard_cube    : MD.CubeData = null
var _is_left_held      : bool = false
var _drag_painted_keys : Dictionary = {}

# ── Nœuds 3D ────────────────────────────────────────────────────────────────
var _sub_viewport : SubViewport
var _camera       : Camera3D
var _cam_rig      : Node3D
var _map_root     : Node3D
var _cube_root    : Node3D
var _overlay_root : Node3D   ## Overlay layer meshes
var _trigger_root : Node3D   ## Trigger visual markers
var _sel_root     : Node3D
var _grid_root    : Node3D

var _cube_nodes    : Dictionary = {}
var _overlay_nodes : Dictionary = {}
var _trigger_nodes : Dictionary = {}

# ── Caméra ───────────────────────────────────────────────────────────────────
var _cam_distance  : float = 12.0
var _cam_elevation : float = 45.0
var _cam_azimuth   : float = 225.0
var _is_orbiting   : bool  = false
var _is_panning    : bool  = false

var _vp_container : Control = null
var _physics_ready : bool = false

# ── Hover visuals ────────────────────────────────────────────────────────────
var _hover_corner_spheres : Array = []
var _hover_face_plane     : MeshInstance3D = null
var _hover_tile_outline   : MeshInstance3D = null

# ══════════════════════════════════════════════════════════════════════════════
# INIT
# ══════════════════════════════════════════════════════════════════════════════
func _init(md: MD) -> void:
	map_data  = md
	undo_redo = UndoRedo.new()

func _ready() -> void:
	_build_viewport()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_physics_ready = true
	_update_camera()

func _build_viewport() -> void:
	_sub_viewport = SubViewport.new()
	_sub_viewport.world_3d = World3D.new()
	_sub_viewport.size = Vector2i(1200, 800)
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.physics_object_picking      = true
	_sub_viewport.physics_object_picking_sort = true

	var env := WorldEnvironment.new()
	var e   := Environment.new()
	e.background_mode      = Environment.BG_COLOR
	e.background_color     = Color(0.12, 0.12, 0.15)
	e.ambient_light_color  = Color(0.6, 0.6, 0.65)
	e.ambient_light_energy = 0.7
	env.environment = e
	_sub_viewport.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.3
	_sub_viewport.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -150, 0)
	fill.light_energy = 0.4
	fill.shadow_enabled = false
	_sub_viewport.add_child(fill)

	_cam_rig = Node3D.new(); _cam_rig.name = "CameraRig"
	_sub_viewport.add_child(_cam_rig)
	_camera = Camera3D.new(); _camera.name = "Camera"
	_cam_rig.add_child(_camera)

	_map_root     = Node3D.new(); _map_root.name     = "MapRoot"
	_cube_root    = Node3D.new(); _cube_root.name    = "Cubes"
	_overlay_root = Node3D.new(); _overlay_root.name = "Overlays"
	_trigger_root = Node3D.new(); _trigger_root.name = "Triggers"
	_sel_root     = Node3D.new(); _sel_root.name     = "Selection"
	_grid_root    = Node3D.new(); _grid_root.name    = "Grid"
	_sub_viewport.add_child(_map_root)
	_map_root.add_child(_cube_root)
	_map_root.add_child(_overlay_root)
	_map_root.add_child(_trigger_root)
	_map_root.add_child(_sel_root)
	_map_root.add_child(_grid_root)

# ══════════════════════════════════════════════════════════════════════════════
# VIEWPORT SIZE SYNC
# ══════════════════════════════════════════════════════════════════════════════
func set_viewport_container(container: Control) -> void:
	_vp_container = container
	container.resized.connect(_sync_viewport_size)
	_sync_viewport_size()

func _sync_viewport_size() -> void:
	if _vp_container == null or _sub_viewport == null: return
	var s := Vector2i(int(_vp_container.size.x), int(_vp_container.size.y))
	if s.x > 8 and s.y > 8 and _sub_viewport.size != s:
		_sub_viewport.size = s

# ══════════════════════════════════════════════════════════════════════════════
# BUILD MAP
# ══════════════════════════════════════════════════════════════════════════════
func build_all() -> void:
	_clear_cube_nodes()
	for tx in map_data.grid_width:
		for ty in map_data.grid_height:
			_rebuild_tile(tx, ty)
	_rebuild_all_triggers()
	_build_grid_overlay()
	_center_camera_on_map()
	undo_redo.clear_history()
	map_changed.emit()

func _clear_cube_nodes() -> void:
	for child in _cube_root.get_children(): child.queue_free()
	for child in _overlay_root.get_children(): child.queue_free()
	for child in _trigger_root.get_children(): child.queue_free()
	_cube_nodes.clear()
	_overlay_nodes.clear()
	_trigger_nodes.clear()
	selected_corners.clear()
	selected_faces.clear()
	_clear_selection_nodes()

# ══════════════════════════════════════════════════════════════════════════════
# GRID
# ══════════════════════════════════════════════════════════════════════════════
func _build_grid_overlay() -> void:
	for ch in _grid_root.get_children(): ch.queue_free()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.5, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	var TS := MD.TILE_SIZE
	var W  := map_data.grid_width
	var H  := map_data.grid_height
	for ix in (W + 1):
		var x := float(ix) * TS - TS * 0.5
		_add_grid_line(Vector3(x, 0.01, -TS * 0.5),
					   Vector3(x, 0.01, float(H) * TS - TS * 0.5), mat)
	for iz in (H + 1):
		var z := float(iz) * TS - TS * 0.5
		_add_grid_line(Vector3(-TS * 0.5, 0.01, z),
					   Vector3(float(W) * TS - TS * 0.5, 0.01, z), mat)

func _add_grid_line(a: Vector3, b: Vector3, mat: Material) -> void:
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([a, b])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mi := MeshInstance3D.new(); mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	_grid_root.add_child(mi)

func toggle_grid(v: bool) -> void: _grid_root.visible = v

# ══════════════════════════════════════════════════════════════════════════════
# TILES
# ══════════════════════════════════════════════════════════════════════════════
func _rebuild_tile(tx: int, ty: int) -> void:
	for si in [-1, 0, 1, 2, 3]:
		var key := _cube_key(tx, ty, si)
		if _cube_nodes.has(key):
			_cube_nodes[key]["mi"].queue_free()
			_cube_nodes.erase(key)
		if _overlay_nodes.has(key):
			_overlay_nodes[key].queue_free()
			_overlay_nodes.erase(key)
	var td := map_data.get_tile(tx, ty)
	if td == null: return
	if not td.subdivided:
		_spawn_cube(tx, ty, -1, td.cubes[0], MD.TILE_SIZE)
	else:
		for si in 4:
			_spawn_cube(tx, ty, si, td.cubes[si], MD.TILE_SIZE * 0.5)

func _spawn_cube(tx: int, ty: int, si: int, cube: MD.CubeData, cube_size: float) -> void:
	var key  := _cube_key(tx, ty, si)
	var mesh := MB.build_cube(cube, cube_size)
	var mi   := MeshInstance3D.new()
	mi.name = key; mi.mesh = mesh
	mi.position = _cube_world_pos(tx, ty, si, cube_size)
	mi.set_meta("tx", tx); mi.set_meta("ty", ty); mi.set_meta("si", si)

	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask  = 0
	var cshape := CollisionShape3D.new()
	var shape  := BoxShape3D.new()
	var top_h  := cube.top_max()
	var by     := cube.base_y
	var height := maxf(top_h - by, 0.1)
	shape.size      = Vector3(cube_size * 0.98, height, cube_size * 0.98)
	cshape.position = Vector3(0, by + height * 0.5, 0)
	cshape.shape    = shape
	body.add_child(cshape)
	mi.add_child(body)
	_cube_root.add_child(mi)
	_cube_nodes[key] = {"mi": mi, "body": body}

	# Spawn overlay mesh if it has overlay textures
	if MB.has_overlay(cube):
		var ov_mesh := MB.build_cube_overlay(cube, cube_size)
		var ov_mi   := MeshInstance3D.new()
		ov_mi.name = key + "_ov"
		ov_mi.mesh = ov_mesh
		ov_mi.position = _cube_world_pos(tx, ty, si, cube_size) + Vector3(0, 0.002, 0)
		_overlay_root.add_child(ov_mi)
		_overlay_nodes[key] = ov_mi

static func _cube_world_pos(tx: int, ty: int, si: int, cube_size: float) -> Vector3:
	var TS := MD.TILE_SIZE
	var bx := float(tx) * TS
	var bz := float(ty) * TS
	if si < 0 or cube_size >= TS:
		return Vector3(bx, 0.0, bz)
	var off := MD.SUB_CENTER[si]
	return Vector3(bx + off.x * TS, 0.0, bz + off.y * TS)

static func _cube_key(tx: int, ty: int, si: int) -> String:
	return "%d,%d,%d" % [tx, ty, si]

func rebuild_cube(tx: int, ty: int, si: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null: return
	var cube_size := MD.TILE_SIZE if not td.subdivided else MD.TILE_SIZE * 0.5
	var cube := td.cubes[0 if si < 0 else si]
	var key  := _cube_key(tx, ty, si)

	# Rebuild base mesh
	if _cube_nodes.has(key):
		var mi : MeshInstance3D = _cube_nodes[key]["mi"]
		mi.mesh = MB.build_cube(cube, cube_size)
		var body : StaticBody3D = _cube_nodes[key]["body"]
		for ch in body.get_children(): ch.queue_free()
		var cshape := CollisionShape3D.new()
		var shape  := BoxShape3D.new()
		var top_h  := cube.top_max()
		var by     := cube.base_y
		var height := maxf(top_h - by, 0.1)
		shape.size      = Vector3(cube_size * 0.98, height, cube_size * 0.98)
		cshape.position = Vector3(0, by + height * 0.5, 0)
		cshape.shape    = shape
		body.add_child(cshape)
	else:
		_spawn_cube(tx, ty, si, cube, cube_size)
		return  # _spawn_cube handles overlay too

	# Rebuild overlay mesh
	if _overlay_nodes.has(key):
		_overlay_nodes[key].queue_free()
		_overlay_nodes.erase(key)
	if MB.has_overlay(cube):
		var ov_mesh := MB.build_cube_overlay(cube, cube_size)
		var ov_mi   := MeshInstance3D.new()
		ov_mi.name = key + "_ov"
		ov_mi.mesh = ov_mesh
		ov_mi.position = _cube_world_pos(tx, ty, si, cube_size) + Vector3(0, 0.002, 0)
		_overlay_root.add_child(ov_mi)
		_overlay_nodes[key] = ov_mi

	# Rebuild trigger visual
	_rebuild_trigger_visual(tx, ty, si)

# ══════════════════════════════════════════════════════════════════════════════
# TRIGGER VISUALS
# ══════════════════════════════════════════════════════════════════════════════
func _rebuild_all_triggers() -> void:
	for ch in _trigger_root.get_children(): ch.queue_free()
	_trigger_nodes.clear()
	for tx in map_data.grid_width:
		for ty in map_data.grid_height:
			var td := map_data.get_tile(tx, ty)
			if td == null: continue
			if td.subdivided:
				for si in 4:
					_rebuild_trigger_visual(tx, ty, si)
			else:
				_rebuild_trigger_visual(tx, ty, -1)

func _rebuild_trigger_visual(tx: int, ty: int, si: int) -> void:
	var key := _cube_key(tx, ty, si)
	if _trigger_nodes.has(key):
		_trigger_nodes[key].queue_free()
		_trigger_nodes.erase(key)

	var cube := map_data.get_cube(tx, ty, si)
	if cube == null or cube.trigger == null: return
	if cube.trigger.type == MD.TriggerType.NONE: return

	var td := map_data.get_tile(tx, ty)
	var cs := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var pos := _cube_world_pos(tx, ty, si, cs)
	var y := cube.top_max() + 0.15

	# Create a billboard label with the trigger icon
	var mi := MeshInstance3D.new()
	mi.name = key + "_trig"
	mi.position = pos + Vector3(0, y, 0)

	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	mi.mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	# Color based on trigger type
	match cube.trigger.type:
		MD.TriggerType.SPAWN_POINT:    mat.albedo_color = Color(1.0, 0.3, 0.3)
		MD.TriggerType.CHEST:          mat.albedo_color = Color(1.0, 0.85, 0.2)
		MD.TriggerType.DOOR:           mat.albedo_color = Color(0.6, 0.4, 0.2)
		MD.TriggerType.DRAWBRIDGE:     mat.albedo_color = Color(0.5, 0.5, 0.5)
		MD.TriggerType.ANIMATION:      mat.albedo_color = Color(0.9, 0.5, 1.0)
		MD.TriggerType.PARTICLES:      mat.albedo_color = Color(0.3, 1.0, 0.8)
		MD.TriggerType.USABLE_OBJECT:  mat.albedo_color = Color(0.3, 0.7, 1.0)
		MD.TriggerType.MESH_MARKER:    mat.albedo_color = Color(0.7, 0.7, 0.7)
		_: mat.albedo_color = Color(1, 1, 1)
	mi.set_surface_override_material(0, mat)
	_trigger_root.add_child(mi)
	_trigger_nodes[key] = mi

func toggle_triggers_visible(v: bool) -> void:
	_trigger_root.visible = v

# ══════════════════════════════════════════════════════════════════════════════
# CAMERA
# ══════════════════════════════════════════════════════════════════════════════
func _center_camera_on_map() -> void:
	var TS := MD.TILE_SIZE
	var cx := (float(map_data.grid_width)  * TS) * 0.5 - TS * 0.5
	var cz := (float(map_data.grid_height) * TS) * 0.5 - TS * 0.5
	_cam_rig.position  = Vector3(cx, 0.0, cz)
	_cam_distance      = maxf(8.0, maxf(map_data.grid_width, map_data.grid_height) * 1.5)
	_cam_elevation     = 45.0
	_cam_azimuth       = 225.0
	_update_camera()

func _update_camera() -> void:
	if _camera == null: return
	var az := deg_to_rad(_cam_azimuth)
	var el := deg_to_rad(_cam_elevation)
	var d  := _cam_distance
	_camera.position = Vector3(sin(az) * cos(el) * d, sin(el) * d, cos(az) * cos(el) * d)
	_camera.look_at(_cam_rig.global_position, Vector3.UP)

func pan_camera(direction: Vector3) -> void:
	var speed := _cam_distance * 0.04
	_cam_rig.position += direction * speed
	var limit := maxf(map_data.grid_width, map_data.grid_height) * MD.TILE_SIZE * 2.5
	_cam_rig.position = _cam_rig.position.clamp(
		Vector3(-limit, -5.0, -limit), Vector3(limit, 10.0, limit))

func reset_camera() -> void:
	_center_camera_on_map()
	status_message.emit("🎯 Caméra recentrée")

func zoom_in() -> void:
	_cam_distance = maxf(2.0, _cam_distance * 0.82)
	_update_camera()
	status_message.emit("Zoom : %.1f" % _cam_distance)

func zoom_out() -> void:
	_cam_distance = minf(80.0, _cam_distance * 1.22)
	_update_camera()
	status_message.emit("Zoom : %.1f" % _cam_distance)

func elevate_camera(delta_deg: float) -> void:
	_cam_elevation = clampf(_cam_elevation + delta_deg, 5.0, 89.0)
	_update_camera()
	status_message.emit("Élévation : %.0f°" % _cam_elevation)

func look_from_azimuth(azimuth: float) -> void:
	_cam_azimuth = azimuth
	_update_camera()
	var labels := {
		0.0: "Nord", 45.0: "Nord-Est", 90.0: "Est", 135.0: "Sud-Est",
		180.0: "Sud", 225.0: "Sud-Ouest", 270.0: "Ouest", 315.0: "Nord-Ouest"
	}
	status_message.emit("Vue depuis le %s" % labels.get(azimuth, "%.0f°" % azimuth))

# ══════════════════════════════════════════════════════════════════════════════
# INPUT
# ══════════════════════════════════════════════════════════════════════════════
func handle_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)

func _on_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			_is_orbiting = false
			_is_panning  = false
			if event.shift_pressed or (event.button_index == MOUSE_BUTTON_MIDDLE and event.alt_pressed):
				_is_panning = true
			elif event.alt_pressed:
				_is_panning = true
			else:
				_is_orbiting = true
		else:
			_is_orbiting = false
			_is_panning  = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_cam_distance = maxf(2.0, _cam_distance * 0.9); _update_camera()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_cam_distance = minf(80.0, _cam_distance * 1.1); _update_camera()

	elif event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_left_held = true
			_drag_painted_keys.clear()
			if not _is_orbiting and not _is_panning:
				_do_tool_click(event.position)
		else:
			_is_left_held = false
			_drag_painted_keys.clear()

func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _is_orbiting:
		_cam_azimuth   += event.relative.x * 0.5
		_cam_elevation  = clampf(_cam_elevation - event.relative.y * 0.4, 5.0, 89.0)
		_update_camera()
	elif _is_panning:
		var right := _camera.global_transform.basis.x
		_cam_rig.position -= right      * event.relative.x * 0.02 * (_cam_distance / 12.0)
		_cam_rig.position += Vector3.UP * event.relative.y * 0.02 * (_cam_distance / 12.0)
	else:
		_do_tool_hover(event.position)
		if _is_left_held:
			_do_tool_drag(event.position)

# ══════════════════════════════════════════════════════════════════════════════
# RAYCAST
# ══════════════════════════════════════════════════════════════════════════════
func _raycast(mouse_pos: Vector2) -> Dictionary:
	if not _physics_ready or _camera == null:
		return {}

	_sync_viewport_size()
	var vp_size  := Vector2(_sub_viewport.size)
	var final_pos := mouse_pos

	if _vp_container != null:
		var ct := _vp_container.size
		if ct.x > 0.0 and ct.y > 0.0 and vp_size.x > 0.0 and vp_size.y > 0.0:
			final_pos = mouse_pos * vp_size / ct

	var world := _sub_viewport.get_world_3d()
	if world == null: return {}
	var space := world.get_direct_space_state()
	if space == null: return {}

	var from := _camera.project_ray_origin(final_pos)
	var dir  := _camera.project_ray_normal(final_pos)

	var params := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0)
	params.collision_mask = 1
	var result := space.intersect_ray(params)
	return result

func _hit_to_cube_info(hit: Dictionary) -> Dictionary:
	if hit.is_empty(): return {}
	var collider = hit.get("collider")
	if collider == null: return {}
	var mi = collider.get_parent()
	if not (mi is MeshInstance3D): mi = collider
	if not (mi is MeshInstance3D): return {}
	if not mi.has_meta("tx"): return {}
	return {
		"tx":     mi.get_meta("tx"),
		"ty":     mi.get_meta("ty"),
		"si":     mi.get_meta("si"),
		"pos":    hit.get("position", Vector3.ZERO),
		"normal": hit.get("normal",   Vector3.UP),
	}

func _hit_face_idx(normal: Vector3) -> int:
	var ax := absf(normal.x)
	var ay := absf(normal.y)
	var az := absf(normal.z)
	if ay >= ax and ay >= az:
		return MD.FACE_TOP if normal.y > 0 else MD.FACE_BOTTOM
	if ax >= az:
		return MD.FACE_EAST if normal.x > 0 else MD.FACE_WEST
	return MD.FACE_SOUTH if normal.z > 0 else MD.FACE_NORTH

func _nearest_corner(tx: int, ty: int, si: int, hit_pos: Vector3) -> int:
	var best_ci := 0
	var best_d  := INF
	for ci in 4:
		var p    := map_data.get_corner_world_xz(tx, ty, si, ci)
		var cube := map_data.get_cube(tx, ty, si)
		var y    := cube.corners[ci] if cube else 0.5
		var d    := hit_pos.distance_squared_to(Vector3(p.x, y, p.y))
		if d < best_d:
			best_d = d; best_ci = ci
	return best_ci

func _nearest_grid_corner_xz(hit_pos: Vector3) -> Vector2:
	var TS := MD.TILE_SIZE
	return Vector2(
		roundf(hit_pos.x / (TS * 0.5)) * (TS * 0.5),
		roundf(hit_pos.z / (TS * 0.5)) * (TS * 0.5))

# ══════════════════════════════════════════════════════════════════════════════
# HOVER VISUALS
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_hover(mouse_pos: Vector2) -> void:
	if not _physics_ready: return
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	_clear_hover_visuals()
	if info.is_empty(): return
	var tx := info["tx"] as int
	var ty := info["ty"] as int
	var si := info["si"] as int
	_show_tile_outline(tx, ty, si, Color(1.0, 0.85, 0.1, 1.0))
	match current_tool:
		Tool.SHARED_CORNER:
			var gxz    := _nearest_grid_corner_xz(info["pos"])
			var shared := map_data.get_shared_corners(gxz.x, gxz.y)
			_show_corner_spheres(shared, Color(1, 0.9, 0, 1))
			corner_hovered.emit(shared)
		Tool.SINGLE_CORNER:
			var ci := _nearest_corner(tx, ty, si, info["pos"])
			_show_corner_spheres([{"tx":tx,"ty":ty,"si":si,"ci":ci}], Color(1, 0.9, 0, 1))
			corner_hovered.emit([{"tx":tx,"ty":ty,"si":si,"ci":ci}])
		Tool.FACE_HEIGHT, Tool.TEXTURE, Tool.EYEDROPPER:
			_show_face_highlight(tx, ty, si, _hit_face_idx(info["normal"]), MB.hover_material())
			cube_hovered.emit(tx, ty, si)
		Tool.TRIGGER:
			cube_hovered.emit(tx, ty, si)

func _build_tile_outline_mesh(tx: int, ty: int, si: int,
							   cube: MD.CubeData, color: Color) -> MeshInstance3D:
	var td := map_data.get_tile(tx, ty)
	if td == null: return null
	var cs  := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var pos := _cube_world_pos(tx, ty, si, cs)
	var hx  := cs * 0.5 + 0.035
	var hz  := hx
	var yt  := cube.top_max() + 0.035
	var yb  := cube.base_y - 0.01
	var lines := PackedVector3Array([
		Vector3(-hx,yt,-hz), Vector3( hx,yt,-hz), Vector3( hx,yt,-hz), Vector3( hx,yt, hz),
		Vector3( hx,yt, hz), Vector3(-hx,yt, hz), Vector3(-hx,yt, hz), Vector3(-hx,yt,-hz),
		Vector3(-hx,yb,-hz), Vector3(-hx,yt,-hz), Vector3( hx,yb,-hz), Vector3( hx,yt,-hz),
		Vector3( hx,yb, hz), Vector3( hx,yt, hz), Vector3(-hx,yb, hz), Vector3(-hx,yt, hz),
	])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.position = pos; mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	return mi

func _show_tile_outline(tx: int, ty: int, si: int, color: Color) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null: return
	var mi := _build_tile_outline_mesh(tx, ty, si, cube, color)
	if mi:
		_sel_root.add_child(mi)
		_hover_tile_outline = mi

func _show_corner_spheres(corners: Array, color: Color) -> void:
	for cr in corners:
		var p    := map_data.get_corner_world_xz(cr["tx"], cr["ty"], cr["si"], cr["ci"])
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		var y    := (cube.corners[cr["ci"]] + 0.06) if cube else 0.5
		var mi   := MeshInstance3D.new()
		mi.position = Vector3(p.x, y, p.y)
		var mat  := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.mesh = SphereMesh.new()
		(mi.mesh as SphereMesh).radius = 0.10
		(mi.mesh as SphereMesh).height = 0.20
		mi.set_surface_override_material(0, mat)
		_sel_root.add_child(mi)
		_hover_corner_spheres.append(mi)

func _show_face_highlight(tx: int, ty: int, si: int, fi: int, mat: Material) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null: return
	var td  := map_data.get_tile(tx, ty)
	var cs  := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var mi  := MeshInstance3D.new()
	mi.position = _cube_world_pos(tx, ty, si, cs)
	mi.mesh     = MB.build_cube(cube, cs * 1.01)
	var invis := StandardMaterial3D.new()
	invis.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	invis.albedo_color = Color(0, 0, 0, 0)
	for s in 6: mi.set_surface_override_material(s, invis)
	mi.set_surface_override_material(fi, mat)
	_sel_root.add_child(mi)
	_hover_face_plane = mi

func _clear_hover_visuals() -> void:
	for s in _hover_corner_spheres:
		if is_instance_valid(s): s.queue_free()
	_hover_corner_spheres.clear()
	if _hover_face_plane != null and is_instance_valid(_hover_face_plane):
		_hover_face_plane.queue_free(); _hover_face_plane = null
	if _hover_tile_outline != null and is_instance_valid(_hover_tile_outline):
		_hover_tile_outline.queue_free(); _hover_tile_outline = null

# ══════════════════════════════════════════════════════════════════════════════
# TOOL — CLICK
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_click(mouse_pos: Vector2) -> void:
	if not _physics_ready:
		status_message.emit("Initialisation en cours…")
		return
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	if info.is_empty():
		clear_selection(); return

	var tx      := info["tx"] as int
	var ty      := info["ty"] as int
	var si      := info["si"] as int
	var hit_pos := info["pos"] as Vector3
	var normal  := info["normal"] as Vector3

	match current_tool:
		Tool.SHARED_CORNER:
			var gxz    := _nearest_grid_corner_xz(hit_pos)
			var shared := map_data.get_shared_corners(gxz.x, gxz.y)
			selected_corners = shared; selected_faces.clear()
			_refresh_selection_overlay(); selection_changed.emit()
			status_message.emit("🔵 %d coin(s) sélectionné(s)" % shared.size())

		Tool.SINGLE_CORNER:
			var ci := _nearest_corner(tx, ty, si, hit_pos)
			selected_corners = [{"tx":tx,"ty":ty,"si":si,"ci":ci}]
			selected_faces.clear()
			_refresh_selection_overlay(); selection_changed.emit()
			status_message.emit("🔵 Coin (%d,%d) sélectionné" % [tx, ty])

		Tool.FACE_HEIGHT:
			var fi    := _hit_face_idx(normal)
			var found := false
			for i in selected_faces.size():
				var sf := selected_faces[i] as Dictionary
				if sf["tx"]==tx and sf["ty"]==ty and sf["si"]==si and sf["face_idx"]==fi:
					selected_faces.remove_at(i); found = true; break
			if not found: selected_faces.append({"tx":tx,"ty":ty,"si":si,"face_idx":fi})
			selected_corners.clear()
			_refresh_selection_overlay(); selection_changed.emit()
			cube_clicked.emit(tx, ty, si, fi)
			status_message.emit("🟦 Face sélectionnée sur tuile (%d,%d)" % [tx, ty])

		Tool.TEXTURE:
			if pending_texture != null:
				var fi  := _hit_face_idx(normal)
				var key := "%s_%d_%d" % [_cube_key(tx, ty, si), fi, active_layer]
				if not _drag_painted_keys.has(key):
					_apply_texture_to_face(tx, ty, si, fi)
					_drag_painted_keys[key] = true
			else:
				status_message.emit("Sélectionnez d'abord une texture dans la barre latérale")
			cube_clicked.emit(tx, ty, si, _hit_face_idx(normal))

		Tool.EYEDROPPER:
			var fi   := _hit_face_idx(normal)
			var cube := map_data.get_cube(tx, ty, si)
			if cube:
				var fc : MD.FaceConfig = cube.get_face_config(fi, active_layer)
				if fc.has_texture():
					pending_texture = fc.dup()
					texture_picked.emit(fc)
					var layer_name := "overlay" if active_layer == MD.LAYER_OVERLAY else "base"
					status_message.emit("💧 Texture récupérée (%s) de (%d,%d) face %d" % [layer_name, tx, ty, fi])
				else:
					status_message.emit("💧 Cette face n'a pas de texture sur cette couche")

		Tool.TRIGGER:
			_place_trigger(tx, ty, si)

# ══════════════════════════════════════════════════════════════════════════════
# TRIGGER PLACEMENT
# ══════════════════════════════════════════════════════════════════════════════
func _place_trigger(tx: int, ty: int, si: int) -> void:
	if pending_trigger_type == MD.TriggerType.NONE:
		# If clicking with NONE, remove existing trigger
		var cube := map_data.get_cube(tx, ty, si)
		if cube != null and cube.trigger != null and cube.trigger.type != MD.TriggerType.NONE:
			cube.trigger = MD.TriggerData.new()
			_rebuild_trigger_visual(tx, ty, si)
			map_changed.emit()
			status_message.emit("🗑 Trigger supprimé de (%d,%d)" % [tx, ty])
		else:
			status_message.emit("Sélectionnez un type de trigger dans le panneau")
		return

	var trigger := MD.TriggerData.new()
	trigger.type = pending_trigger_type
	trigger.id = "%s_%d_%d_%d" % [MD.TRIGGER_NAMES[pending_trigger_type].to_lower().replace(" ", "_"), tx, ty, si]

	# Set default properties based on type
	match pending_trigger_type:
		MD.TriggerType.MESH_MARKER:
			trigger.properties["mesh_path"] = ""
			trigger.properties["rotation_y"] = 0.0
			trigger.properties["scale"] = 1.0
		MD.TriggerType.SPAWN_POINT:
			trigger.properties["entity_type"] = "default"
			trigger.properties["count"] = 1
		MD.TriggerType.CHEST:
			trigger.properties["locked"] = false
			trigger.properties["key_id"] = ""
			trigger.properties["loot_table"] = ""
		MD.TriggerType.DOOR:
			trigger.properties["locked"] = false
			trigger.properties["key_id"] = ""
			trigger.properties["destination"] = ""
		MD.TriggerType.DRAWBRIDGE:
			trigger.properties["raised"] = true
			trigger.properties["trigger_id"] = ""
		MD.TriggerType.ANIMATION:
			trigger.properties["anim_name"] = ""
			trigger.properties["loop"] = false
		MD.TriggerType.PARTICLES:
			trigger.properties["effect_name"] = ""
			trigger.properties["color"] = "#ffffff"
		MD.TriggerType.USABLE_OBJECT:
			trigger.properties["action"] = ""
			trigger.properties["item_id"] = ""

	map_data.set_trigger(tx, ty, si, trigger)
	_rebuild_trigger_visual(tx, ty, si)
	map_changed.emit()
	trigger_placed.emit(tx, ty, si, trigger)
	var icon : String = MD.TRIGGER_ICONS.get(pending_trigger_type, "")
	status_message.emit("%s Trigger '%s' placé sur (%d,%d)" % [icon, MD.TRIGGER_NAMES[pending_trigger_type], tx, ty])

func set_pending_trigger(type: int) -> void:
	pending_trigger_type = type

# ══════════════════════════════════════════════════════════════════════════════
# DRAG
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_drag(mouse_pos: Vector2) -> void:
	if not _physics_ready: return
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	if info.is_empty(): return
	var tx := info["tx"] as int
	var ty := info["ty"] as int
	var si := info["si"] as int
	match current_tool:
		Tool.TEXTURE:
			if pending_texture != null:
				var fi  := _hit_face_idx(info["normal"])
				var key := "%s_%d_%d" % [_cube_key(tx, ty, si), fi, active_layer]
				if not _drag_painted_keys.has(key):
					_apply_texture_to_face(tx, ty, si, fi)
					_drag_painted_keys[key] = true

func _apply_texture_to_face(tx: int, ty: int, si: int, fi: int) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null or pending_texture == null: return
	cube.set_face_config(fi, active_layer, pending_texture.dup())
	rebuild_cube(tx, ty, si)
	map_changed.emit()
	var layer_name := "overlay" if active_layer == MD.LAYER_OVERLAY else "base"
	status_message.emit("🖌 Texture appliquée (%s) sur (%d,%d) face %d" % [layer_name, tx, ty, fi])

# ══════════════════════════════════════════════════════════════════════════════
# HEIGHT
# ══════════════════════════════════════════════════════════════════════════════
func adjust_height(delta: float) -> void:
	if not selected_corners.is_empty():
		_adjust_corner_heights(delta)
	elif not selected_faces.is_empty():
		_adjust_face_heights(delta)
	else:
		status_message.emit("Sélectionnez d'abord un coin ou une face")

func _apply_snapped_height(current: float, delta: float) -> float:
	var new_h := current + delta
	if snap_enabled: new_h = snappedf(new_h, MD.HEIGHT_STEP)
	return clampf(new_h, MD.MIN_H, MD.MAX_H)

func _adjust_corner_heights(delta: float) -> void:
	var before    := _snapshot_cubes_from_corners()
	var sel_saved := selected_corners.duplicate(true)
	for cr in selected_corners:
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		if cube == null: continue
		var ci : int = cr["ci"]
		cube.corners[ci] = _apply_snapped_height(cube.corners[ci], delta)
	_rebuild_affected_tiles_from_corners()
	_refresh_selection_overlay(); map_changed.emit()
	var after := _snapshot_cubes_from_corners()
	undo_redo.create_action("Ajuster hauteur coins")
	undo_redo.add_do_method(_restore_cube_snapshot.bind(after,  sel_saved, false))
	undo_redo.add_undo_method(_restore_cube_snapshot.bind(before, sel_saved, false))
	undo_redo.commit_action(false)

func _adjust_face_heights(delta: float) -> void:
	var before    := _snapshot_cubes_from_faces()
	var sel_saved := selected_faces.duplicate(true)
	for sf in selected_faces:
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube == null: continue
		for ci in MD.face_top_corners(sf["face_idx"]):
			cube.corners[ci] = _apply_snapped_height(cube.corners[ci], delta)
	_rebuild_affected_tiles_from_faces()
	_refresh_selection_overlay(); map_changed.emit()
	var after := _snapshot_cubes_from_faces()
	undo_redo.create_action("Ajuster hauteur faces")
	undo_redo.add_do_method(_restore_cube_snapshot.bind(after,  sel_saved, true))
	undo_redo.add_undo_method(_restore_cube_snapshot.bind(before, sel_saved, true))
	undo_redo.commit_action(false)

func _snapshot_cubes_from_corners() -> Dictionary:
	var state := {}
	for cr in selected_corners:
		var k := "%d,%d,%d" % [cr["tx"], cr["ty"], cr["si"]]
		if not state.has(k):
			var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
			if cube: state[k] = cube.corners.duplicate()
	return state

func _snapshot_cubes_from_faces() -> Dictionary:
	var state := {}
	for sf in selected_faces:
		var k := "%d,%d,%d" % [sf["tx"], sf["ty"], sf["si"]]
		if not state.has(k):
			var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
			if cube: state[k] = cube.corners.duplicate()
	return state

func _restore_cube_snapshot(state: Dictionary, sel: Array, is_faces: bool) -> void:
	var tiles := {}
	for k in state:
		var p : PackedStringArray = k.split(",")
		var cube := map_data.get_cube(int(p[0]), int(p[1]), int(p[2]))
		if cube: cube.corners = state[k].duplicate()
		tiles["%d,%d" % [int(p[0]), int(p[1])]] = true
	for tk in tiles:
		var p : PackedStringArray = tk.split(",")
		_rebuild_tile(int(p[0]), int(p[1]))
	if is_faces: selected_faces = sel; selected_corners = []
	else:        selected_corners = sel; selected_faces = []
	_refresh_selection_overlay(); map_changed.emit()

func _rebuild_affected_tiles_from_corners() -> void:
	var done := {}
	for cr in selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k): done[k] = true; _rebuild_tile(cr["tx"], cr["ty"])

func _rebuild_affected_tiles_from_faces() -> void:
	var done := {}
	for sf in selected_faces:
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k): done[k] = true; _rebuild_tile(sf["tx"], sf["ty"])

# ══════════════════════════════════════════════════════════════════════════════
# UNDO / REDO
# ══════════════════════════════════════════════════════════════════════════════
func undo() -> void:
	if undo_redo.has_undo():
		undo_redo.undo()
		status_message.emit("↶  Annulé : " + undo_redo.get_current_action_name())
	else:
		status_message.emit("Rien à annuler")

func redo() -> void:
	if undo_redo.has_redo():
		undo_redo.redo()
		status_message.emit("↷  Rétabli")
	else:
		status_message.emit("Rien à rétablir")

# ══════════════════════════════════════════════════════════════════════════════
# COPY / PASTE
# ══════════════════════════════════════════════════════════════════════════════
func copy_selected() -> void:
	var cube : MD.CubeData = null
	if not selected_faces.is_empty():
		var sf := selected_faces[0] as Dictionary
		cube = map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
	elif not selected_corners.is_empty():
		var cr := selected_corners[0] as Dictionary
		cube = map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
	if cube == null:
		status_message.emit("Sélectionnez une tuile avant de copier"); return
	_clipboard_cube = cube.dup()
	status_message.emit("✓ Tuile copiée")

func paste_selected() -> void:
	if _clipboard_cube == null:
		status_message.emit("Presse-papiers vide"); return
	var targets := {}
	for sf in selected_faces:
		targets["%d,%d,%d" % [sf["tx"],sf["ty"],sf["si"]]] = {"tx":sf["tx"],"ty":sf["ty"],"si":sf["si"]}
	for cr in selected_corners:
		targets["%d,%d,%d" % [cr["tx"],cr["ty"],cr["si"]]] = {"tx":cr["tx"],"ty":cr["ty"],"si":cr["si"]}
	if targets.is_empty():
		status_message.emit("Sélectionnez des tuiles cibles avant de coller"); return
	for k in targets:
		var t    := targets[k] as Dictionary
		var cube := map_data.get_cube(t["tx"], t["ty"], t["si"])
		if cube == null: continue
		cube.corners = _clipboard_cube.corners.duplicate()
		for fi in 6:
			cube.face_configs[fi] = _clipboard_cube.face_configs[fi].dup()
			cube.overlay_configs[fi] = _clipboard_cube.overlay_configs[fi].dup()
		if _clipboard_cube.trigger != null:
			cube.trigger = _clipboard_cube.trigger.dup()
		_rebuild_tile(t["tx"], t["ty"])
	map_changed.emit()
	status_message.emit("✓ Collé sur %d zone(s)" % targets.size())

# ══════════════════════════════════════════════════════════════════════════════
# SELECTION OVERLAY
# ══════════════════════════════════════════════════════════════════════════════
func _clear_selection_nodes() -> void:
	for ch in _sel_root.get_children(): ch.queue_free()
	_hover_corner_spheres.clear()
	_hover_face_plane   = null
	_hover_tile_outline = null

func _refresh_selection_overlay() -> void:
	_clear_selection_nodes()
	var sel_mat  := MB.selection_material()
	var outlined := {}

	for cr in selected_corners:
		var ok := "%d,%d,%d" % [cr["tx"],cr["ty"],cr["si"]]
		if not outlined.has(ok):
			outlined[ok] = true
			var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
			if cube:
				var mi := _build_tile_outline_mesh(cr["tx"],cr["ty"],cr["si"],cube,Color(1.0,0.85,0.1,1.0))
				if mi: _sel_root.add_child(mi)
		var p    := map_data.get_corner_world_xz(cr["tx"],cr["ty"],cr["si"],cr["ci"])
		var cube := map_data.get_cube(cr["tx"],cr["ty"],cr["si"])
		var y    := (cube.corners[cr["ci"]] + 0.06) if cube else 0.5
		var smi  := MeshInstance3D.new()
		smi.position = Vector3(p.x, y, p.y)
		var smat := StandardMaterial3D.new()
		smat.albedo_color = Color(0.1, 0.6, 1.0)
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		smi.mesh = SphereMesh.new()
		(smi.mesh as SphereMesh).radius = 0.12
		(smi.mesh as SphereMesh).height = 0.24
		smi.set_surface_override_material(0, smat)
		_sel_root.add_child(smi)

	for sf in selected_faces:
		var td := map_data.get_tile(sf["tx"], sf["ty"])
		if td == null: continue
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube == null: continue
		var cs := MD.TILE_SIZE if not td.subdivided else MD.TILE_SIZE * 0.5
		var ok := "%d,%d,%d" % [sf["tx"],sf["ty"],sf["si"]]
		if not outlined.has(ok):
			outlined[ok] = true
			var omi := _build_tile_outline_mesh(sf["tx"],sf["ty"],sf["si"],cube,Color(1.0,0.85,0.1,1.0))
			if omi: _sel_root.add_child(omi)
		var hi_mesh := MB.build_cube(cube, cs * 1.015)
		var fmi     := MeshInstance3D.new()
		fmi.position = _cube_world_pos(sf["tx"],sf["ty"],sf["si"],cs)
		fmi.mesh     = hi_mesh
		var invis    := StandardMaterial3D.new()
		invis.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		invis.albedo_color = Color(0, 0, 0, 0)
		for s in 6: fmi.set_surface_override_material(s, invis)
		fmi.set_surface_override_material(sf["face_idx"], sel_mat)
		_sel_root.add_child(fmi)

func clear_selection() -> void:
	selected_corners.clear(); selected_faces.clear()
	_clear_selection_nodes(); selection_changed.emit()

# ══════════════════════════════════════════════════════════════════════════════
# SUBDIVISION / MERGE
# ══════════════════════════════════════════════════════════════════════════════
func subdivide_tile(tx: int, ty: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null or td.subdivided: return
	td.subdivide(); _rebuild_tile(tx, ty); clear_selection(); map_changed.emit()

func merge_tile(tx: int, ty: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null or not td.subdivided: return
	td.merge(); _rebuild_tile(tx, ty); clear_selection(); map_changed.emit()

# ══════════════════════════════════════════════════════════════════════════════
# TEST MODE
# ══════════════════════════════════════════════════════════════════════════════
func toggle_test_mode(enabled: bool) -> void:
	_cube_root.visible    = not enabled
	_overlay_root.visible = not enabled
	_grid_root.visible    = not enabled
	_trigger_root.visible = not enabled

func export_to_json_map() -> Dictionary:
	var jm := {"width": map_data.grid_width, "height": map_data.grid_height, "tiles": []}
	for ty in map_data.grid_height:
		var row : Array = []
		for tx in map_data.grid_width:
			var td := map_data.get_tile(tx, ty)
			var cube := td.cubes[0]
			row.append({"type":0,"height":int(cube.top_max()/MD.HEIGHT_STEP),"walkable":true})
		jm["tiles"].append(row)
	return jm

# ══════════════════════════════════════════════════════════════════════════════
# LAYER
# ══════════════════════════════════════════════════════════════════════════════
func set_active_layer(layer: int) -> void:
	active_layer = layer
	var name := "Overlay (haute)" if layer == MD.LAYER_OVERLAY else "Base (basse)"
	status_message.emit("Couche active : %s" % name)

func get_active_layer() -> int:
	return active_layer

# ══════════════════════════════════════════════════════════════════════════════
# ACCESSORS
# ══════════════════════════════════════════════════════════════════════════════
func get_sub_viewport() -> SubViewport: return _sub_viewport
func set_tool(t: int) -> void: current_tool = t; clear_selection()
func set_pending_texture(fc: MD.FaceConfig) -> void: pending_texture = fc
func set_snap(enabled: bool) -> void:
	snap_enabled = enabled
	status_message.emit("Snap hauteur : %s" % ("✓ ON" if enabled else "OFF"))
