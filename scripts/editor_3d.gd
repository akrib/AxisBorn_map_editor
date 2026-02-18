## editor_3d.gd
## Manages the 3D viewport: SubViewport, Camera, cube MeshInstances, picking.
## Also implements all tool logic (corner/face/texture selection).
extends Node

const MD := preload("res://scripts/map_data.gd")
const MB := preload("res://scripts/mesh_builder.gd")

# ══════════════════════════════════════════════════════════════════════════════
# SIGNALS
# ══════════════════════════════════════════════════════════════════════════════
signal cube_hovered(tx: int, ty: int, si: int)
signal cube_clicked(tx: int, ty: int, si: int, face_idx: int)
signal corner_hovered(corners: Array)   ## Array of {tx,ty,si,ci}
signal selection_changed

# ══════════════════════════════════════════════════════════════════════════════
# TOOL ENUM
# ══════════════════════════════════════════════════════════════════════════════
enum Tool {
	SHARED_CORNER,   ## raises/lowers the 4 shared corners at a grid intersection
	FACE_HEIGHT,     ## selects face(s) and raises/lowers their top edge
	TEXTURE,         ## applies current texture to clicked face
	SINGLE_CORNER,   ## raises/lowers one corner of one cube
}

# ══════════════════════════════════════════════════════════════════════════════
# STATE
# ══════════════════════════════════════════════════════════════════════════════
var map_data       : MD
var current_tool   : int = Tool.SHARED_CORNER
var selected_faces = []
var selected_corners = []

## Current texture to apply (set by SideBar)
var pending_texture : MD.FaceConfig = null

# 3D nodes
var _sub_viewport  : SubViewport
var _camera        : Camera3D
var _cam_rig       : Node3D
var _map_root      : Node3D
var _cube_root     : Node3D
var _sel_root      : Node3D

## cube_key → {"mi": MeshInstance3D, "body": StaticBody3D}
var _cube_nodes: Dictionary = {}

## Camera orbit state
var _cam_distance  : float = 12.0
var _cam_elevation : float = 40.0   ## degrees
var _cam_azimuth   : float = 45.0   ## degrees
var _cam_pan       : Vector2 = Vector2.ZERO
var _is_orbiting   : bool = false
var _is_panning    : bool = false
var _last_mouse    : Vector2 = Vector2.ZERO

## Hover indicators
var _hover_corner_spheres : Array = []  ## Array[MeshInstance3D]
var _hover_face_plane     : MeshInstance3D = null

# ══════════════════════════════════════════════════════════════════════════════
# INIT
# ══════════════════════════════════════════════════════════════════════════════
func _init(md: MD) -> void:
	map_data = md

func _ready() -> void:
	_build_viewport()
	await get_tree().process_frame   # ✔ attendre d’être dans l’arbre
	_update_camera()

func _build_viewport() -> void:
	_sub_viewport = SubViewport.new()
	_sub_viewport.size = Vector2i(1, 1)  ## resized by container
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.physics_object_picking  = true
	# Ne pas l’ajouter ici !
	# Il sera ajouté par EditorUI
	#add_child(_sub_viewport)

	# Environment
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode       = Environment.BG_COLOR
	e.background_color      = Color(0.15, 0.15, 0.18)
	e.ambient_light_color   = Color(0.5, 0.5, 0.5)
	e.ambient_light_energy  = 0.6
	env.environment = e
	_sub_viewport.add_child(env)

	# Light
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy     = 1.2
	_sub_viewport.add_child(sun)

	# Camera rig
	_cam_rig = Node3D.new()
	_cam_rig.name = "CameraRig"
	_sub_viewport.add_child(_cam_rig)
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_cam_rig.add_child(_camera)

	# Map scene root
	_map_root  = Node3D.new(); _map_root.name  = "MapRoot"
	_cube_root = Node3D.new(); _cube_root.name = "Cubes"
	_sel_root  = Node3D.new(); _sel_root.name  = "Selection"
	_sub_viewport.add_child(_map_root)
	_map_root.add_child(_cube_root)
	_map_root.add_child(_sel_root)


