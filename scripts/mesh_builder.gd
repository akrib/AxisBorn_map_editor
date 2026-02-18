## mesh_builder.gd
## Builds ArrayMesh for a single CubeData.
## Each face is a separate surface → one material per face.
## FIX : AtlasTexture ne fonctionne pas correctement en 3D (Godot 4).
##       On utilise la texture complète + uv1_offset / uv1_scale pour isoler la cellule.
class_name MeshBuilder
extends RefCounted

## Material cache: "path|col|row|cs|uvs" → StandardMaterial3D
static var _mat_cache     : Dictionary = {}
static var _default_top   : StandardMaterial3D = null
static var _default_side  : StandardMaterial3D = null
static var _hover_mat     : StandardMaterial3D = null
static var _sel_mat       : StandardMaterial3D = null

static func clear_cache() -> void:
	_mat_cache.clear()
	_default_top  = null
	_default_side = null

## Build an ArrayMesh for a CubeData.
## cube_size = TILE_SIZE for full tiles, TILE_SIZE/2 for sub-tiles.
static func build_cube(
	cube     : MapData.CubeData,
	cube_size: float,
	tile_type: int = 0
) -> ArrayMesh:
	var hx := cube_size * 0.5
	var hz := cube_size * 0.5
	var by := cube.base_y

	# Top corners (absolute Y)
	var tnw := Vector3(-hx, cube.corners[MapData.CORNER_NW], -hz)
	var tne := Vector3( hx, cube.corners[MapData.CORNER_NE], -hz)
	var tse := Vector3( hx, cube.corners[MapData.CORNER_SE],  hz)
	var tsw := Vector3(-hx, cube.corners[MapData.CORNER_SW],  hz)
	# Base corners
	var bnw := Vector3(-hx, by, -hz)
	var bne := Vector3( hx, by, -hz)
	var bse := Vector3( hx, by,  hz)
	var bsw := Vector3(-hx, by,  hz)

	var face_quads := [
		# TOP
		[tnw, tne, tse, tsw,  Vector3(0, 1, 0),   MapData.FACE_TOP],
		# NORTH Z-
		[tne, tnw, bnw, bne,  Vector3(0, 0,-1),   MapData.FACE_NORTH],
		# SOUTH Z+
		[tsw, tse, bse, bsw,  Vector3(0, 0, 1),   MapData.FACE_SOUTH],
		# WEST X-
		[tnw, tsw, bsw, bnw,  Vector3(-1, 0, 0),  MapData.FACE_WEST],
		# EAST X+
		[tse, tne, bne, bse,  Vector3( 1, 0, 0),  MapData.FACE_EAST],
		# BOTTOM
		[bnw, bne, bse, bsw,  Vector3(0,-1, 0),   MapData.FACE_BOTTOM],
	]

	var mesh := ArrayMesh.new()
	for fq in face_quads:
		var v0 : Vector3 = fq[0]; var v1 : Vector3 = fq[1]
		var v2 : Vector3 = fq[2]; var v3 : Vector3 = fq[3]
		var n  : Vector3 = fq[4]; var fi  : int     = fq[5]
		var fc : MapData.FaceConfig = cube.face_configs[fi]

		# Smooth normals on top face if corners differ
		var n0 := n; var n1 := n; var n2 := n; var n3 := n
		if fi == MapData.FACE_TOP and not _corners_flat(cube.corners):
			n0 = _smooth_n(v0, v1, v3)
			n1 = _smooth_n(v1, v2, v0)
			n2 = _smooth_n(v2, v3, v1)
			n3 = _smooth_n(v3, v0, v2)

		var arr := []; arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([v0, v1, v2, v3])
		arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([n0, n1, n2, n3])
		# UVs toujours 0→1 ; c'est uv1_offset/uv1_scale du matériau qui isole la cellule
		arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
			Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,1)])
		arr[Mesh.ARRAY_INDEX]  = PackedInt32Array([0, 1, 2,  0, 2, 3])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(fi, _get_mat(fc, fi == MapData.FACE_TOP))

	return mesh

