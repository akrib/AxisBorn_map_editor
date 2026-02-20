## map_data.gd
## Data model for the map editor.
## A Map is a grid of TerrainTileData.
## Each TerrainTileData is either 1 CubeData (full tile) or 4 CubeData (subdivided).
## Each CubeData has 4 top corner heights + 6 FaceConfig (one per face).
## Each face now supports TWO texture layers: base (low) and overlay (high).
## Triggers can be placed on tiles for gameplay events.
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

## Texture layer constants
const LAYER_BASE    := 0   ## Low layer (drawn first)
const LAYER_OVERLAY := 1   ## High layer (drawn on top, supports transparency)

## Sub-tile center offset from tile center (as fraction of TILE_SIZE)
const SUB_CENTER: Array[Vector2] = [
	Vector2(-0.25, -0.25),
	Vector2( 0.25, -0.25),
	Vector2( 0.25,  0.25),
	Vector2(-0.25,  0.25),
]
const CORNER_OX := [-1,  1,  1, -1]
const CORNER_OZ := [-1, -1,  1,  1]

# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER TYPES
# ═══════════════════════════════════════════════════════════════════════════════

enum TriggerType {
	NONE,
	ANIMATION,
	PARTICLES,
	SPAWN_POINT,
	CHEST,
	DOOR,
	DRAWBRIDGE,
	USABLE_OBJECT,
	MESH_MARKER,      ## Placeholder for external 3D mesh
}

const TRIGGER_NAMES := {
	TriggerType.NONE:           "Aucun",
	TriggerType.ANIMATION:      "Animation",
	TriggerType.PARTICLES:      "Particules",
	TriggerType.SPAWN_POINT:    "Point de spawn",
	TriggerType.CHEST:          "Coffre",
	TriggerType.DOOR:           "Porte",
	TriggerType.DRAWBRIDGE:     "Pont-levis",
	TriggerType.USABLE_OBJECT:  "Objet utilisable",
	TriggerType.MESH_MARKER:    "Repère mesh",
}

const TRIGGER_ICONS := {
	TriggerType.NONE:           "",
	TriggerType.ANIMATION:      "🎬",
	TriggerType.PARTICLES:      "✨",
	TriggerType.SPAWN_POINT:    "📍",
	TriggerType.CHEST:          "📦",
	TriggerType.DOOR:           "🚪",
	TriggerType.DRAWBRIDGE:     "🏗",
	TriggerType.USABLE_OBJECT:  "🔧",
	TriggerType.MESH_MARKER:    "🧊",
}

# ═══════════════════════════════════════════════════════════════════════════════
# TILESET CONFIG
# ═══════════════════════════════════════════════════════════════════════════════

class TilesetConfig:
	var path       : String = ""
	var x_start    : int    = 0    ## X offset in pixels before first tile
	var y_start    : int    = 0    ## Y offset in pixels before first tile
	var x_spacing  : int    = 0    ## Horizontal spacing between tiles
	var y_spacing  : int    = 0    ## Vertical spacing between tiles
	var cell_size  : int    = 32   ## Tile size in pixels

	func to_dict() -> Dictionary:
		return {
			"path": path, "x_start": x_start, "y_start": y_start,
			"x_spacing": x_spacing, "y_spacing": y_spacing, "cell_size": cell_size
		}

	static func from_dict(d: Dictionary) -> TilesetConfig:
		var c := TilesetConfig.new()
		c.path      = d.get("path", "")
		c.x_start   = d.get("x_start", 0)
		c.y_start   = d.get("y_start", 0)
		c.x_spacing = d.get("x_spacing", 0)
		c.y_spacing = d.get("y_spacing", 0)
		c.cell_size = d.get("cell_size", 32)
		return c

	func dup() -> TilesetConfig:
		var c := TilesetConfig.new()
		c.path = path; c.x_start = x_start; c.y_start = y_start
		c.x_spacing = x_spacing; c.y_spacing = y_spacing; c.cell_size = cell_size
		return c

	## Compute the pixel rect for a given col/row
	func get_cell_rect(col: int, row: int) -> Rect2:
		var px := x_start + col * (cell_size + x_spacing)
		var py := y_start + row * (cell_size + y_spacing)
		return Rect2(px, py, cell_size, cell_size)

	## Get number of columns/rows for a texture of given size
	func get_grid_size(tex_width: int, tex_height: int) -> Vector2i:
		var usable_w := tex_width  - x_start
		var usable_h := tex_height - y_start
		var cols := 1
		var rows := 1
		if cell_size + x_spacing > 0:
			cols = maxi(1, (usable_w + x_spacing) / (cell_size + x_spacing))
		if cell_size + y_spacing > 0:
			rows = maxi(1, (usable_h + y_spacing) / (cell_size + y_spacing))
		return Vector2i(cols, rows)

# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER DATA
# ═══════════════════════════════════════════════════════════════════════════════

class TriggerData:
	var type        : int    = TriggerType.NONE
	var id          : String = ""     ## Unique ID for game reference
	var properties  : Dictionary = {} ## Custom key-value properties
	## For MESH_MARKER: properties["mesh_path"], properties["rotation_y"], properties["scale"]
	## For SPAWN_POINT: properties["entity_type"], properties["count"]
	## For DOOR/CHEST: properties["locked"], properties["key_id"]
	## For ANIMATION: properties["anim_name"], properties["loop"]
	## For PARTICLES: properties["effect_name"], properties["color"]

	func dup() -> TriggerData:
		var t := TriggerData.new()
		t.type = type; t.id = id
		t.properties = properties.duplicate(true)
		return t

	func to_dict() -> Dictionary:
		return {"type": type, "id": id, "props": properties.duplicate(true)}

	static func from_dict(d: Dictionary) -> TriggerData:
		var t := TriggerData.new()
		t.type       = d.get("type", TriggerType.NONE)
		t.id         = d.get("id", "")
		t.properties = d.get("props", {})
		return t

# ═══════════════════════════════════════════════════════════════════════════════
# INNER CLASSES
# ═══════════════════════════════════════════════════════════════════════════════

class FaceConfig:
	var atlas_path : String = ""
	var atlas_col  : int    = 0
	var atlas_row  : int    = 0
	var cell_size  : int    = 32
	var uv_scale   : float  = 1.0
	## Tileset config reference (for spacing/offset support)
	var tileset_x_start   : int = 0
	var tileset_y_start   : int = 0
	var tileset_x_spacing : int = 0
	var tileset_y_spacing : int = 0

	func has_texture() -> bool:
		return atlas_path != ""

	func dup() -> FaceConfig:
		var c := FaceConfig.new()
		c.atlas_path = atlas_path; c.atlas_col = atlas_col
		c.atlas_row  = atlas_row;  c.cell_size  = cell_size
		c.uv_scale   = uv_scale
		c.tileset_x_start   = tileset_x_start
		c.tileset_y_start   = tileset_y_start
		c.tileset_x_spacing = tileset_x_spacing
		c.tileset_y_spacing = tileset_y_spacing
		return c

	func to_dict() -> Dictionary:
		return {
			"path": atlas_path, "col": atlas_col, "row": atlas_row,
			"cs": cell_size, "uvs": uv_scale,
			"xs": tileset_x_start, "ys": tileset_y_start,
			"xsp": tileset_x_spacing, "ysp": tileset_y_spacing
		}

	static func from_dict(d: Dictionary) -> FaceConfig:
		var c := FaceConfig.new()
		c.atlas_path = d.get("path", "")
		c.atlas_col  = d.get("col",  0)
		c.atlas_row  = d.get("row",  0)
		c.cell_size  = d.get("cs",   32)
		c.uv_scale   = d.get("uvs",  1.0)
		c.tileset_x_start   = d.get("xs", 0)
		c.tileset_y_start   = d.get("ys", 0)
		c.tileset_x_spacing = d.get("xsp", 0)
		c.tileset_y_spacing = d.get("ysp", 0)
		return c

class CubeData:
	var corners: Array[float] = [0.5, 0.5, 0.5, 0.5]
	var base_y       : float = 0.0
	## Face configs: [TOP, NORTH, SOUTH, WEST, EAST, BOTTOM] — BASE layer
	var face_configs : Array = []
	## Overlay layer configs (same indexing) — drawn on top with transparency
	var overlay_configs : Array = []
	## Trigger attached to this cube
	var trigger : TriggerData = null

	func _init() -> void:
		face_configs.resize(6)
		overlay_configs.resize(6)
		for i in 6:
			face_configs[i] = FaceConfig.new()
			overlay_configs[i] = FaceConfig.new()

	func top_max() -> float:
		return maxf(maxf(corners[0], corners[1]), maxf(corners[2], corners[3]))

	func get_face_config(fi: int, layer: int) -> FaceConfig:
		if layer == LAYER_OVERLAY:
			return overlay_configs[fi]
		return face_configs[fi]

	func set_face_config(fi: int, layer: int, fc: FaceConfig) -> void:
		if layer == LAYER_OVERLAY:
			overlay_configs[fi] = fc
		else:
			face_configs[fi] = fc

	func dup() -> CubeData:
		var c := CubeData.new()
		c.corners = corners.duplicate()
		c.base_y  = base_y
		for i in 6:
			c.face_configs[i] = face_configs[i].dup()
			c.overlay_configs[i] = overlay_configs[i].dup()
		if trigger != null:
			c.trigger = trigger.dup()
		return c

	func to_dict() -> Dictionary:
		var fd: Array = []
		var od: Array = []
		for fc in face_configs: fd.append(fc.to_dict())
		for oc in overlay_configs: od.append(oc.to_dict())
		var d := {"corners": corners.duplicate(), "base_y": base_y,
				  "faces": fd, "overlay": od}
		if trigger != null and trigger.type != TriggerType.NONE:
			d["trigger"] = trigger.to_dict()
		return d

	static func from_dict(d: Dictionary) -> CubeData:
		var c := CubeData.new()
		var raw_corners : Array = d.get("corners", [0.5, 0.5, 0.5, 0.5])
		c.corners = [float(raw_corners[0]), float(raw_corners[1]),
					 float(raw_corners[2]), float(raw_corners[3])]
		c.base_y  = d.get("base_y", 0.0)
		var fd: Array = d.get("faces", [])
		for i in mini(fd.size(), 6):
			c.face_configs[i] = FaceConfig.from_dict(fd[i])
		var od: Array = d.get("overlay", [])
		for i in mini(od.size(), 6):
			c.overlay_configs[i] = FaceConfig.from_dict(od[i])
		if d.has("trigger"):
			c.trigger = TriggerData.from_dict(d["trigger"])
		return c

