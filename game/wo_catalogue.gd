extends RefCounted

const WoCourseDoc := preload("wo_course_doc.gd")
const WoPaths := preload("wo_paths.gd")
const WoWorld := preload("wo_world.gd")

## Every course and arena this server can play, and which one is next.
##
## [b]Two sources, and the built-in one is a floor rather than a feature.[/b] The courses are
## the mg-wipeout-maps repository's, read from [member WoConfig.course_directory] — a link in
## a checkout, a directory in a delivered pack. A server whose directory is missing or empty
## still has [method practice] and [method practice_arena], so it plays rather than refusing
## to start; that is the state a fresh clone without the maps repository is in, and nothing
## in it is broken.
##
## [b]A server reads documents; a client never does.[/b] The course travels in the round's
## first event (see [WoCourseDoc]), so nothing here runs on a connected client.

const CHANNEL := "wo.catalogue"

## id -> normalised document.
var courses: Dictionary = {}
var arenas: Dictionary = {}

## id -> path of the course's `cfg/<id>.cfg`, for the courses that have one. Looked for beside
## the directory the document was read from (`<root>/../cfg`), so a checkout's link and a
## delivered pack's mount both find it. See [WoCourseCfg].
var course_cfg: Dictionary = {}

## Files that were refused, with why. What `wo_courses` prints, so a mapper can see it.
var refused: Dictionary = {}

## id -> pack title, for the courses in [member courses] that a subscribed pack provided (solo
## only). The game's own courses are never in it, and an id of theirs is never taken by a pack.
var workshop: Dictionary = {}

## The Workshop's index and the `map_kind`s taken from it; see [method follow_content].
var content_index: DotContentIndex = null
var content_kinds: PackedStringArray = PackedStringArray()

## The order courses come up in when they are not shuffled.
var _order: Array[StringName] = []
var _next: int = 0

## The server's maps.yml, or null when there is none (every course rotates, as it always did).
## dot-map's rotation file speaks DotMapDef; this catalogue holds course documents, so [member _defs]
## mirrors the ids and the file marks `in_rotation` on the mirror. See [method rotating].
var rotation_file: DotMapRotationFile = null
var _defs: DotMapCatalogue = DotMapCatalogue.new()
var _rotation: DotMapRotation = DotMapRotation.of(_defs)
var _workshop_docs: Dictionary = {}


## Reads every document under [param directory] (relative to this game's root), and adds the
## two built in. Forgets anything read before.
func load_from(directory: String) -> int:
	courses.clear()
	arenas.clear()
	refused.clear()
	workshop.clear()
	course_cfg.clear()

	_add(practice(), "built-in")
	_add(practice_arena(), "built-in")

	var root := WoPaths.rebase("res://" + directory.trim_prefix("res://").trim_prefix("/"))
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "courses loaded", {
		"courses": courses.size(), "arenas": arenas.size(), "refused": refused.size(),
	})
	return loaded


## Adds every document under [param root] — an absolute `res://` path — to what is already
## loaded. What a server uses for a course pack mounted beside the game.
##
## [b]Absolute, and not rebased.[/b] A delivered course pack mounts at its OWN prefix
## (`res://dot_cloud/<owner>/mg-wipeout-maps/<version>/`), not under this game's, so the
## rebasing every one of this game's own paths needs would put it in the wrong place.
func add_directory(root: String) -> int:
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "courses added", {
		"from": root, "read": loaded, "courses": courses.size(), "arenas": arenas.size(),
	})
	return loaded


