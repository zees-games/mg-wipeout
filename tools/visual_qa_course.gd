extends RefCounted

## The course half of Wipeout's visual QA capture (tools/visual_qa.gd; the loop is dot-game's docs/visual-qa.md): the course objects, each filmed with a runner (WoFigure) in the real built course (WoCourse, drawn as a client draws it).
## object_<kind> is one of every piece kind the shipped courses are made of (mover, turntable, roller, seesaw, tiles, conveyor, bouncer, spinner, pendulum, pusher, fall, ramp, ball, cylinder), plus object_start (the start pen and its gate). Clip: approach. A mover, turntable, seesaw, tiles, conveyor, ramp or bouncer is stood on (a mover, turntable and seesaw carry the runner); a hazard is walked up to from 4 m.
## The first-person camera is the runner's eye, so f shows what a runner sees; t and o are dot-game's outside views.

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")

const CLIPS: PackedStringArray = ["approach"]
## Pieces that carry the runner stand-still: the planted feet move at the platform's speed in the world, so the world
## foot-slide limit does not fit; the clip "ride" has its own in tools/visual_qa_thresholds.json (relative to the
## carrying platform the feet do not move at all, 0.00 m/s in the report note).
const CLIPS_RIDE: PackedStringArray = ["ride"]
const RIDDEN: PackedStringArray = ["mover", "turntable", "seesaw"]
const SECONDS := 4.0
## The sprint pace of the stride clips (the person run clip is judged at the same speed).
const WALK_SPEED := 6.5
## Pieces a runner stands on; every other kind is a hazard (or a floor) walked up to.
const STOOD_ON: PackedStringArray = ["mover", "turntable", "seesaw", "tiles", "conveyor", "ramp", "bouncer"]
const SKIPPED: PackedStringArray = ["box", "world"]

var entries: Dictionary = {}
var course: WoCourse = null

var _entry: Dictionary = {}
var _piece: Dictionary = {}


## Every item name this file makes, in a stable order; fills [member entries].
func items(catalogue: WoCatalogue) -> PackedStringArray:
	entries.clear()
	var names := PackedStringArray()
	var seen := {}
	var docs: Array[Dictionary] = []
	var ids: Array = catalogue.courses.keys()
	ids.sort()
	for id: StringName in ids:
		docs.append(catalogue.courses[id])
	ids = catalogue.arenas.keys()
	ids.sort()
	for id: StringName in ids:
		docs.append(catalogue.arenas[id])
	for raw in docs:
		var checked := WoCourseDoc.validate(raw)
		if not checked.ok:
			continue
		var doc: Dictionary = checked.value
		var pieces: Array = doc.get("pieces", [])
		for index in pieces.size():
			var kind := str(pieces[index]["kind"])
			if SKIPPED.has(kind) or seen.has(kind):
				continue
			seen[kind] = true
			entries["object_" + kind] = {"raw": raw, "kind": kind, "index": index}
			names.append("object_" + kind)
		if not seen.has("start") and str(doc.get("kind", "")) == WoCourseDoc.KIND_COURSE and not bool(doc.get("instant", false)):
			seen["start"] = true
			entries["object_start"] = {"raw": raw, "kind": "start", "index": -1}
			names.append("object_start")
	return names


func has(item: String) -> bool:
	return entries.has(item)


func clips(item: String) -> PackedStringArray:
	if RIDDEN.has(str((entries[item] as Dictionary)["kind"])):
		return CLIPS_RIDE
	return CLIPS


func seconds(_item: String) -> float:
	return SECONDS


## Builds [param item]'s course under [param holder].
func stage(holder: Node3D, item: String, _clip: String) -> DotResult:
	_entry = entries[item]
	course = WoCourse.new()
	course.draw_world = true
	holder.add_child(course)
	var built := course.build((_entry["raw"] as Dictionary).duplicate(true))
	if not built.ok:
		return built
	_piece = {}
	if str(_entry["kind"]) != "start":
		var specs: Array = course.doc["pieces"]
		var spec: Dictionary = specs[int(_entry["index"])]
		for piece in course.pieces:
			if piece["spec"] == spec:
				_piece = piece
				break
		if _piece.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "no built piece for %s" % item)
	else:
		course.gate_closed = true
	course.pose_at_time(0.0)
	return DotResult.success(item)


