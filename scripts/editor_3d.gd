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
signal corner_hovered(corners: Array)
signal selection_changed
signal status_message(msg: String)   ## NEW: pour afficher des messages dans l'UI

# ══════════════════════════════════════════════════════════════════════════════
# TOOL ENUM
# ══════════════════════════════════════════════════════════════════════════════
enum Tool {
	SHARED_CORNER,
	FACE_HEIGHT,
	TEXTURE,
	SINGLE_CORNER,
}

# ══════════════════════════════════════════════════════════════════════════════
# STATE
# ══════════════════════════════════════════════════════════════════════════════
var map_data       : MD
var current_tool   : int = Tool.SHARED_CORNER
var selected_faces   : Array = []
var selected_corners : Array = []

var pending_texture : MD.FaceConfig = null

# 3D nodes
var _sub_viewport  : SubViewport
var _camera        : Camera3D
var _cam_rig       : Node3D
var _map_root      : Node3D
var _cube_root     : Node3D
var _sel_root      : Node3D
var _grid_root     : Node3D   ## NEW: grille de repère

## cube_key → {"mi": MeshInstance3D, "body": StaticBody3D}
var _cube_nodes: Dictionary = {}

## Camera orbit state
var _cam_distance  : float = 12.0
var _cam_elevation : float = 40.0
var _cam_azimuth   : float = 45.0
var _cam_pan       : Vector2 = Vector2.ZERO
var _is_orbiting   : bool = false
var _is_panning    : bool = false
var _last_mouse    : Vector2 = Vector2.ZERO

## FIX: flag pour s'assurer que la physique est prête
var _physics_ready : bool = false

## Hover indicators
var _hover_corner_spheres : Array = []
var _hover_face_plane     : MeshInstance3D = null

## NEW: Tile highlight overlay (cube entier surligné)
var _hover_tile_outline : MeshInstance3D = null

# ══════════════════════════════════════════════════════════════════════════════
# INIT
# ══════════════════════════════════════════════════════════════════════════════
func _init(md: MD) -> void:
	map_data = md

func _ready() -> void:
	_build_viewport()
	## FIX: attendre 2 frames pour que la physique soit prête
	await get_tree().process_frame
	await get_tree().process_frame
	_physics_ready = true
	_update_camera()

func _build_viewport() -> void:
	_sub_viewport = SubViewport.new()
	_sub_viewport.size = Vector2i(1, 1)
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.physics_object_picking  = true

	# Environment
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode       = Environment.BG_COLOR
	e.background_color      = Color(0.12, 0.12, 0.15)
	e.ambient_light_color   = Color(0.6, 0.6, 0.65)
	e.ambient_light_energy  = 0.7
	env.environment = e
	_sub_viewport.add_child(env)

	# Light
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy     = 1.3
	_sub_viewport.add_child(sun)

	## NEW: lumière de remplissage douce (évite les zones trop sombres)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -150, 0)
	fill.light_energy     = 0.4
	fill.shadow_enabled   = false
	_sub_viewport.add_child(fill)

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
	_grid_root = Node3D.new(); _grid_root.name = "Grid"   ## NEW
	_sub_viewport.add_child(_map_root)
	_map_root.add_child(_cube_root)
	_map_root.add_child(_sel_root)
	_map_root.add_child(_grid_root)


## Called by EditorUI once the map is initialized.
func build_all() -> void:
	_clear_cube_nodes()
	for tx in map_data.grid_width:
		for ty in map_data.grid_height:
			_rebuild_tile(tx, ty)
	_build_grid_overlay()   ## NEW
	_center_camera_on_map()

func _clear_cube_nodes() -> void:
	for child in _cube_root.get_children():
		child.queue_free()
	_cube_nodes.clear()
	selected_corners.clear()
	selected_faces.clear()
	_clear_selection_nodes()

# ══════════════════════════════════════════════════════════════════════════════
# NEW: GRILLE DE REPÈRE
# ══════════════════════════════════════════════════════════════════════════════
func _build_grid_overlay() -> void:
	for ch in _grid_root.get_children(): ch.queue_free()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.5, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false

	var TS := MD.TILE_SIZE
	var W  := map_data.grid_width
	var H  := map_data.grid_height

	## Lignes X
	for ix in (W + 1):
		var x := float(ix) * TS - TS * 0.5
		_add_grid_line(Vector3(x, 0.01, -TS * 0.5),
					   Vector3(x, 0.01, float(H) * TS - TS * 0.5), mat)

	## Lignes Z
	for iz in (H + 1):
		var z := float(iz) * TS - TS * 0.5
		_add_grid_line(Vector3(-TS * 0.5, 0.01, z),
					   Vector3(float(W) * TS - TS * 0.5, 0.01, z), mat)