func _read_directory(root: String) -> int:
	var dir := DirAccess.open(root)

	if dir == null:
		DotLog.info(CHANNEL, "no course directory here", {"looked_at": root})
		return 0

	var files := PackedStringArray()

	for file in dir.get_files():
		# Anything that is not a document is somebody's README.
		if file.ends_with(".json"):
			files.append(file)

	# Sorted, so the order a server plays them in does not depend on the filesystem.
	files.sort()

	var loaded := 0

	for file in files:
		var path := root.path_join(file)
		var text := FileAccess.get_file_as_string(path)

		if text.is_empty():
			refused[file] = "empty or unreadable"
			continue

		var parsed := WoCourseDoc.parse_json(text, file)

		if not parsed.ok:
			refused[file] = parsed.error.message
			# WARN: a server is running without a course somebody installed, and the mapper
			# needs the sentence. Not ERROR: every other course still plays.
			DotLog.warn(CHANNEL, "a document was refused", {
				"file": file, "why": parsed.error.message, "detail": parsed.error.detail,
			})
			continue

		if _add(parsed.value, file):
			loaded += 1
			var cfg_path := root.path_join("..").path_join("cfg").path_join("%s.cfg" % parsed.value["id"])
			cfg_path = cfg_path.simplify_path()

			WoWorld.add_dir(root.path_join("..").path_join("worlds").simplify_path())

			if FileAccess.file_exists(cfg_path):
				course_cfg[StringName(str(parsed.value["id"]))] = cfg_path

	return loaded


func _add(doc: Dictionary, origin: String) -> bool:
	var id := StringName(str(doc["id"]))
	var into := courses if str(doc["kind"]) == WoCourseDoc.KIND_COURSE else arenas

	if into.has(id) and origin != "built-in":
		# A file named after a built-in replaces it, which is how a server improves on the
		# practice course without a code change. Two FILES with one id is a mistake.
		if not _is_builtin(id):
			refused[origin] = "a second document with id %s" % id
			return false

	into[id] = doc
	return true


static func _is_builtin(id: StringName) -> bool:
	return id == &"wo_practice" or id == &"wo_practice_arena"


func _rebuild_order() -> void:
	_order.clear()

	for id: StringName in courses:
		_order.append(id)

	_order.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	_next = 0


## Takes the courses subscribed packs provide, for the index's current session only. Opt-in.
## A pack's map is a [b]course document[/b] (the JSON `courses/` holds, see its README) named
## by the entry's `scene` path, with `map_kind` one of [param accepted_kinds] ("*" is every kind,
## empty none). The document is the whole map (pieces, checkpoints, finish, route), so a pack
## ships no code and the game needs no second format. Arenas are not offered: the final death
## stays the game's own.
##
## [b]Synced on every read rather than copied once[/b]: the index filters by its current
## session, so a game that goes online loses them with no signal to miss.
## [method playable_courses] is the read everything goes through.
func follow_content(index: DotContentIndex, accepted_kinds: PackedStringArray = PackedStringArray()) -> void:
	content_index = index
	content_kinds = accepted_kinds
	sync_content()


## Brings [member courses] in line with the index's current session: a pack course in, one that
## left out. The game's own ids win, and a pack course that is not a valid document is listed in
## [member refused] and left out.
func sync_content() -> void:
	var wanted := {}

	if content_index != null:
		for entry in content_index.entries(&"map"):
			var kind := str(entry.raw.get("map_kind", ""))

			if kind == "" or not (content_kinds.has("*") or content_kinds.has(kind)):
				continue

			var id := StringName(entry.id)

			if wanted.has(id) or arenas.has(id) or (courses.has(id) and not workshop.has(id)):
				continue

			var doc := _workshop_doc(entry)

			if not doc.is_empty():
				wanted[id] = [doc, entry.pack_title]

	var changed := false

	for id: StringName in workshop.keys():
		if not wanted.has(id):
			courses.erase(id)
			workshop.erase(id)
			changed = true

	for id: StringName in wanted:
		if not courses.has(id):
			courses[id] = wanted[id][0]
			workshop[id] = wanted[id][1]
			changed = true

	if changed:
		_rebuild_order()


func _workshop_doc(entry: DotContentEntry) -> Dictionary:
	if _workshop_docs.has(entry.key):
		return _workshop_docs[entry.key]

	var path := entry.path("scene")
	var text := FileAccess.get_file_as_string(path) if path != "" else ""
	var parsed := WoCourseDoc.parse_json(text, path) if text != "" \
		else DotResult.fail(DotError.CODE_IO, "empty or unreadable", path)
	var doc: Dictionary = {}

	if parsed.ok and str(parsed.value.get("kind", "")) == WoCourseDoc.KIND_COURSE:
		doc = parsed.value
		doc["id"] = entry.id
	else:
		var why: String = parsed.error.message if not parsed.ok else "a pack map must be a course, not an arena"
		refused[entry.key] = why
		DotLog.warn(CHANNEL, "a Workshop course was refused", {"entry": entry.key, "why": why})

	_workshop_docs[entry.key] = doc
	return doc