## Poses the course at [param t] and returns {at, speed, yaw} for the runner (feet position, metres a second, degrees).
func drive(t: float) -> Dictionary:
	course.pose_at_time(t)
	if str(_entry["kind"]) == "start":
		return _start_runner(t)
	var spec: Dictionary = _piece["spec"]
	var kind := str(_entry["kind"])
	if kind == "mover" or kind == "turntable" or kind == "seesaw":
		var frame := course.transform_of(_piece, t)
		var offset := Vector3(_half(spec).x * 0.5, _half(spec).y, 0.0)
		return {"at": frame.origin + frame.basis * offset, "speed": 0.0}
	if STOOD_ON.has(kind):
		var centre := _centre(spec)
		return {"at": Vector3(centre.x, centre.y + _half(spec).y, centre.z), "speed": 0.0, "yaw": float(spec.get("yaw", 0.0))}
	return _hazard_runner(spec, t)


func _start_runner(t: float) -> Dictionary:
	var start: Dictionary = course.doc["start"]
	var at: Vector3 = start["at"]
	var size: Vector2 = start["size"]
	var yaw := float(start["yaw"])
	# Held at the back of the pen for the countdown, then the gate drops and they run out through it.
	course.gate_closed = t < 1.2
	var run := maxf(t - 1.2, 0.0) * 5.0
	var local := Vector3(0.0, 0.0, size.y * 0.5 - 1.0 - run)
	return {"at": at + Basis(Vector3.UP, deg_to_rad(yaw)) * local, "speed": 5.0 if t >= 1.2 else 0.0, "yaw": yaw}


func _hazard_runner(spec: Dictionary, t: float) -> Dictionary:
	var centre := _centre(spec)
	var stop_z := centre.z + _half(spec).z + 1.8
	# Sprints at WALK_SPEED and reaches the spot as the clip ends: a stop inside the clip makes the stride clips slide
	# their feet, which is a capture artefact (a runner never halts dead), not a defect of the figure.
	var left := WALK_SPEED * (SECONDS - t)
	var speed := WALK_SPEED
	var z := stop_z + maxf(left, 0.0)
	return {"at": Vector3(centre.x, _ground(Vector3(centre.x, centre.y, z), centre.y + 2.0, centre.y), z), "speed": speed}


## Where the piece sits on the ground (its middle).
func _centre(spec: Dictionary) -> Vector3:
	if spec.has("pivot"):
		var pivot: Vector3 = spec["pivot"]
		return pivot - Vector3(0.0, float(spec["length"]) + float(spec.get("radius", 0.0)), 0.0)
	if spec.has("at"):
		return spec["at"]
	var from: Vector3 = spec["from"]
	return from


## Half of the box the piece covers (x, y, z).
func _half(spec: Dictionary) -> Vector3:
	if spec.has("size"):
		return (spec["size"] as Vector3) * 0.5
	if spec.has("radius"):
		var r := float(spec["radius"])
		return Vector3(r, float(spec.get("height", spec.get("thickness", 0.5))) * 0.5, r)
	if spec.has("arm_length"):
		return Vector3(float(spec["arm_length"]), 0.3, float(spec["arm_length"]))
	if spec.has("tile"):
		var tile := float(spec["tile"]) + float(spec.get("gap", 0.0))
		return Vector3(float(spec["cols"]) * tile * 0.5, float(spec.get("thickness", 0.5)) * 0.5, float(spec["rows"]) * tile * 0.5)
	return Vector3(1.0, 0.5, 1.0)


## The top of the highest still box under (x, z) that is no higher than [param limit]; [param fallback] if none.
func _ground(at: Vector3, limit: float, fallback: float) -> float:
	var best := -INF
	for spec: Dictionary in course.doc["pieces"]:
		if str(spec["kind"]) != "box":
			continue
		var centre: Vector3 = spec["at"]
		var size: Vector3 = spec["size"]
		var top := centre.y + size.y * 0.5
		if absf(at.x - centre.x) <= size.x * 0.5 and absf(at.z - centre.z) <= size.z * 0.5 and top <= limit:
			best = maxf(best, top)
	return fallback if best == -INF else best