func _add_grid_line(a: Vector3, b: Vector3, mat: Material) -> void:
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([a, b])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	_grid_root.add_child(mi)

func toggle_grid(visible: bool) -> void:
	_grid_root.visible = visible

# ══════════════════════════════════════════════════════════════════════════════
# TILE / CUBE BUILDING
# ══════════════════════════════════════════════════════════════════════════════
func _rebuild_tile(tx: int, ty: int) -> void:
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

	## FIX: taille minimum pour éviter les collisions dégénérées
	var height := maxf(top_h - by, 0.1)
	shape.size = Vector3(cube_size * 0.98, height, cube_size * 0.98)
	cshape.position = Vector3(0, by + height * 0.5, 0)
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
		var body : StaticBody3D = _cube_nodes[key]["body"]
		for ch in body.get_children(): ch.queue_free()
		var cshape := CollisionShape3D.new()
		var shape  := BoxShape3D.new()
		var top_h := cube.top_max(); var by := cube.base_y
		var height := maxf(top_h - by, 0.1)
		shape.size = Vector3(cube_size * 0.98, height, cube_size * 0.98)
		cshape.position = Vector3(0, by + height * 0.5, 0)
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
	_cam_distance  = maxf(8.0, maxf(map_data.grid_width, map_data.grid_height) * 1.5)
	_cam_elevation = 45.0
	_cam_azimuth   = 45.0
	_update_camera()

func _update_camera() -> void:
	if _camera == null: return
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
	## FIX: clic DROIT = orbiter (plus intuitif que le clic milieu)
	## Clic MILIEU = aussi orbiter (rétro-compatible)
	if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if event.shift_pressed or event.button_index == MOUSE_BUTTON_MIDDLE and event.shift_pressed:
				_is_panning = true
			elif event.alt_pressed and event.button_index == MOUSE_BUTTON_RIGHT:
				_is_panning = true
			else:
				_is_orbiting = true
			_last_mouse = event.position
		else:
			_is_orbiting = false
			_is_panning  = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_cam_distance = maxf(2.0, _cam_distance * 0.9); _update_camera()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_cam_distance = minf(80.0, _cam_distance * 1.1); _update_camera()

	elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		## FIX: ne pas faire le pick si on est en orbite/pan
		if not _is_orbiting and not _is_panning:
			_do_tool_click(event.position)

func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _is_orbiting:
		_cam_azimuth  += event.relative.x * 0.5
		_cam_elevation = clampf(_cam_elevation - event.relative.y * 0.4, 5.0, 89.0)
		_update_camera()
	elif _is_panning:
		var right := _camera.global_transform.basis.x
		var up    := Vector3(0, 1, 0)
		_cam_rig.position -= right * event.relative.x * 0.02 * (_cam_distance / 12.0)
		_cam_rig.position += up    * event.relative.y * 0.02 * (_cam_distance / 12.0)
	else:
		_do_tool_hover(event.position)

## NEW: reset de la caméra vers la position centrée
func reset_camera() -> void:
	_center_camera_on_map()