## The file a game pack states what it takes from subscriptions in (dot-cloud's
## docs/workshop.md, "What a game accepts"). Read from there so the site and this list cannot drift.
const PROVIDES_PATH := "res://provides.json"
const ACCEPTED_MAP_KINDS_FALLBACK := ["obstacle", "race"]


## The `map_kind`s of subscribed maps this game takes: `accepts.map_kinds` in `provides.json`.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := WoPaths.rebase(PROVIDES_PATH)
	var parsed: Variant = null
	if FileAccess.file_exists(path):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null
	if not (kinds is Array):
		kinds = ACCEPTED_MAP_KINDS_FALLBACK
	for kind: Variant in (kinds as Array):
		out.append(str(kind))
	return out


## Whether [param id] came from a subscribed pack.
func is_workshop(id: StringName) -> bool:
	return workshop.has(id)


## The name a menu shows: "Name [Pack]" for a pack's course, the plain name otherwise.
func label_of(id: StringName) -> String:
	var name := str((courses.get(id, {}) as Dictionary).get("name", id))
	var pack := str(workshop.get(id, ""))
	return "%s [%s]" % [name, pack] if pack != "" else name


## The ids a server may draw from, after [param allowed] (empty is all). The built-in
## practice course drops out once there is anything else, because a server with ten real
## courses should not spend one round in eleven on the tutorial.
func playable_courses(allowed: PackedStringArray) -> Array[StringName]:
	sync_content()
	var out: Array[StringName] = []

	for id in _order:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	if allowed.is_empty() and out.size() > 1:
		out.erase(&"wo_practice")

	return out


## Whether maps.yml names rotations, so that it (not `shuffle_courses`) orders the courses.
func has_rotation_file() -> bool:
	return rotation_file != null and rotation_file.has_rotations()


## Brings the mirror up to date with [member courses] and lets the file mark who rotates.
## Without a file every course is in, which is what [method playable_courses] always did.
func apply_rotation(allowed: PackedStringArray = PackedStringArray()) -> void:
	sync_content()
	var seen := {}

	for id: StringName in _order:
		seen[id] = true
		var def := _defs.get_map(id)

		if def == null:
			def = DotMapDef.new()
			def.id = id
			def.scene_path = "wo:%s" % id
			def.display_name = str((courses.get(id, {}) as Dictionary).get("name", id))
			var _added := _defs.add(def)

		def.enabled = allowed.is_empty() or allowed.has(String(id))

	for def: DotMapDef in _defs.maps.duplicate():
		if not seen.has(def.id):
			var _gone := _defs.remove(def.id)

	if has_rotation_file():
		# A file that names rotations leaves the tutorial out unless it is all there is.
		# Captures the mirror, never self: a lambda on self held by a member is a reference cycle,
		# and a RefCounted cycle is a leak the exit check reports.
		var mirror := _defs
		rotation_file.fallback_in = func(def: DotMapDef) -> bool:
			return def.id != &"wo_practice" or mirror.size() == 1
		var _applied := rotation_file.apply(_rotation)
		return

	_rotation.order = []

	for def: DotMapDef in _defs.maps:
		def.in_rotation = true


## `wo_rotation <name>`: the live switch to another named rotation in the file.
func switch_rotation(rotation_name: String) -> DotResult:
	if not has_rotation_file():
		return DotResult.fail(DotError.CODE_STATE, "There is no maps.yml to switch rotations in.")

	apply_rotation()
	return rotation_file.switch(_rotation, rotation_name)


## Whether [param id] is in the active rotation. A course the catalogue does not hold is not.
func in_rotation(id: StringName) -> bool:
	if not courses.has(id):
		return false

	if not has_rotation_file():
		return true

	apply_rotation()
	var def := _defs.get_map(id)
	return def != null and def.in_rotation