## Called by EditorUI once the map is initialized.
func build_all() -> void:
	_clear_cube_nodes()
	for tx in map_data.grid_width:
		for ty in map_data.grid_height:
			_rebuild_tile(tx, ty)
	_center_camera_on_map()

func _clear_cube_nodes() -> void:
	for child in _cube_root.get_children():
		child.queue_free()
	_cube_nodes.clear()
	selected_corners.clear()
	selected_faces.clear()
	_clear_selection_nodes()

# ══════════════════════════════════════════════════════════════════════════════
# TILE / CUBE BUILDING
# ══════════════════════════════════════════════════════════════════════════════

## Rebuild all cubes for one tile (full or subdivided).
func _rebuild_tile(tx: int, ty: int) -> void:
	# Remove old nodes for this tile
	for si in [-1, 0, 1, 2, 3]:
		var key := _cube_key(tx, ty, si)
		if _cube_nodes.has(key):
			_cube_nodes[key]["mi"].queue_free()
			_cube_nodes.erase(key)

	var td := map_data.get_tile(tx, ty)
	if td == null: return

	if not td.subdivided:
		_spawn_cube(tx, ty, -1, td.cubes[0], MD.TILE_SIZE)
	else:
		for si in 4:
			_spawn_cube(tx, ty, si, td.cubes[si], MD.TILE_SIZE * 0.5)

func _spawn_cube(tx: int, ty: int, si: int, cube: MD.CubeData, cube_size: float) -> void:
	var key := _cube_key(tx, ty, si)
	var mesh := MB.build_cube(cube, cube_size)

	var mi := MeshInstance3D.new()
	mi.name = key
	mi.mesh = mesh
	mi.position = _cube_world_pos(tx, ty, si, cube_size)
	mi.set_meta("tx", tx); mi.set_meta("ty", ty); mi.set_meta("si", si)

	var body   := StaticBody3D.new()
	body.collision_layer = 1; body.collision_mask = 0
	var cshape := CollisionShape3D.new()
	var shape  := BoxShape3D.new()
	var top_h  := cube.top_max()
	var by     := cube.base_y
	shape.size = Vector3(cube_size, top_h - by, cube_size)
	cshape.position = Vector3(0, by + (top_h - by) * 0.5, 0)
	cshape.shape = shape
	body.add_child(cshape)
	mi.add_child(body)

	_cube_root.add_child(mi)
	_cube_nodes[key] = {"mi": mi, "body": body}

static func _cube_world_pos(tx: int, ty: int, si: int, cube_size: float) -> Vector3:
	var TS := MD.TILE_SIZE
	var base_x := float(tx) * TS
	var base_z := float(ty) * TS
	if si < 0 or cube_size >= TS:
		return Vector3(base_x, 0.0, base_z)
	var off := MD.SUB_CENTER[si]
	return Vector3(base_x + off.x * TS, 0.0, base_z + off.y * TS)

static func _cube_key(tx: int, ty: int, si: int) -> String:
	return "%d,%d,%d" % [tx, ty, si]