class TerrainTileData:
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
var tiles : Array = []
var tileset_configs : Array = []  ## Array of TilesetConfig

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
# TILESET CONFIG MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

func add_tileset_config(cfg: TilesetConfig) -> void:
	## Replace if same path already exists
	for i in tileset_configs.size():
		if tileset_configs[i].path == cfg.path:
			tileset_configs[i] = cfg
			return
	tileset_configs.append(cfg)

func get_tileset_config(path: String) -> TilesetConfig:
	for cfg in tileset_configs:
		if cfg.path == path:
			return cfg
	return null

func save_tileset_configs(file_path: String) -> bool:
	var arr : Array = []
	for cfg in tileset_configs:
		arr.append(cfg.to_dict())
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null: return false
	f.store_string(JSON.stringify({"tileset_configs": arr}, "\t"))
	f.close()
	return true

func load_tileset_configs(file_path: String) -> bool:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null: return false
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data == null: return false
	var arr : Array = data.get("tileset_configs", [])
	tileset_configs.clear()
	for d in arr:
		tileset_configs.append(TilesetConfig.from_dict(d))
	return true

# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

func set_trigger(tx: int, ty: int, si: int, trigger: TriggerData) -> void:
	var cube := get_cube(tx, ty, si)
	if cube == null: return
	cube.trigger = trigger

func get_trigger(tx: int, ty: int, si: int) -> TriggerData:
	var cube := get_cube(tx, ty, si)
	if cube == null: return null
	return cube.trigger

func get_all_triggers() -> Array:
	var result : Array = []
	for tx in grid_width:
		for ty in grid_height:
			var td := get_tile(tx, ty)
			if td == null: continue
			if td.subdivided:
				for si in 4:
					if td.cubes[si].trigger != null and td.cubes[si].trigger.type != TriggerType.NONE:
						result.append({"tx": tx, "ty": ty, "si": si, "trigger": td.cubes[si].trigger})
			else:
				if td.cubes[0].trigger != null and td.cubes[0].trigger.type != TriggerType.NONE:
					result.append({"tx": tx, "ty": ty, "si": -1, "trigger": td.cubes[0].trigger})
	return result

# ═══════════════════════════════════════════════════════════════════════════════
# CORNER UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

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

func get_corner_height(tx: int, ty: int, si: int, ci: int) -> float:
	var c := get_cube(tx, ty, si)
	if c == null: return 0.0
	return c.corners[ci]

func set_corner_height(tx: int, ty: int, si: int, ci: int, h: float) -> void:
	var c := get_cube(tx, ty, si)
	if c == null: return
	c.corners[ci] = clampf(h, MIN_H, MAX_H)

static func face_top_corners(face: int) -> Array:
	match face:
		FACE_TOP:    return [0, 1, 2, 3]
		FACE_NORTH:  return [0, 1]
		FACE_SOUTH:  return [3, 2]
		FACE_WEST:   return [0, 3]
		FACE_EAST:   return [1, 2]
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
	var ts_cfgs : Array = []
	for cfg in tileset_configs:
		ts_cfgs.append(cfg.to_dict())
	return JSON.stringify({
		"w": grid_width, "h": grid_height,
		"tiles": grid, "tileset_configs": ts_cfgs
	}, "\t")

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
	var ts_cfgs : Array = data.get("tileset_configs", [])
	tileset_configs.clear()
	for d in ts_cfgs:
		tileset_configs.append(TilesetConfig.from_dict(d))
	return true