## What the ballot, a nomination and the next-course draw may offer: [method playable_courses]
## less the courses maps.yml leaves out. A course left out stays [i]playable[/i] (the map menu
## loads it). With no file, or a file that leaves nothing, it is [method playable_courses].
func rotating(allowed: PackedStringArray) -> Array[StringName]:
	var every := playable_courses(allowed)

	if not has_rotation_file():
		return every

	apply_rotation(allowed)
	var out: Array[StringName] = []

	for id in every:
		var def := _defs.get_map(id)

		if def != null and def.in_rotation:
			out.append(id)

	return out if not out.is_empty() else every


## Records that [param id] was built, for the file's cooldown and cycle. Nothing without a file.
func note_played(id: StringName) -> void:
	if has_rotation_file() and courses.has(id):
		_rotation.note_played(id)


func playable_arenas(allowed: PackedStringArray) -> Array[StringName]:
	var out: Array[StringName] = []

	for id: StringName in arenas:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	if allowed.is_empty() and out.size() > 1:
		out.erase(&"wo_practice_arena")

	return out


## The next course: drawn from [param stream] when shuffling, in order otherwise. A maps.yml with
## rotations replaces both: its rotation's mode (`random` with a cooldown, or `cycle`) and
## written order decide.
##
## [b]Never the same course twice running when there is a choice[/b], because a shuffle that
## repeats is the thing every player notices first and reports as the rotation being broken.
func next_course(allowed: PackedStringArray, shuffle: bool, stream: DotRandomStream,
		previous: StringName) -> Dictionary:
	if has_rotation_file():
		apply_rotation(allowed)

		if _rotation.seed_value == 0 and stream != null:
			_rotation.seed_value = stream.next_range_i(1, 0x3fffffff)

		var chosen := _rotation.choose(0)

		if chosen != null and courses.has(chosen.id):
			return courses[chosen.id]

	var ids := rotating(allowed)

	if ids.is_empty():
		DotLog.warn(CHANNEL, "no course matches the allowed list; playing practice", {
			"allowed": ",".join(allowed),
		})
		return courses.get(&"wo_practice", practice())

	var pick: StringName

	if shuffle and stream != null:
		pick = ids[stream.next_range_i(0, ids.size() - 1)]

		if pick == previous and ids.size() > 1:
			pick = ids[(ids.find(pick) + 1 + stream.next_range_i(0, ids.size() - 2)) % ids.size()]
	else:
		pick = ids[_next % ids.size()]
		_next += 1

	return courses[pick]


func pick_arena(allowed: PackedStringArray, stream: DotRandomStream) -> Dictionary:
	var ids := playable_arenas(allowed)

	if ids.is_empty():
		return arenas.get(&"wo_practice_arena", practice_arena())

	return arenas[ids[stream.next_range_i(0, ids.size() - 1)] if stream != null else ids[0]]


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["courses (%d)" % courses.size()])

	for id in _order:
		var doc: Dictionary = courses[id]
		lines.append("  %-22s %-24s %d pieces  %s%s" % [
			id, label_of(id), (doc["pieces"] as Array).size(), str(doc["author"]),
			"" if in_rotation(id) else "  (not in rotation)",
		])

	lines.append("arenas (%d)" % arenas.size())

	for id: StringName in arenas:
		var doc: Dictionary = arenas[id]
		lines.append("  %-22s %-24s %d spawn areas" % [
			id, str(doc["name"]), (doc["spawns"] as Array).size(),
		])

	if not refused.is_empty():
		lines.append("refused (%d)" % refused.size())

		for file: String in refused:
			lines.append("  %-22s %s" % [file, refused[file]])

	return lines


# --- The two built in ---------------------------------------------------------