func rebuild_cube(tx: int, ty: int, si: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null: return
	var cube_size := MD.TILE_SIZE if not td.subdivided else MD.TILE_SIZE * 0.5
	var cube := td.cubes[0 if si < 0 else si]
	var key := _cube_key(tx, ty, si)
	if _cube_nodes.has(key):
		var mi : MeshInstance3D = _cube_nodes[key]["mi"]
		mi.mesh = MB.build_cube(cube, cube_size)
		# Update collision shape too
		var body : StaticBody3D = _cube_nodes[key]["body"]
		for ch in body.get_children(): ch.queue_free()
		var cshape := CollisionShape3D.new()
		var shape  := BoxShape3D.new()
		var top_h := cube.top_max(); var by := cube.base_y
		shape.size = Vector3(cube_size, top_h - by, cube_size)
		cshape.position = Vector3(0, by + (top_h - by) * 0.5, 0)
		cshape.shape = shape
		body.add_child(cshape)
	else:
		_spawn_cube(tx, ty, si, cube, cube_size)

# ══════════════════════════════════════════════════════════════════════════════
# CAMERA
# ══════════════════════════════════════════════════════════════════════════════
func _center_camera_on_map() -> void:
	var cx := (map_data.grid_width  - 1) * MD.TILE_SIZE * 0.5
	var cz := (map_data.grid_height - 1) * MD.TILE_SIZE * 0.5
	_cam_rig.position = Vector3(cx, 0.0, cz)
	_cam_distance  = maxf(8.0, maxf(map_data.grid_width, map_data.grid_height) * 1.2)
	_update_camera()

func _update_camera() -> void:
	var az_rad := deg_to_rad(_cam_azimuth)
	var el_rad := deg_to_rad(_cam_elevation)
	var d      := _cam_distance
	_camera.position = Vector3(
		sin(az_rad) * cos(el_rad) * d,
		sin(el_rad) * d,
		cos(az_rad) * cos(el_rad) * d)
	_camera.look_at(_cam_rig.global_position, Vector3.UP)

# ══════════════════════════════════════════════════════════════════════════════
# INPUT (forwarded from SubViewportContainer)
# ══════════════════════════════════════════════════════════════════════════════
func handle_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)

func _on_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if event.shift_pressed:
				_is_panning = true
			else:
				_is_orbiting = true
			_last_mouse = event.position
		else:
			_is_orbiting = false; _is_panning = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_cam_distance = maxf(2.0, _cam_distance - 1.0); _update_camera()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_cam_distance = minf(60.0, _cam_distance + 1.0); _update_camera()

	elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_do_tool_click(event.position)

func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _is_orbiting:
		_cam_azimuth  += event.relative.x * 0.4
		_cam_elevation = clampf(_cam_elevation - event.relative.y * 0.3, 5.0, 89.0)
		_update_camera()
	elif _is_panning:
		var right := _camera.global_transform.basis.x
		var up    := Vector3(0, 1, 0)
		_cam_rig.position -= right * event.relative.x * 0.02 * (_cam_distance / 12.0)
		_cam_rig.position += up    * event.relative.y * 0.02 * (_cam_distance / 12.0)
	else:
		_do_tool_hover(event.position)

# ══════════════════════════════════════════════════════════════════════════════
# RAYCAST
# ══════════════════════════════════════════════════════════════════════════════
func _raycast(mouse_pos: Vector2) -> Dictionary:
	if _camera == null:
		return {}

	var world := _sub_viewport.get_world_3d()
	if world == null:
		return {}   # viewport pas encore prêt

	var space := world.get_direct_space_state()
	if space == null:
		return {}

	var from := _camera.project_ray_origin(mouse_pos)
	var dir  := _camera.project_ray_normal(mouse_pos)
	var to   := from + dir * 500.0

	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = 1
	return space.intersect_ray(params)


func _hit_to_cube_info(hit: Dictionary) -> Dictionary:
	if hit.is_empty(): return {}
	var collider = hit.get("collider")
	if collider == null: return {}
	var mi = collider.get_parent()
	if not (mi is MeshInstance3D): return {}
	if not mi.has_meta("tx"): return {}
	return {
		"tx"      : mi.get_meta("tx"),
		"ty"      : mi.get_meta("ty"),
		"si"      : mi.get_meta("si"),
		"pos"     : hit.get("position", Vector3.ZERO),
		"normal"  : hit.get("normal",   Vector3.UP),
		"mi"      : mi,
	}

func _hit_face_idx(normal: Vector3) -> int:
	var ax: float = abs(normal.x)
	var ay: float = abs(normal.y)
	var az: float = abs(normal.z)
	if ay >= ax and ay >= az:
		return MD.FACE_TOP if normal.y > 0 else MD.FACE_BOTTOM
	if ax >= az:
		return MD.FACE_EAST if normal.x > 0 else MD.FACE_WEST
	return MD.FACE_SOUTH if normal.z > 0 else MD.FACE_NORTH

