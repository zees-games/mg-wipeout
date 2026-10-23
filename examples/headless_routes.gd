extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Can a runner get from the start to the finish of an io course? A walker flood-fills the floor the
## map's own physics gives (1 m cells, a step or jump up to 1 m, a jump over a gap of up to 5 m,
## ladders as lifts) from where the runner stands after the start, three times: without the
## map's teleports, with them, and with them but never through a live hurt volume.
##
## What it cannot model is machinery: a door, a button, a mover that carries a body, a timed
## hazard. So `finish` is what the static floor proves, and a course whose finish only a button or a
## ride reaches is listed `none` here with the reason, not failed. Each course's plan is the
## measured outcome; a change in it (a teleport that became unreachable, a hurt on the only way)
## fails the suite so somebody looks.
##
## Measured 2026-10-23: no course's finish is reached by floor alone, and most teleport volumes (Labo's
## zonetp9 among them) lie in rooms the walker never gets to: every start is sealed by a door, a button
## or a ride the walker does not model, and Pauls' start is one isolated cell. No hurt volume is the only way.
## So what this guards is a change in that picture, not a finding that a course is broken; the proof a course
## can be finished is headless_io's walks and the bots on the route documents.
##
## Plan keys: `min_cells` (floor the walker must find from the start, default 50), `finish` is "walk" (floor alone), "tp" (needs a teleport the walker reaches) or "none";
## `hurt_only` is true when the finish is reached with the teleports but not without crossing a live
## hurt volume; `dead_tps` is the number of teleport volumes no route reaches.
const COURSES := {
	&"wo_oaks_course": {"dead_tps": 0},
	&"wo_office_course": {"dead_tps": 7},
	&"wo_dans_course": {"dead_tps": 3},
	&"wo_pauls_course": {"dead_tps": 8, "min_cells": 1},
	&"wo_scary_course": {"dead_tps": 0},
	&"wo_lego_course": {"dead_tps": 0},
	&"wo_dc_course": {"dead_tps": 3},
	&"wo_waytobar_course": {"dead_tps": 6},
	&"wo_labo_course": {"dead_tps": 3},
	&"wo_sweet_course": {"dead_tps": 5},
}
const CHECKS_PER_COURSE := 6
const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
const CELL := 1.0
const MAX_CELLS := 70000
const DIRS := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
	Vector2(0.7071, 0.7071), Vector2(-0.7071, 0.7071), Vector2(0.7071, -0.7071), Vector2(-0.7071, -0.7071)]

var _passed := 0
var _failed := 0
var _entered := 0
var _finished_count := 0
var _failures := PackedStringArray()
var _world: WoGame = null
var _expected_sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: can a runner reach the finish of each io course")
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var summary: Array[String] = []

	for id: StringName in COURSES:
		if not catalogue.courses.has(id):
			print("(%s is not installed: no mg-wipeout-maps link, nothing to check)" % id)
			continue

		_expected_sections += 1
		print("== %s" % id)
		summary.append(await _course(catalogue.courses[id], id, COURSES[id]))

	print("")
	print("per course:")
	for line in summary:
		print("  %s" % line)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0
	if _entered != _finished_count or _entered != _expected_sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_finished_count, _entered, _expected_sections])
		code = 1
	if _passed + _failed != _expected_sections * CHECKS_PER_COURSE:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, _expected_sections * CHECKS_PER_COURSE])
		code = 1
	get_tree().quit(code)