## A short course of one of each family of obstacle: still ground, a carrier, a hazard.
##
## [b]Written here rather than shipped as a file,[/b] so a server with no course directory
## at all — a fresh clone, a suite — has something to play and the suites have a course whose
## every number is in front of them.
static func practice() -> Dictionary:
	var doc := {
		"format": 1,
		"kind": "course",
		"id": "wo_practice",
		"name": "Practice Run",
		"author": "mg-wipeout",
		"blurb": "Three things to cross before the real courses: a gap, an arm and a ride.",
		"water_height": -6.0,
		"start": {"at": [0.0, 0.0, 0.0], "size": [10.0, 8.0], "yaw": 0.0},
		"pieces": [
			# Run-out from the start pad.
			{"kind": "box", "at": [0.0, -0.5, -9.0], "size": [6.0, 1.0, 10.0]},
			# A 2.5 m gap, inside a running jump, onto a landing.
			{"kind": "box", "at": [0.0, -0.5, -21.5], "size": [6.0, 1.0, 10.0]},
			# A sweeping arm at shin height across the landing: jump it.
			{"kind": "spinner", "at": [0.0, 0.0, -21.5], "arm_length": 4.6, "arm_height": 0.55,
				"speed": 75.0, "arms": 2},
			# A mover across a 9 m gap.
			{"kind": "box", "at": [0.0, -0.5, -29.5], "size": [6.0, 1.0, 6.0], "role": "safe"},
			{"kind": "mover", "from": [0.0, -0.4, -35.5], "to": [0.0, -0.4, -41.5],
				"size": [4.0, 0.6, 4.0], "period": 5.0},
			{"kind": "box", "at": [0.0, -0.5, -48.0], "size": [8.0, 1.0, 8.0], "role": "safe"},
		],
		"checkpoints": [
			{"at": [0.0, 0.0, -29.0], "size": [6.0, 4.0, 2.0]},
		],
		"finish": {"at": [0.0, 0.0, -47.0], "size": [8.0, 4.0, 2.0], "lounge": [0.0, 0.0, -49.0]},
		"route": [
			{"at": [0.0, 0.0, -3.2], "reach": 1.0},
			{"at": [0.0, 0.0, -13.5], "jump": true, "reach": 0.55},
			{"at": [0.0, 0.0, -18.0]},
			# Round the arm's post, not through it; the arm itself is hopped.
			{"at": [1.8, 0.0, -20.0]},
			{"at": [1.8, 0.0, -23.5]},
			{"at": [0.0, 0.0, -25.5]},
			# Two metres back from the edge to wait for the mover, then on it, then off it.
			{"at": [0.0, 0.0, -30.5], "reach": 0.6},
			{"at": [0.0, 0.0, -35.5], "board": true, "ride": true, "reach": 0.9},
			{"at": [0.0, 0.0, -45.5], "board": true, "reach": 0.9},
			{"at": [0.0, 0.0, -47.5]},
		],
		# dot-props' beach balls in the back corners of the start pen, to bat about while the
		# gate is up. headless_run walks into one; nothing on the course itself.
		"toys": [
			{"toy": "beach_ball", "at": [-3.8, 0.0, 2.8]},
			{"toy": "beach_ball", "at": [3.8, 0.0, 2.8]},
		],
	}

	var checked := WoCourseDoc.validate(doc)
	return checked.value if checked.ok else doc


## A square with four corners to start in and a gallery along one side.
static func practice_arena() -> Dictionary:
	var doc := {
		"format": 1,
		"kind": "arena",
		"id": "wo_practice_arena",
		"name": "The Square",
		"author": "mg-wipeout",
		"blurb": "Four corners, one middle, everything you need in the middle.",
		"kill_height": -8.0,
		"pieces": [
			{"kind": "box", "at": [0.0, -0.5, 0.0], "size": [26.0, 1.0, 26.0], "role": "arena"},
			{"kind": "box", "at": [0.0, 0.6, 0.0], "size": [3.0, 1.2, 3.0], "role": "pillar"},
		],
		"spawns": [
			{"at": [-9.0, 0.0, -9.0], "size": [4.0, 4.0]},
			{"at": [9.0, 0.0, 9.0], "size": [4.0, 4.0]},
			{"at": [9.0, 0.0, -9.0], "size": [4.0, 4.0]},
			{"at": [-9.0, 0.0, 9.0], "size": [4.0, 4.0]},
		],
		"drops": [{"at": [0.0, 0.0, 0.0], "size": [12.0, 12.0]}],
		"gallery": {"at": [0.0, 6.0, 20.0], "size": [14.0, 5.0]},
		# Two balls between the corners, clear of the drops and the pillar: shot about, thrown by
		# a barrel's blast, never cover. headless_run shoots one.
		"toys": [
			{"toy": "beach_ball", "at": [-8.0, 0.0, 0.0]},
			{"toy": "football", "at": [8.0, 0.0, 0.0]},
		],
	}

	var checked := WoCourseDoc.validate(doc)
	return checked.value if checked.ok else doc