## Returns the nearest corner of a cube to a 3D hit position.
func _nearest_corner(tx: int, ty: int, si: int, hit_pos: Vector3) -> int:
	var best_ci := 0; var best_d := INF
	for ci in 4:
		var p := map_data.get_corner_world_xz(tx, ty, si, ci)
		var cube := map_data.get_cube(tx, ty, si)
		var y := cube.corners[ci] if cube else 0.5
		var wp := Vector3(p.x, y, p.y)
		var d  := hit_pos.distance_squared_to(wp)
		if d < best_d: best_d = d; best_ci = ci
	return best_ci

## Finds the nearest corner GRID INTERSECTION (shared by up to 4 cubes)
## to a hit position. Returns world XZ as Vector2.
func _nearest_grid_corner_xz(hit_pos: Vector3) -> Vector2:
	var TS := MD.TILE_SIZE
	# Grid corners are at multiples of TS/2 for full tiles.
	# We snap to nearest multiple of TS/2.
	var snx := roundf(hit_pos.x / (TS * 0.5)) * (TS * 0.5)
	var snz := roundf(hit_pos.z / (TS * 0.5)) * (TS * 0.5)
	return Vector2(snx, snz)

# ══════════════════════════════════════════════════════════════════════════════
# TOOL HOVER
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_hover(mouse_pos: Vector2) -> void:
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	_clear_hover_visuals()

	if info.is_empty(): return
	var tx: int = info["tx"]
	var ty: int = info["ty"]
	var si: int = info["si"]
	var hit_pos : Vector3 = info["pos"]; var normal : Vector3 = info["normal"]

	match current_tool:
		Tool.SHARED_CORNER:
			var gxz := _nearest_grid_corner_xz(hit_pos)
			var shared := map_data.get_shared_corners(gxz.x, gxz.y)
			_show_corner_spheres(shared)
			corner_hovered.emit(shared)

		Tool.SINGLE_CORNER:
			var ci := _nearest_corner(tx, ty, si, hit_pos)
			var single := [{"tx":tx,"ty":ty,"si":si,"ci":ci}]
			_show_corner_spheres(single)
			corner_hovered.emit(single)

		Tool.FACE_HEIGHT:
			var fi := _hit_face_idx(normal)
			_show_face_highlight(tx, ty, si, fi, MB.hover_material())
			cube_hovered.emit(tx, ty, si)

		Tool.TEXTURE:
			var fi := _hit_face_idx(normal)
			_show_face_highlight(tx, ty, si, fi, MB.hover_material())
			cube_hovered.emit(tx, ty, si)

func _show_corner_spheres(corners: Array) -> void:
	for cr in corners:
		var p := map_data.get_corner_world_xz(cr["tx"], cr["ty"], cr["si"], cr["ci"])
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		var y    := cube.corners[cr["ci"]] + 0.04 if cube else 0.5
		var mi   := MeshInstance3D.new()
		mi.position = Vector3(p.x, y, p.y)
		var mat  := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0.9, 0, 1)
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.mesh = SphereMesh.new()
		(mi.mesh as SphereMesh).radius = 0.07; (mi.mesh as SphereMesh).height = 0.14
		mi.set_surface_override_material(0, mat)
		_sel_root.add_child(mi)
		_hover_corner_spheres.append(mi)

func _show_face_highlight(tx: int, ty: int, si: int, fi: int, mat: Material) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null: return
	var td := map_data.get_tile(tx, ty)
	var cs := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var hi_mesh := MB.build_cube(cube, cs * 1.01)  ## slightly larger
	var mi := MeshInstance3D.new()
	mi.position = _cube_world_pos(tx, ty, si, cs)
	mi.mesh = hi_mesh
	for s in 6:
		mi.set_surface_override_material(s, null)
	mi.set_surface_override_material(fi, mat)
	_sel_root.add_child(mi)
	_hover_face_plane = mi

