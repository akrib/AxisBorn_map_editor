## map_data.gd
## Data model for the map editor.
## A Map is a grid of TerrainTileData.
## Each TerrainTileData is either 1 CubeData (full tile) or 4 CubeData (subdivided).
## Each CubeData has 4 top corner heights + 6 FaceConfig (one per face).
class_name MapData
extends RefCounted

const TILE_SIZE   : float = 1.0
const HEIGHT_STEP : float = 0.25
const DEFAULT_H   : float = 0.5
const MIN_H       : float = 0.25
const MAX_H       : float = 8.0

## Face index constants
const FACE_TOP    := 0
const FACE_NORTH  := 1  ## Z-
const FACE_SOUTH  := 2  ## Z+
const FACE_WEST   := 3  ## X-
const FACE_EAST   := 4  ## X+
const FACE_BOTTOM := 5

## Corner index constants (top face seen from above)
## NW=0  NE=1
## SW=3  SE=2
const CORNER_NW := 0
const CORNER_NE := 1
const CORNER_SE := 2
const CORNER_SW := 3

## Sub-tile center offset from tile center (as fraction of TILE_SIZE)
## Index matches NW=0, NE=1, SE=2, SW=3
const SUB_CENTER: Array[Vector2] = [
	Vector2(-0.25, -0.25),
	Vector2( 0.25, -0.25),
	Vector2( 0.25,  0.25),
	Vector2(-0.25,  0.25),
]
const CORNER_OX := [-1,  1,  1, -1]  ## local X sign per corner
const CORNER_OZ := [-1, -1,  1,  1]  ## local Z sign per corner

# ═══════════════════════════════════════════════════════════════════════════════
# INNER CLASSES
# ═══════════════════════════════════════════════════════════════════════════════

class FaceConfig:
	var atlas_path : String = ""   ## res:// path to atlas PNG
	var atlas_col  : int    = 0
	var atlas_row  : int    = 0
	var cell_size  : int    = 32   ## pixels per cell in the atlas
	var uv_scale   : float  = 1.0  ## texture tiling factor

	func has_texture() -> bool:
		return atlas_path != ""

	func dup() -> FaceConfig:
		var c := FaceConfig.new()
		c.atlas_path = atlas_path; c.atlas_col = atlas_col
		c.atlas_row  = atlas_row;  c.cell_size  = cell_size
		c.uv_scale   = uv_scale
		return c

	func to_dict() -> Dictionary:
		return {"path": atlas_path, "col": atlas_col, "row": atlas_row,
				"cs": cell_size, "uvs": uv_scale}

	static func from_dict(d: Dictionary) -> FaceConfig:
		var c := FaceConfig.new()
		c.atlas_path = d.get("path", "")
		c.atlas_col  = d.get("col",  0)
		c.atlas_row  = d.get("row",  0)
		c.cell_size  = d.get("cs",   32)
		c.uv_scale   = d.get("uvs",  1.0)
		return c

class CubeData:
	## Top corner heights: [NW, NE, SE, SW]  absolute Y world position
	var corners: Array[float] = [0.5, 0.5, 0.5, 0.5]
	var base_y       : float = 0.0
	## Face configs: [TOP, NORTH, SOUTH, WEST, EAST, BOTTOM]
	var face_configs : Array = []

	func _init() -> void:
		face_configs.resize(6)
		for i in 6:
			face_configs[i] = FaceConfig.new()

	func top_max() -> float:
		return maxf(maxf(corners[0], corners[1]), maxf(corners[2], corners[3]))

	func dup() -> CubeData:
		var c := CubeData.new()
		c.corners = corners.duplicate()
		c.base_y  = base_y
		for i in 6:
			c.face_configs[i] = face_configs[i].dup()
		return c

	func to_dict() -> Dictionary:
		var fd: Array = []
		for fc in face_configs: fd.append(fc.to_dict())
		return {"corners": corners.duplicate(), "base_y": base_y, "faces": fd}

	static func from_dict(d: Dictionary) -> CubeData:
		var c := CubeData.new()
		c.corners = d.get("corners", [0.5, 0.5, 0.5, 0.5])
		c.base_y  = d.get("base_y", 0.0)
		var fd: Array = d.get("faces", [])
		for i in mini(fd.size(), 6):
			c.face_configs[i] = FaceConfig.from_dict(fd[i])
		return c

class TerrainTileData:
	## false → cubes[0] single cube
	## true  → cubes[0..3] = [NW, NE, SE, SW] sub-cubes
	var subdivided : bool  = false
	var cubes: Array[CubeData] = []

	func _init() -> void:
		cubes = [CubeData.new()]

	func subdivide() -> void:
		if subdivided: return
		subdivided = true
		var o  : CubeData = cubes[0]
		var h0 := o.corners[0]; var h1 := o.corners[1]
		var h2 := o.corners[2]; var h3 := o.corners[3]
		var hc := (h0 + h1 + h2 + h3) * 0.25

		var sub_nw := CubeData.new(); sub_nw.base_y = o.base_y
		sub_nw.corners = [h0, (h0+h1)*0.5, hc, (h0+h3)*0.5]
		var sub_ne := CubeData.new(); sub_ne.base_y = o.base_y
		sub_ne.corners = [(h0+h1)*0.5, h1, (h1+h2)*0.5, hc]
		var sub_se := CubeData.new(); sub_se.base_y = o.base_y
		sub_se.corners = [hc, (h1+h2)*0.5, h2, (h2+h3)*0.5]
		var sub_sw := CubeData.new(); sub_sw.base_y = o.base_y
		sub_sw.corners = [(h0+h3)*0.5, hc, (h2+h3)*0.5, h3]

		cubes = [sub_nw, sub_ne, sub_se, sub_sw]

	func merge() -> void:
		if not subdivided: return
		subdivided = false
		var c := CubeData.new()
		c.base_y  = cubes[0].base_y
		c.corners = [cubes[0].corners[0], cubes[1].corners[1],
					 cubes[2].corners[2], cubes[3].corners[3]]
		cubes = [c]

	func to_dict() -> Dictionary:
		var cd: Array = []
		for cube in cubes: cd.append(cube.to_dict())
		return {"sub": subdivided, "cubes": cd}

	static func from_dict(d: Dictionary) -> TerrainTileData:
		var t := TerrainTileData.new()
		t.subdivided = d.get("sub", false)
		var cd: Array = d.get("cubes", [])
		t.cubes.clear()
		for cb in cd: t.cubes.append(CubeData.from_dict(cb))
		if t.cubes.is_empty(): t.cubes = [CubeData.new()]
		return t