# ══════════════════════════════════════════════════════════════════════════════
# RAYCAST
# ══════════════════════════════════════════════════════════════════════════════
func _raycast(mouse_pos: Vector2) -> Dictionary:
	## FIX: vérifier que tout est prêt
	if not _physics_ready: return {}
	if _camera == null:    return {}

	var world := _sub_viewport.get_world_3d()
	if world == null: return {}

	var space := world.get_direct_space_state()
	if space == null: return {}

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
	## FIX: la StaticBody3D peut être directement le collider
	## On cherche le MeshInstance3D parent
	var mi = collider.get_parent()
	if not (mi is MeshInstance3D):
		mi = collider  ## fallback
	if not (mi is MeshInstance3D): return {}
	if not mi.has_meta("tx"): return {}
	return {
		"tx"     : mi.get_meta("tx"),
		"ty"     : mi.get_meta("ty"),
		"si"     : mi.get_meta("si"),
		"pos"    : hit.get("position", Vector3.ZERO),
		"normal" : hit.get("normal",   Vector3.UP),
		"mi"     : mi,
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

func _nearest_grid_corner_xz(hit_pos: Vector3) -> Vector2:
	var TS := MD.TILE_SIZE
	var snx := roundf(hit_pos.x / (TS * 0.5)) * (TS * 0.5)
	var snz := roundf(hit_pos.z / (TS * 0.5)) * (TS * 0.5)
	return Vector2(snx, snz)

# ══════════════════════════════════════════════════════════════════════════════
# TOOL HOVER
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_hover(mouse_pos: Vector2) -> void:
	if not _physics_ready: return
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	_clear_hover_visuals()

	if info.is_empty(): return
	var tx: int = info["tx"]
	var ty: int = info["ty"]
	var si: int = info["si"]
	var hit_pos : Vector3 = info["pos"]
	var normal  : Vector3 = info["normal"]

	## NEW: toujours afficher le contour de la tuile survolée
	_show_tile_outline(tx, ty, si)

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

## NEW: contour filaire de la tuile survolée
func _show_tile_outline(tx: int, ty: int, si: int) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null: return
	var td := map_data.get_tile(tx, ty)
	var cs := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var pos := _cube_world_pos(tx, ty, si, cs)

	var hx := cs * 0.5 + 0.03
	var hz := hx
	var yt := cube.top_max() + 0.03
	var yb := cube.base_y   - 0.01

	## 8 arêtes du dessus + 4 verticales
	var lines := PackedVector3Array([
		## Top face
		Vector3(-hx, yt, -hz), Vector3( hx, yt, -hz),
		Vector3( hx, yt, -hz), Vector3( hx, yt,  hz),
		Vector3( hx, yt,  hz), Vector3(-hx, yt,  hz),
		Vector3(-hx, yt,  hz), Vector3(-hx, yt, -hz),
		## Verticals
		Vector3(-hx, yb, -hz), Vector3(-hx, yt, -hz),
		Vector3( hx, yb, -hz), Vector3( hx, yt, -hz),
		Vector3( hx, yb,  hz), Vector3( hx, yt,  hz),
		Vector3(-hx, yb,  hz), Vector3(-hx, yt,  hz),
	])

	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)

	var mat := StandardMaterial3D.new()
	mat.albedo_color  = Color(1.0, 0.85, 0.1, 1.0)
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false

	var mi := MeshInstance3D.new()
	mi.position = pos
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	_sel_root.add_child(mi)
	_hover_tile_outline = mi

func _show_corner_spheres(corners: Array) -> void:
	for cr in corners:
		var p := map_data.get_corner_world_xz(cr["tx"], cr["ty"], cr["si"], cr["ci"])
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		var y    := cube.corners[cr["ci"]] + 0.06 if cube else 0.5
		var mi   := MeshInstance3D.new()
		mi.position = Vector3(p.x, y, p.y)
		var mat  := StandardMaterial3D.new()
		mat.albedo_color  = Color(1, 0.9, 0, 1)
		mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
		mi.mesh = SphereMesh.new()
		(mi.mesh as SphereMesh).radius = 0.10
		(mi.mesh as SphereMesh).height = 0.20
		mi.set_surface_override_material(0, mat)
		_sel_root.add_child(mi)
		_hover_corner_spheres.append(mi)

func _show_face_highlight(tx: int, ty: int, si: int, fi: int, mat: Material) -> void:
	var cube := map_data.get_cube(tx, ty, si)
	if cube == null: return
	var td := map_data.get_tile(tx, ty)
	var cs := MD.TILE_SIZE if (not td.subdivided) else MD.TILE_SIZE * 0.5
	var hi_mesh := MB.build_cube(cube, cs * 1.01)
	var mi := MeshInstance3D.new()
	mi.position = _cube_world_pos(tx, ty, si, cs)
	mi.mesh = hi_mesh
	## FIX: n'afficher que la face concernée, les autres en transparent invisible
	var invis := StandardMaterial3D.new()
	invis.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	invis.albedo_color = Color(0, 0, 0, 0)
	for s in 6:
		mi.set_surface_override_material(s, invis)
	mi.set_surface_override_material(fi, mat)
	_sel_root.add_child(mi)
	_hover_face_plane = mi

func _clear_hover_visuals() -> void:
	for s in _hover_corner_spheres:
		if is_instance_valid(s): s.queue_free()
	_hover_corner_spheres.clear()
	if _hover_face_plane != null and is_instance_valid(_hover_face_plane):
		_hover_face_plane.queue_free()
		_hover_face_plane = null
	if _hover_tile_outline != null and is_instance_valid(_hover_tile_outline):
		_hover_tile_outline.queue_free()
		_hover_tile_outline = null