func _course(doc: Dictionary, id: StringName, plan: Dictionary) -> String:
	_entered += 1
	var game := await _fresh_world(doc)
	var runner := game.add_player(&"u1", "Runner")
	game.start()
	await _until(game, WoGame.Phase.COURSE)
	var world: DotMapWorld = game.stage.io.world
	_check(world != null, "dot-map built the world")

	# A start-line teleport moves everybody on the first ticks: the start is where the runner is after them.
	await _steps(game, 4 * TICK_RATE / 4)
	await _steps(game, 8)
	var start := runner.controller.state.position
	var spawns := game.stage.io_spawns()
	# A runner a start teleport dropped below the water is seeded from the map's first spawn point instead.
	if start.y <= float(doc["water_height"]) + 0.5 and not spawns.is_empty():
		start = spawns[0]["origin"]
		var hit := game.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(start + Vector3(0, 0.5, 0), start - Vector3(0, 6, 0)))
		if not hit.is_empty():
			start = hit["position"]
	var water := float(doc["water_height"])
	var finish := _finish_box(doc)
	var space := game.get_world_3d().direct_space_state
	var body := game.io_body(runner)

	var tps: Array = []
	var hurts: Array = []
	for node: DotMapVolumeNode in world.volumes.nodes:
		var v := node.volume
		var dest: Variant = world.io.destinations.get(v.target) if v.kind == "teleport" else null
		if v.kind == "teleport" and dest is Dictionary and (dest as Dictionary).has("at"):
			var at: Array = dest["at"]
			tps.append({"node": node, "boxes": v.brush_boxes(), "to": Vector3(at[0], at[1], at[2]),
				"gate": not node.active(), "open": node._filter_passes(world.io, body)})
		elif v.kind == "hurt" and node.active() and float(v.record.get("damage", 0.0)) > 0.0:
			for box: AABB in v.brush_boxes():
				if box.size.is_finite() and box.size.y > 0.1:
					hurts.append(box)

	var ladders: Array[AABB] = world.ladder_boxes()
	var walker := _Walker.new(space, water, ladders)
	var a := walker.flood(start, finish, [], [])
	var b := walker.flood(start, finish, tps, [])
	var c := walker.flood(start, finish, tps, hurts)

	var dead := 0
	var gated := 0
	var names: Array[String] = []
	for i in tps.size():
		if not b["tp_hit"][i]:
			dead += 1
			names.append("%s->%s" % [tps[i]["node"].volume.targetname, tps[i]["to"]])
		elif tps[i]["gate"]:
			gated += 1

	var finish_how := "walk" if a["finish"] else ("tp" if b["finish"] else "none")
	var hurt_only: bool = b["finish"] and not c["finish"]
	var line := "%s: finish %s%s; cells %d/%d/%d%s; teleports %d, unreached %d, gated %d, hurt volumes %d%s%s" % [
		id, finish_how, " (BLOCKED by a hurt volume on every route)" if hurt_only else "",
		a["cells"], b["cells"], c["cells"], " (capped)" if a["capped"] or b["capped"] or c["capped"] else "",
		tps.size(), dead, gated, hurts.size(), " [%s]" % ", ".join(names) if dead > 0 else "",
		"" if b["finish"] else "; nearest cell to the finish %.1f m" % b["nearest"]]
	print("  " + line)

	_check(a["cells"] >= int(plan.get("min_cells", 50)), "the runner starts on floor the walker can cross", "%d cells from %s" % [a["cells"], start])
	_check(b["cells"] >= a["cells"], "teleports only add floor", "%d vs %d" % [b["cells"], a["cells"]])
	_check(finish_how == plan.get("finish", "none"), "the finish is reached by: %s" % plan.get("finish", "none"), finish_how)
	_check(hurt_only == plan.get("hurt_only", false), "a live hurt volume %s the only way" % ("is on" if plan.get("hurt_only", false) else "is not on"), str(hurt_only))
	_check(dead == int(plan.get("dead_tps", 0)), "teleport volumes no route reaches: %d" % int(plan.get("dead_tps", 0)), "%d %s" % [dead, str(names)])
	_finished_count += 1
	return line


## The finish box of the document as a world box (its yaw is a multiple of 90 degrees on the imports).
func _finish_box(doc: Dictionary) -> AABB:
	var finish: Dictionary = doc["finish"]
	var at: Vector3 = finish["at"]
	var size: Vector3 = finish["size"]
	var turned := int(roundf(float(finish["yaw"]) / 90.0)) % 2 != 0
	var half := Vector3(size.z, size.y, size.x) * 0.5 if turned else size * 0.5
	return AABB(Vector3(at.x - half.x, at.y - 0.5, at.z - half.z), Vector3(half.x * 2.0, size.y + 0.5, half.z * 2.0))


