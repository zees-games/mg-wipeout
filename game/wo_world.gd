extends RefCounted

const WoPaths := preload("wo_paths.gd")

## A course's imported geometry: a `world` piece names a dot-bsp-mesh (`worlds/<mesh>.json` and
## `.bin` beside the courses) that dot-map's converter wrote, and this builds it: the faces
## drawn, one convex hull per player-solid brush as a single static body.
##
## The mesh is never in the document (a megabyte against the wire's 64 KB). A server and a solo
## player read it from the pack's `worlds/`; a connected client reads it from the courses pack
## its server names, which `maps_delivery: client` (game.yml) mounts under `res://dot_cloud/`.

const CHANNEL := "wo.world"

const CLOUD_SERVICE := &"dot_cloud_client"

## Hull kinds a player is stopped by. A piece's `skip` lists model numbers the course replaces
## with its own scripted pieces.
const SOLID_KINDS := ["solid", "clip", "glass"]

## Source material generic id to a [DotMapSurfaces] kind. The tint is the original's average
## colour, so the hue and darkness of a room survive the replaced texture.
const KINDS := {
	"stone_wall": &"concrete", "metal": &"metal", "plaster_painted": &"plaster",
	"carpet": &"plaster", "ceiling": &"concrete_clean", "flat": &"plaster",
	"wood_planks": &"wood_planks", "parquet": &"wood_floor", "tile_floor": &"tile_white",
	"door_wood": &"wood_planks", "concrete": &"concrete", "wood_floor": &"wood_floor",
	"mud": &"ground",
}

## Directories that hold `<mesh>.json`; the catalogue adds `<courses>/../worlds`.
static var dirs: PackedStringArray = PackedStringArray()

static var _surfaces: DotMapSurfaces = null


static func add_dir(path: String) -> void:
	if not dirs.has(path):
		dirs.append(path)


## Where [param mesh]'s files are, without extension, or "". A client never read the courses
## directory, so it also looks in every mounted pack's `worlds/`.
static func prefix_of(mesh: String) -> String:
	for dir in dirs:
		var prefix := dir.path_join(mesh)
		if FileAccess.file_exists(prefix + ".json"):
			return prefix

	for dir in _mounted_dirs():
		var prefix := dir.path_join(mesh)
		if FileAccess.file_exists(prefix + ".json"):
			return prefix

	return ""


## Mesh ids the document's world pieces name that no mounted pack holds yet.
static func missing(doc: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()

	for piece: Dictionary in doc.get("pieces", []):
		if str(piece.get("kind", "")) != "world":
			continue

		var mesh := str(piece.get("mesh", ""))

		if mesh != "" and not out.has(mesh) and prefix_of(mesh).is_empty():
			out.append(mesh)

	return out


## Fetches [param mesh]'s files: a maps pack whose manifest puts them in a group named after the
## mesh id is widened to include it, so a join downloads the courses played, not every mesh.
## OK with nothing done when no mounted pack groups it (an ungrouped pack arrived whole).
static func fetch(mesh: String) -> DotResult:
	var cloud := DotRegistry.get_service(CLOUD_SERVICE)

	if cloud == null:
		return DotResult.success(false)

	for key: String in cloud.call("acquired_keys"):
		var manifest: Object = cloud.call("manifest_for", key)

		if manifest == null:
			continue

		for file: Object in manifest.get("files"):
			if (file.get("groups") as PackedStringArray).has(mesh):
				var got: DotResult = await cloud.call(
					"ensure", StringName(manifest.get("content_id")), str(manifest.get("version")),
					PackedStringArray([mesh]))
				return got.wrap("fetching mesh %s" % mesh) if not got.ok else DotResult.success(true)

	return DotResult.success(false)


static func _mounted_dirs() -> PackedStringArray:
	var out := PackedStringArray()
	var root := "res://dot_cloud"

	for owner in DirAccess.get_directories_at(root):
		for pack in DirAccess.get_directories_at(root.path_join(owner)):
			for version in DirAccess.get_directories_at(root.path_join(owner).path_join(pack)):
				out.append(root.path_join(owner).path_join(pack).path_join(version).path_join("worlds"))

	return out


## The built world for a piece, or null (with a line) when its files are not here.
static func build(spec: Dictionary, physics: Object) -> StaticBody3D:
	var mesh_id := str(spec.get("mesh", ""))
	var prefix := prefix_of(mesh_id)

	if prefix.is_empty():
		DotLog.warn(CHANNEL, "a world piece has no mesh here", {"mesh": mesh_id})
		return null

	var read := DotMapBspMesh.load_prefix(prefix)

	if not read.ok:
		DotLog.warn(CHANNEL, "a world mesh would not read", {"mesh": mesh_id, "why": read.error.message})
		return null

	var mesh: DotMapBspMesh = read.value
	var skip: Dictionary = {}

	for model in spec.get("skip", []):
		skip[int(model)] = true

	if _surfaces == null:
		_surfaces = DotMapSurfaces.new()
		_surfaces.path_fn = WoPaths.rebase

	var body := StaticBody3D.new()
	body.name = "World_%s" % mesh_id
	var drawn := Node3D.new()
	drawn.name = "Drawn"
	body.add_child(drawn)
	var cache: Dictionary = {}

	for model in mesh.models():
		if skip.has(model) or not mesh.mover(model).is_empty():
			continue

		for group: Dictionary in mesh.build_meshes(model, func(rec: Dictionary) -> Material:
				return _material(rec, cache)):
			if bool(group["sky3d"]):
				continue
			var instance := MeshInstance3D.new()
			instance.mesh = group["mesh"]
			drawn.add_child(instance)

		for hull: Dictionary in mesh.hull_shapes(model, PackedStringArray(SOLID_KINDS)):
			var shape := CollisionShape3D.new()
			shape.shape = hull["shape"]
			body.add_child(shape)

	return body


static func _material(rec: Dictionary, cache: Dictionary) -> Material:
	var generic := str(rec.get("generic", ""))

	if generic == "water":
		return null

	var colour: Array = rec.get("colour", [0.6, 0.6, 0.6]) if rec.get("colour") != null else [0.1, 0.1, 0.1]
	var key := "%s|%s" % [generic, colour]

	if cache.has(key):
		return cache[key]

	var tint := Color(minf(colour[0] * 1.8, 1.2), minf(colour[1] * 1.8, 1.2), minf(colour[2] * 1.8, 1.2))
	var material: StandardMaterial3D

	if generic == "glass":
		material = StandardMaterial3D.new()
		material.albedo_color = Color(0.7, 0.85, 0.9, 0.25)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	else:
		material = _surfaces.material(KINDS.get(generic, &"concrete"), tint)

	cache[key] = material
	return material