# ═══════════════════════════════════════════════════════════════════════════════
# GRID
# ═══════════════════════════════════════════════════════════════════════════════

var grid_width  : int   = 10
var grid_height : int   = 10
## tiles[x][y] : TerrainTileData
var tiles : Array = []

func init_grid(w: int, h: int) -> void:
	grid_width = w; grid_height = h
	tiles.clear()
	for _x in w:
		var col : Array = []
		for _y in h:
			col.append(TerrainTileData.new())
		tiles.append(col)

func get_tile(x: int, y: int) -> TerrainTileData:
	if not in_bounds(x, y): return null
	return tiles[x][y]

func get_cube(tx: int, ty: int, si: int) -> CubeData:
	var td := get_tile(tx, ty)
	if td == null: return null
	var idx := 0 if (si < 0 or not td.subdivided) else si
	if idx >= td.cubes.size(): return null
	return td.cubes[idx]

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < grid_width and y >= 0 and y < grid_height

# ═══════════════════════════════════════════════════════════════════════════════
# CORNER UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

## World XZ of a corner. si=-1 means full tile (subdivided flag ignored).
func get_corner_world_xz(tx: int, ty: int, si: int, ci: int) -> Vector2:
	var TS := TILE_SIZE
	var tile_cx := float(tx) * TS
	var tile_cz := float(ty) * TS
	var cube_cx : float; var cube_cz : float; var hc : float
	var td := get_tile(tx, ty)
	if td == null: return Vector2.ZERO

	if not td.subdivided or si < 0:
		cube_cx = tile_cx; cube_cz = tile_cz; hc = TS * 0.5
	else:
		hc = TS * 0.25
		cube_cx = tile_cx + SUB_CENTER[si].x * TS
		cube_cz = tile_cz + SUB_CENTER[si].y * TS

	return Vector2(cube_cx + CORNER_OX[ci] * hc, cube_cz + CORNER_OZ[ci] * hc)

## All corner refs sharing world position (wx, wz).
## Each entry: {tx, ty, si, ci}  si=-1 for full tiles.
func get_shared_corners(wx: float, wz: float) -> Array:
	var result : Array = []
	var eps    := 0.02
	for tx in grid_width:
		for ty in grid_height:
			var td := get_tile(tx, ty)
			if td.subdivided:
				for si in 4:
					for ci in 4:
						var p := get_corner_world_xz(tx, ty, si, ci)
						if abs(p.x - wx) < eps and abs(p.y - wz) < eps:
							result.append({"tx":tx,"ty":ty,"si":si,"ci":ci})
			else:
				for ci in 4:
					var p := get_corner_world_xz(tx, ty, -1, ci)
					if abs(p.x - wx) < eps and abs(p.y - wz) < eps:
						result.append({"tx":tx,"ty":ty,"si":-1,"ci":ci})
	return result

## Corner height for a specific corner ref.
func get_corner_height(tx: int, ty: int, si: int, ci: int) -> float:
	var c := get_cube(tx, ty, si)
	if c == null: return 0.0
	return c.corners[ci]

func set_corner_height(tx: int, ty: int, si: int, ci: int, h: float) -> void:
	var c := get_cube(tx, ty, si)
	if c == null: return
	c.corners[ci] = clampf(h, MIN_H, MAX_H)

# ═══════════════════════════════════════════════════════════════════════════════
# FACE CORNERS MAP  (which corner indices belong to each face top edge)
# ═══════════════════════════════════════════════════════════════════════════════

## Returns which corner indices (0-3) form the TOP edge of the given face.
## For FACE_TOP: all 4. For sides: the 2 top corners. For BOTTOM: none (base_y).
static func face_top_corners(face: int) -> Array:
	match face:
		FACE_TOP:    return [0, 1, 2, 3]
		FACE_NORTH:  return [0, 1]        ## NW, NE
		FACE_SOUTH:  return [3, 2]        ## SW, SE
		FACE_WEST:   return [0, 3]        ## NW, SW
		FACE_EAST:   return [1, 2]        ## NE, SE
		_:           return []

# ═══════════════════════════════════════════════════════════════════════════════
# SERIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

func to_json() -> String:
	var grid : Array = []
	for tx in grid_width:
		var col : Array = []
		for ty in grid_height:
			col.append(tiles[tx][ty].to_dict())
		grid.append(col)
	return JSON.stringify({"w": grid_width, "h": grid_height, "tiles": grid}, "\t")

func from_json(text: String) -> bool:
	var data = JSON.parse_string(text)
	if data == null: return false
	var w : int = data.get("w", 0)
	var h : int = data.get("h", 0)
	if w <= 0 or h <= 0: return false
	init_grid(w, h)
	var grid : Array = data.get("tiles", [])
	for tx in mini(grid.size(), w):
		var col : Array = grid[tx]
		for ty in mini(col.size(), h):
			tiles[tx][ty] = TerrainTileData.from_dict(col[ty])
	return true