# ══════════════════════════════════════════════════════════════════════════════
# TOOL CLICK
# ══════════════════════════════════════════════════════════════════════════════
func _do_tool_click(mouse_pos: Vector2) -> void:
	if not _physics_ready:
		status_message.emit("Initialisation en cours, veuillez patienter...")
		return
	var hit  := _raycast(mouse_pos)
	var info := _hit_to_cube_info(hit)
	if info.is_empty():
		## FIX: clic dans le vide = désélectionner
		clear_selection()
		return
	var tx: int = info["tx"]
	var ty: int = info["ty"]
	var si: int = info["si"]
	var hit_pos : Vector3 = info["pos"]
	var normal  : Vector3 = info["normal"]

	match current_tool:
		Tool.SHARED_CORNER:
			var gxz := _nearest_grid_corner_xz(hit_pos)
			var shared := map_data.get_shared_corners(gxz.x, gxz.y)
			selected_corners = shared
			selected_faces.clear()
			_refresh_selection_overlay()
			selection_changed.emit()
			status_message.emit("Coins sélectionnés : %d" % shared.size())

		Tool.SINGLE_CORNER:
			var ci := _nearest_corner(tx, ty, si, hit_pos)
			selected_corners = [{"tx":tx,"ty":ty,"si":si,"ci":ci}]
			selected_faces.clear()
			_refresh_selection_overlay()
			selection_changed.emit()
			status_message.emit("Coin (%d,%d) sélectionné" % [tx, ty])

		Tool.FACE_HEIGHT:
			var fi := _hit_face_idx(normal)
			var found := false
			for i in selected_faces.size():
				var sf: Dictionary = selected_faces[i]
				if sf["tx"]==tx and sf["ty"]==ty and sf["si"]==si and sf["face_idx"]==fi:
					selected_faces.remove_at(i); found = true; break
			if not found: selected_faces.append({"tx":tx,"ty":ty,"si":si,"face_idx":fi})
			selected_corners.clear()
			_refresh_selection_overlay()
			selection_changed.emit()
			cube_clicked.emit(tx, ty, si, fi)
			status_message.emit("Face sélectionnée sur tuile (%d,%d)" % [tx, ty])

		Tool.TEXTURE:
			var fi := _hit_face_idx(normal)
			if pending_texture != null:
				var cube := map_data.get_cube(tx, ty, si)
				if cube:
					cube.face_configs[fi] = pending_texture.dup()
					rebuild_cube(tx, ty, si)
					status_message.emit("Texture appliquée sur (%d,%d)" % [tx, ty])
			else:
				status_message.emit("Sélectionnez d'abord une texture dans la barre latérale")
			cube_clicked.emit(tx, ty, si, fi)

# ══════════════════════════════════════════════════════════════════════════════
# HEIGHT ADJUSTMENT
# ══════════════════════════════════════════════════════════════════════════════
func adjust_height(delta: float) -> void:
	if not selected_corners.is_empty():
		_adjust_corner_heights(delta)
	elif not selected_faces.is_empty():
		_adjust_face_heights(delta)
	else:
		status_message.emit("Sélectionnez d'abord un coin ou une face")

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
			done[k] = true; _rebuild_tile(cr["tx"], cr["ty"])

func _rebuild_affected_tiles_from_faces() -> void:
	var done := {}
	for sf_any in selected_faces:
		var sf := sf_any as Dictionary
		var k := "%d,%d" % [sf["tx"], sf["ty"]]
		if not done.has(k):
			done[k] = true; _rebuild_tile(sf["tx"], sf["ty"])

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
	var sel_mat := MB.selection_material()

	for cr in selected_corners:
		var p  := map_data.get_corner_world_xz(cr["tx"], cr["ty"], cr["si"], cr["ci"])
		var cube := map_data.get_cube(cr["tx"], cr["ty"], cr["si"])
		var y  := (cube.corners[cr["ci"]] + 0.06) if cube else 0.5
		var mi := MeshInstance3D.new()
		mi.position = Vector3(p.x, y, p.y)
		var mat := StandardMaterial3D.new()
		mat.albedo_color  = Color(0.1, 0.6, 1.0)
		mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
		mi.mesh = SphereMesh.new()
		(mi.mesh as SphereMesh).radius = 0.12
		(mi.mesh as SphereMesh).height = 0.24
		mi.set_surface_override_material(0, mat)
		_sel_root.add_child(mi)

	for sf in selected_faces:
		var td := map_data.get_tile(sf["tx"], sf["ty"])
		if td == null: continue
		var cs := MD.TILE_SIZE if not td.subdivided else MD.TILE_SIZE * 0.5
		var cube := map_data.get_cube(sf["tx"], sf["ty"], sf["si"])
		if cube == null: continue
		var hi_mesh := MB.build_cube(cube, cs * 1.015)
		var mi      := MeshInstance3D.new()
		mi.position = _cube_world_pos(sf["tx"], sf["ty"], sf["si"], cs)
		mi.mesh     = hi_mesh
		var invis := StandardMaterial3D.new()
		invis.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		invis.albedo_color = Color(0, 0, 0, 0)
		for s in 6: mi.set_surface_override_material(s, invis)
		mi.set_surface_override_material(sf["face_idx"], sel_mat)
		_sel_root.add_child(mi)

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
# TEST MODE
# ══════════════════════════════════════════════════════════════════════════════
func toggle_test_mode(enabled: bool) -> void:
	_cube_root.visible = not enabled
	_grid_root.visible = not enabled

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