func _clear_hover_visuals() -> void:
	for s in _hover_corner_spheres: if is_instance_valid(s): s.queue_free()
	_hover_corner_spheres.clear()
	if _hover_face_plane != null and is_instance_valid(_hover_face_plane):
		_hover_face_plane.queue_free()
		_hover_face_plane = null

# ══════════════════════════════════════════════════════════════════════════════
# TOOL CLICK
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_click(mouse_pos: Vector2) -> void:
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	if info.is_empty(): return
	var tx: int = info["tx"]
	var ty: int = info["ty"]
	var si: int = info["si"]
	var hit_pos : Vector3 = info["pos"]; var normal : Vector3 = info["normal"]

	match current_tool:
		Tool.SHARED_CORNER:
			var gxz := _nearest_grid_corner_xz(hit_pos)
			var shared := map_data.get_shared_corners(gxz.x, gxz.y)
			selected_corners = shared
			selected_faces.clear()
			_refresh_selection_overlay()
			selection_changed.emit()

		Tool.SINGLE_CORNER:
			var ci := _nearest_corner(tx, ty, si, hit_pos)
			selected_corners = [{"tx":tx,"ty":ty,"si":si,"ci":ci}]
			selected_faces.clear()
			_refresh_selection_overlay()
			selection_changed.emit()

		Tool.FACE_HEIGHT:
			var fi := _hit_face_idx(normal)
			var ref := {"tx":tx,"ty":ty,"si":si,"face_idx":fi}
			# Toggle in selection
			var found := false
			for i in selected_faces.size():
				var sf: Dictionary = selected_faces[i]
				if sf["tx"]==tx and sf["ty"]==ty and sf["si"]==si and sf["face_idx"]==fi:
					selected_faces.remove_at(i); found = true; break
			if not found: selected_faces.append(ref)
			selected_corners.clear()
			_refresh_selection_overlay()
			selection_changed.emit()
			cube_clicked.emit(tx, ty, si, fi)

		Tool.TEXTURE:
			var fi := _hit_face_idx(normal)
			if pending_texture != null:
				var cube := map_data.get_cube(tx, ty, si)
				if cube:
					cube.face_configs[fi] = pending_texture.dup()
					rebuild_cube(tx, ty, si)
			cube_clicked.emit(tx, ty, si, fi)

# ══════════════════════════════════════════════════════════════════════════════
# HEIGHT ADJUSTMENT
# ══════════════════════════════════════════════════════════════════════════════
func adjust_height(delta: float) -> void:
	if not selected_corners.is_empty():
		_adjust_corner_heights(delta)
	elif not selected_faces.is_empty():
		_adjust_face_heights(delta)

func _adjust_corner_heights(delta: float) -> void:
	for cr in selected_corners:
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		if cube == null: continue
		var ci : int = cr["ci"]
		cube.corners[ci] = clampf(cube.corners[ci] + delta, MD.MIN_H, MD.MAX_H)
	_rebuild_affected_tiles_from_corners()
	_refresh_selection_overlay()

func _adjust_face_heights(delta: float) -> void:
	for sf_any in selected_faces:
		var sf := sf_any as Dictionary
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube == null: continue
		var cis := MD.face_top_corners(sf["face_idx"])
		for ci in cis:
			cube.corners[ci] = clampf(cube.corners[ci] + delta, MD.MIN_H, MD.MAX_H)
	_rebuild_affected_tiles_from_faces()
	_refresh_selection_overlay()


func _rebuild_affected_tiles_from_corners() -> void:
	var done := {}
	for cr in selected_corners:
		var k := "%d,%d" % [cr["tx"], cr["ty"]]
		if not done.has(k):
			done[k] = true
			_rebuild_tile(cr["tx"], cr["ty"])

func _rebuild_affected_tiles_from_faces() -> void:
	var done := {}
	for sf_any in selected_faces:
		var sf := sf_any as Dictionary
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k):
			done[k] = true
			_rebuild_tile(sf["tx"], sf["ty"])