## A floor-flood walker over the physics space.
class _Walker:
	var space: PhysicsDirectSpaceState3D
	var water: float
	var ladders: Array[AABB]
	var _probe := SphereShape3D.new()

	func _init(s: PhysicsDirectSpaceState3D, w: float, l: Array[AABB]) -> void:
		space = s
		water = w
		ladders = l
		_probe.radius = 0.35

	func _key(p: Vector3) -> Vector3i:
		return Vector3i(roundi(p.x / CELL), roundi(p.y * 2.0), roundi(p.z / CELL))

	func _floor(x: float, z: float, from_y: float, drop: float) -> Variant:
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - drop, z))
		var hit := space.intersect_ray(q)
		if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7 or (hit["position"] as Vector3).y <= water:
			return null
		var p: Vector3 = hit["position"]
		# room for a body: a sphere at chest height touches nothing
		var sq := PhysicsShapeQueryParameters3D.new()
		sq.shape = _probe
		sq.transform = Transform3D(Basis.IDENTITY, p + Vector3(0, 0.75, 0))
		if not space.intersect_shape(sq, 1).is_empty():
			return null
		return p

	func _blocked(a: Vector3, b: Vector3) -> bool:
		var q := PhysicsRayQueryParameters3D.create(a + Vector3(0, 0.6, 0), b + Vector3(0, 0.6, 0))
		return not space.intersect_ray(q).is_empty()

	func flood(start: Vector3, finish: AABB, tps: Array, hurts: Array) -> Dictionary:
		var seen := {}
		var queue: Array[Vector3] = [start]
		var tp_hit: Array = []
		for _t in tps:
			tp_hit.append(false)
		seen[_key(start)] = true
		var reached := false
		var nearest := INF
		var head := 0
		var capped := false
		var fin := finish.grow(0.6)

		while head < queue.size():
			var p := queue[head]
			head += 1
			if queue.size() >= MAX_CELLS:
				capped = true
				break
			var body := AABB(p + Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 1.8, 0.6))
			if fin.intersects(body):
				reached = true
			nearest = minf(nearest, finish.get_center().distance_to(p))

			var found: Array[Vector3] = []
			for dir: Vector2 in DIRS:
				for d: int in [1, 2, 3, 4, 5]:
					var x: float = p.x + dir.x * d * CELL
					var z: float = p.z + dir.y * d * CELL
					var up := 1.0
					var f: Variant = _floor(x, z, p.y + up + 0.1, up + 8.0)
					if f == null:
						continue
					var n: Vector3 = f
					if n.y - p.y > up + 0.05 or _blocked(p, n):
						continue
					found.append(n)
					if d == 1:
						break

			for ladder in ladders:
				if ladder.grow(0.9).intersects(body):
					for off in [Vector2(1.2, 0), Vector2(-1.2, 0), Vector2(0, 1.2), Vector2(0, -1.2)]:
						var c := ladder.get_center()
						var f: Variant = _floor(c.x + off.x, c.z + off.y, ladder.end.y + 1.2, 3.0)
						if f != null and (f as Vector3).y > p.y:
							found.append(f)

			for i in tps.size():
				var t: Dictionary = tps[i]
				if not t["open"]:
					continue
				for box: AABB in t["boxes"]:
					if box.grow(0.2).intersects(body):
						tp_hit[i] = true
						found.append(t["to"])
						break

			for n in found:
				var k := _key(n)
				if seen.has(k):
					continue
				var hurt := false
				for hb: AABB in hurts:
					if hb.intersects(AABB(n + Vector3(-0.2, 0.2, -0.2), Vector3(0.4, 1.4, 0.4))):
						hurt = true
						break
				if hurt:
					continue
				seen[k] = true
				queue.append(n)

		return {"finish": reached, "cells": queue.size(), "capped": capped, "tp_hit": tp_hit, "nearest": nearest}


func _until(game: WoGame, phase: int) -> void:
	for i in range(int(8.0 * TICK_RATE)):
		game.simulate(TICK)
		if i % 64 == 0:
			await get_tree().process_frame
		if game.phase == phase:
			break


func _steps(game: WoGame, count: int) -> void:
	for i in range(count):
		game.simulate(TICK)
		if i % 64 == 63:
			await get_tree().process_frame
	await get_tree().physics_frame


func _fresh_world(doc: Dictionary) -> WoGame:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := WoConfig.new()
	config.knock_damage_per_speed = 0.0
	config.fall_damage_per_metre = 0.0
	config.courses_per_round = 1
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray([str(doc["id"])])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	game.draw_world = true
	add_child(game)
	game.set_physics_process(false)
	_world = game
	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return
	_failed += 1
	var line := "%s: %s%s" % [_world.config.course_ids[0] if _world != null else "?", what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