static func _corners_flat(corners: Array) -> bool:
	var h0 : float = corners[0]
	return corners[1] == h0 and corners[2] == h0 and corners[3] == h0

static func _smooth_n(v: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var n := (a - v).cross(b - v).normalized()
	return n if n.y >= 0.0 else -n

# ── Matériau ──────────────────────────────────────────────────────────────────
# On NE PAS utiliser AtlasTexture en 3D : Godot 4 ne remaphe pas les UV UV→région.
# À la place : texture complète + uv1_offset/uv1_scale calculés depuis la cellule.
#
#   uv1_offset = (col * cell_size / tex_w ,  row * cell_size / tex_h)
#   uv1_scale  = (cell_size / tex_w * uv_scale ,  cell_size / tex_h * uv_scale)
#
# Avec des UVs mesh de 0 à 1 :
#   UV final = UV_mesh * uv1_scale + uv1_offset
#   → à UV=0 : début de la cellule  ✓
#   → à UV=1 : fin de la cellule (×uv_scale pour la répétition)  ✓
static func _get_mat(fc: MapData.FaceConfig, is_top: bool) -> StandardMaterial3D:
	if fc.has_texture():
		var key := "%s|%d|%d|%d|%.3f" % [
			fc.atlas_path, fc.atlas_col, fc.atlas_row, fc.cell_size, fc.uv_scale]
		if _mat_cache.has(key):
			return _mat_cache[key]

		var atlas_tex := load(fc.atlas_path) as Texture2D
		if atlas_tex != null:
			var tw  := float(atlas_tex.get_width())
			var th  := float(atlas_tex.get_height())
			var cs  := float(fc.cell_size)

			# Offset = coin haut-gauche de la cellule en coordonnées 0-1
			var u_off := (float(fc.atlas_col) * cs) / tw
			var v_off := (float(fc.atlas_row) * cs) / th
			# Scale = taille d'une cellule en coordonnées 0-1, multipliée par uv_scale
			var u_scl := (cs / tw) * fc.uv_scale
			var v_scl := (cs / th) * fc.uv_scale

			var mat := StandardMaterial3D.new()
			mat.albedo_texture = atlas_tex
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mat.uv1_offset     = Vector3(u_off, v_off, 0.0)
			mat.uv1_scale      = Vector3(u_scl, v_scl, 1.0)
			mat.cull_mode      = BaseMaterial3D.CULL_DISABLED
			mat.roughness      = 0.9
			_mat_cache[key]    = mat
			return mat

	return _default_mat(is_top)

static func _default_mat(is_top: bool) -> StandardMaterial3D:
	if is_top:
		if _default_top == null:
			_default_top = StandardMaterial3D.new()
			_default_top.albedo_color = Color(0.38, 0.60, 0.25)
			_default_top.roughness    = 0.9
			_default_top.cull_mode    = BaseMaterial3D.CULL_DISABLED
		return _default_top
	else:
		if _default_side == null:
			_default_side = StandardMaterial3D.new()
			_default_side.albedo_color = Color(0.28, 0.22, 0.16)
			_default_side.roughness    = 0.95
			_default_side.cull_mode    = BaseMaterial3D.CULL_DISABLED
		return _default_side

static func hover_material() -> StandardMaterial3D:
	if _hover_mat == null:
		_hover_mat = StandardMaterial3D.new()
		_hover_mat.albedo_color  = Color(1, 1, 0.3, 0.35)
		_hover_mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hover_mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
		_hover_mat.no_depth_test = false
	return _hover_mat

static func selection_material() -> StandardMaterial3D:
	if _sel_mat == null:
		_sel_mat = StandardMaterial3D.new()
		_sel_mat.albedo_color  = Color(0.2, 0.7, 1.0, 0.5)
		_sel_mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
		_sel_mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	return _sel_mat

static func build_sphere(radius: float, color: Color) -> Mesh:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	var sm := SphereMesh.new()
	sm.radius = radius; sm.height = radius * 2.0
	sm.radial_segments = 8; sm.rings = 4
	return sm