# ══════════════════════════════════════════════════════════════════════════════
# SELECTION OVERLAY
# ══════════════════════════════════════════════════════════════════════════════
func _clear_selection_nodes() -> void:
	for ch in _sel_root.get_children(): ch.queue_free()
	_hover_corner_spheres.clear()
	_hover_face_plane = null

func _refresh_selection_overlay() -> void:
	_clear_selection_nodes()
	var sel_mat := MB.selection_material()

	# Draw selected corners as blue spheres
	for cr in selected_corners:
		var p  := map_data.get_corner_world_xz(cr["tx"], cr["ty"], cr["si"], cr["ci"])
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		var y  := (cube.corners[cr["ci"]] + 0.05) if cube else 0.5
		var mi := MeshInstance3D.new()
		mi.position = Vector3(p.x, y, p.y)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.6, 1.0)
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.mesh = SphereMesh.new()
		(mi.mesh as SphereMesh).radius = 0.09; (mi.mesh as SphereMesh).height = 0.18
		mi.set_surface_override_material(0, mat)
		_sel_root.add_child(mi)

	# Draw selected faces
	for sf in selected_faces:
		var td := map_data.get_tile(sf["tx"], sf["ty"])
		if td == null: continue
		var cs := MD.TILE_SIZE if not td.subdivided else MD.TILE_SIZE * 0.5
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube == null: continue
		var hi_mesh := MB.build_cube(cube, cs * 1.01)
		var mi      := MeshInstance3D.new()
		mi.position = _cube_world_pos(sf["tx"], sf["ty"], sf["si"], cs)
		mi.mesh     = hi_mesh
		for s in 6: mi.set_surface_override_material(s, null)
		mi.set_surface_override_material(sf["face_idx"], sel_mat)
		_sel_root.add_child(mi)

## Clear current selection.
func clear_selection() -> void:
	selected_corners.clear(); selected_faces.clear()
	_clear_selection_nodes(); selection_changed.emit()

# ══════════════════════════════════════════════════════════════════════════════
# TILE SUBDIVISION / MERGE
# ══════════════════════════════════════════════════════════════════════════════
func subdivide_tile(tx: int, ty: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null or td.subdivided: return
	td.subdivide()
	_rebuild_tile(tx, ty)
	clear_selection()

func merge_tile(tx: int, ty: int) -> void:
	var td := map_data.get_tile(tx, ty)
	if td == null or not td.subdivided: return
	td.merge()
	_rebuild_tile(tx, ty)
	clear_selection()

# ══════════════════════════════════════════════════════════════════════════════
# TEST MODE (TerrainModule3D view)
# ══════════════════════════════════════════════════════════════════════════════
func toggle_test_mode(enabled: bool) -> void:
	_cube_root.visible = not enabled
	# In test mode we'd instantiate TerrainModule3D populated from map_data.
	# For now just hide editor geometry to show what a clean export looks like.
	# Full TerrainModule3D integration: call export_to_terrain_module().

func export_to_json_map() -> Dictionary:
	var jm : Dictionary = {
		"width"  : map_data.grid_width,
		"height" : map_data.grid_height,
		"tiles"  : []
	}
	for ty in map_data.grid_height:
		var row : Array = []
		for tx in map_data.grid_width:
			var td := map_data.get_tile(tx, ty)
			var cube := td.cubes[0]
			row.append({
				"type"    : 0,
				"height"  : int(cube.top_max() / MD.HEIGHT_STEP),
				"walkable": true,
			})
		jm["tiles"].append(row)
	return jm

# ══════════════════════════════════════════════════════════════════════════════
# ACCESSORS
# ══════════════════════════════════════════════════════════════════════════════
func get_sub_viewport() -> SubViewport:
	return _sub_viewport

func set_tool(t: int) -> void:
	current_tool = t
	clear_selection()

func set_pending_texture(fc: MD.FaceConfig) -> void:
	pending_texture = fc
