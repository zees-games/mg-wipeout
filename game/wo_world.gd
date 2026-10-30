extends RefCounted

const WoPaths := preload("wo_paths.gd")

## A course's imported geometry: a `world` piece names a dot-bsp-mesh (`worlds/<mesh>.json` and `.bin`) that
## dot-map's converter wrote; this draws the faces and builds one convex hull per player-solid brush.
## The mesh is never in the document (a megabyte against the wire's 64 KB); `maps_delivery: client` mounts it.

const CHANNEL := "wo.world"

const CLOUD_SERVICE := &"dot_cloud_client"

## Hull kinds a player is stopped by. A piece's `skip` lists model numbers the course replaces
## with its own scripted pieces.
const SOLID_KINDS := ["solid", "clip", "glass"]

## Brightest to dimmest channel an imported bake may keep, on every surface and an actor's ambient (dot-map's shader limit); tighter than its floor's 2.5 because a blue author bake tinted every wall.
const MAX_CHROMA_RATIO := 1.6

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


## The start and finish a map's `roles` name (`wo_start` on spawns or entities, `wo_finish` on entities), as `{start, finish}`;
## a key is left out when no role names it. A zone is centred on the mean of its entities' places and faces the first one.
static func zones_from_roles(manifest: Dictionary) -> Dictionary:
	var places: Dictionary = {}

	for e: Dictionary in manifest.get("entities", []):
		if e.get("origin") is Array and (e["origin"] as Array).size() == 3:
			places[int(e.get("entity", -1))] = {"at": e["origin"], "yaw": 0.0}

	var spawns: Array = manifest.get("spawns", [])
	var found: Dictionary = {"wo_start": [], "wo_finish": []}

	for r: Dictionary in manifest.get("roles", []):
		var role := str(r.get("role", ""))

		if not found.has(role):
			continue

		var at: Dictionary = places.get(int(r.get("entity", -1)), {})

		if at.is_empty():
			for s: Dictionary in spawns:
				if str(s.get("classname", "")) == str(r.get("classname", "")) and str(s.get("targetname", "")) == str(r.get("targetname", "")):
					at = {"at": s["at"], "yaw": float(s.get("yaw", 0.0))}
					break

		if not at.is_empty():
			(found[role] as Array).append(at)

	var out: Dictionary = {}

	for role: String in found:
		var list: Array = found[role]

		if list.is_empty():
			continue

		var sum := Vector3.ZERO

		for z: Dictionary in list:
			sum += Vector3(z["at"][0], z["at"][1], z["at"][2])

		sum /= float(list.size())
		var at := [snappedf(sum.x, 0.01), snappedf(sum.y, 0.01), snappedf(sum.z, 0.01)]
		var zone := {"at": at, "yaw": float(list[0]["yaw"])}

		if role == "wo_start":
			zone["size"] = [10.0, 8.0]
			out["start"] = zone
		else:
			zone["size"] = [6.0, 4.0, 4.0]
			zone["lounge"] = at
			out["finish"] = zone

	return out


## Puts the zones [method zones_from_roles] finds in the manifest of [param doc]'s first world piece into
## [param doc]'s start and finish, over the hand-written ones. A document with no roles is left alone.
static func apply_roles(doc: Dictionary) -> void:
	for piece: Dictionary in doc.get("pieces", []):
		if str(piece.get("kind", "")) != "world":
			continue

		var prefix := prefix_of(str(piece.get("mesh", "")))

		if prefix.is_empty():
			return

		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(prefix + ".json"))

		if parsed is Dictionary:
			doc.merge(zones_from_roles(parsed), true)

		return


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
	var material_for := _surfaces.world_material_for(mesh, mesh.source_path.get_base_dir())

	for model in mesh.models():
		if skip.has(model) or not mesh.mover(model).is_empty():
			continue

		for group: Dictionary in mesh.build_meshes(model, material_for):
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


## The map's own world through dot-map's [DotMapWorld] (models, entity logic, volumes); [param hooks] is what the
## game plugs in (damage, move, event, send). The stage sets the bodies' layer. Null with a line when the files
## or the source document are missing.
static func build_io(spec: Dictionary, hooks: Dictionary, authoritative: bool, draw: bool, rate: int) -> DotMapWorld:
	var mesh_id := str(spec.get("mesh", ""))
	var prefix := prefix_of(mesh_id)

	if prefix.is_empty():
		DotLog.warn(CHANNEL, "an io world has no mesh here", {"mesh": mesh_id})
		return null

	if _surfaces == null:
		_surfaces = DotMapSurfaces.new()
		_surfaces.path_fn = WoPaths.rebase

	# Process-wide on purpose, never reset: actor ambient reads it live; wipeout is one game per process.
	DotMapBspMesh.set_lightmap_max_chroma_ratio(MAX_CHROMA_RATIO)
	var wired := hooks.duplicate()
	var built := DotMapWorld.build(prefix, wired, {
		"authoritative": authoritative, "rate": rate, "map_id": mesh_id,
		# Ambient players on the dummy driver leave their playbacks and streams alive at exit.
		"environment": false, "surfaces": _surfaces, "draw": draw, "lightmap": draw, "props": draw, "sounds": draw and DotAudioSink.device_present(),
	})

	if not built.ok:
		DotLog.warn(CHANNEL, "an io world would not build", {"mesh": mesh_id, "why": built.error.message})
		return null

	return built.value
