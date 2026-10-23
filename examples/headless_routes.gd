extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Can a runner get from the start to the finish of an io course? A floor-flood walker (1 m cells, step 1 m,
## jump 5 m, ladders as lifts) is driven to a fixed point with the map's io graph run for real: triggers and
## buttons the cells reach fire, doors latch open, rides join their poses, teleports are edges.
##
## Cell counts differ between machines (waytobar 1182/8307 on one box, 1199/8169 on another) while the pinned results agree, so only the finish and dead_tps are asserted. Measured 2026-10-23: the finish is reached on pauls (by "model": a fall past a hole under an overhang); the other
## courses stall at walls, doors or Source logic (logic_*, timed doors) the model lacks. The plan pins that picture
## (`dead_tps`: teleport volumes no route reaches); a change fails the suite so somebody looks.
##
## Plan keys: `reaches` and `why` (documentation: whether the walk ends in the finish zone, and the diagnosis), `min_cells` (floor found from the start, default 50), `finish` ("walk", "tp" or "none"),
## `hurt_only`, `dead_tps`. `debug` ("map", "ents") prints the walk for one course.

const COURSES := {
	&"wo_oaks_course": {"dead_tps": 0, "reaches": false,
		"why": "verified: past the start door (opens by the shoot chain) lies a 12 m flat pit, over twice the pinned jump (about 6 m); no push, teleport, ladder or mover reaches it, and every output target resolves (Rompje are three 0.3 m blocks at the far lip). Not verified: whether the source route needs a bhop the game does not allow, or a piece the importer dropped"},
	&"wo_office_course": {"dead_tps": 5, "reaches": false, "why": "stalls 55 m out at buttons and trigger_once doors; five teleports unreached; Source logic missing from the model"},
	&"wo_dans_course": {"dead_tps": 3, "reaches": false, "why": "stalls 96 m out behind a touch door (hamwallet); three teleports unreached"},
	&"wo_pauls_course": {"dead_tps": 5, "min_cells": 1, "finish": "model", "reaches": true, "why": "reached by the model: a fall past a hole under an overhang"},
	&"wo_scary_course": {"dead_tps": 0, "reaches": false, "why": "stalls 41 m out; the next triggers are trigger_multiple scripts the walk cannot fire from the floor"},
	&"wo_lego_course": {"dead_tps": 0, "reaches": false, "why": "stalls 95 m out; trigger_once chains (low*) are out of reach of the floor walk"},
	&"wo_dc_course": {"dead_tps": 3, "reaches": false, "why": "stalls 233 m out; three teleports and a bonus teleport unreached"},
	&"wo_waytobar_course": {"dead_tps": 3, "reaches": false, "why": "verified: the walk ends 0.76 m in front of a glass wall (z 19.29) that is the 1000-damage score slab; the finish box lies 0.3 m behind it (z 15.9 to 18.9), on the far side, so no walk can enter it. Not verified: whether the box belongs on the approach side (the bar is reachable from the start by floor, with the walker's doors latched open)"},
	&"wo_labo_course": {"dead_tps": 3, "reaches": false, "why": "stalls 106 m out; three teleports unreached"},
	&"wo_sweet_course": {"dead_tps": 4, "reaches": false, "why": "stalls 223 m out; four teleports unreached"},
}
const CHECKS_PER_COURSE := 6
const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
const CELL := 1.0
const MAX_CELLS := 70000
const RELAXED_GAP := 10
## The pinned profile's jump is WoConfig.jump_height (1.25 m); a 56-unit block is 1.07 m and was out of reach at 1.0.
const STEP_UP := 1.2
const RELAXED_UP := 1.6
const RELAXED_DROP := 30.0
const DIRS := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
	Vector2(0.7071, 0.7071), Vector2(-0.7071, 0.7071), Vector2(0.7071, -0.7071), Vector2(-0.7071, -0.7071)]

var _passed := 0
var _failed := 0
var _entered := 0
var _finished_count := 0
var _failures := PackedStringArray()
var _world: WoGame = null
var _expected_sections := 0
var _debug := ""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: can a runner reach the finish of each io course")
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var summary: Array[String] = []
	var only := ""
	var forced_debug := ""
	# a scratch file `examples/headless_routes.only` ("course,course debug") picks courses when game.sh cannot pass arguments
	if FileAccess.file_exists("res://examples/headless_routes.only"):
		var parts := FileAccess.get_file_as_string("res://examples/headless_routes.only").strip_edges().split(" ")
		only = parts[0]
		forced_debug = parts[1] if parts.size() > 1 else ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			only = a.substr(9)
		elif a.begins_with("--debug="):
			forced_debug = a.substr(8)

	for id: StringName in COURSES:
		if only != "" and not (id in only.split(",")):
			continue
		if not catalogue.courses.has(id):
			print("(%s is not installed: no mg-wipeout-maps link, nothing to check)" % id)
			continue

		_expected_sections += 1
		print("== %s" % id)
		var plan: Dictionary = (COURSES[id] as Dictionary).duplicate()
		if forced_debug != "":
			plan["debug"] = forced_debug
		summary.append(await _course(catalogue.courses[id], id, plan))

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
	if only == "" and _passed + _failed != _expected_sections * CHECKS_PER_COURSE:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, _expected_sections * CHECKS_PER_COURSE])
		code = 1
	get_tree().quit(code)


func _course(doc: Dictionary, id: StringName, plan: Dictionary) -> String:
	_entered += 1
	_debug = str(plan.get("debug", ""))
	var ctx := await _setup(doc)
	var walker: _Walker = ctx["walker"]
	var start: Vector3 = ctx["start"]
	var tps: Array = ctx["tps"]
	var finish: AABB = ctx["finish"]
	_check(ctx["world"] != null, "dot-map built the world")

	# the floor alone, then the machinery on the map's own io graph (this world), then the machinery again on a fresh world
	# that never crosses a live hurt volume.
	var a := walker.flood(start, finish, [], [])
	var b := await _model(ctx, false)
	var hurts_in_the_way: bool = false
	var c_cells: int = b["cells"]
	if b["finish"]:
		var ctx2 := await _setup(doc)
		var c := await _model(ctx2, true)
		hurts_in_the_way = not c["finish"]
		c_cells = c["cells"]
		print("    avoid-hurts walk hash %d" % c["hash"])

	var dead := 0
	var gated := 0
	var names: Array[String] = []
	for i in tps.size():
		if not b["tp_hit"][i]:
			dead += 1
			names.append("%s->%s" % [tps[i]["node"].volume.targetname, tps[i]["to"]])
		elif tps[i]["gate"]:
			gated += 1

	var finish_how := "walk" if a["finish"] else ("model" if b["finish"] else "none")
	var line := "%s: finish %s%s; cells %d/%d/%d%s; teleports %d, unreached %d, gated %d, hurt volumes %d%s" % [
		id, finish_how, " (BLOCKED by a hurt volume on every route)" if hurts_in_the_way else "",
		a["cells"], b["cells"], c_cells, " (capped)" if a["capped"] or b["capped"] else "",
		tps.size(), dead, gated, (ctx["hurts"] as Array).size(), " [%s]" % ", ".join(names) if dead > 0 else ""]
	print("  " + line)
	print("    route: " + str(b["route"]))
	print("    walk hash %d" % b["hash"])
	print("    with a %d m jump, a %.1f m step and a %.0f m drop the machinery walk %s (%d cells, nearest %.1f m)" % [RELAXED_GAP, RELAXED_UP, RELAXED_DROP, "FINISHES" if b["relaxed"] else "still does not finish", b["relaxed_cells"], b["relaxed_nearest"]])
	if not b["finish"]:
		print("    blocked: nearest cell %.1f m from the finish at %s; nearest things nobody reached: %s" % [b["nearest"], b["near_at"], b["unfired"]])

	_check(a["cells"] >= int(plan.get("min_cells", 50)), "the runner starts on floor the walker can cross", "%d cells from %s" % [a["cells"], start])
	_check(b["cells"] >= a["cells"], "machinery and teleports only add floor", "%d vs %d" % [b["cells"], a["cells"]])
	_check(finish_how == plan.get("finish", "none"), "the finish is reached by: %s" % plan.get("finish", "none"), finish_how)
	_check(hurts_in_the_way == plan.get("hurt_only", false), "a live hurt volume %s the only way" % ("is on" if plan.get("hurt_only", false) else "is not on"), str(hurts_in_the_way))
	_check(dead == int(plan.get("dead_tps", 0)), "teleport volumes no route reaches: %d" % int(plan.get("dead_tps", 0)), "%d %s" % [dead, str(names)])
	_finished_count += 1
	return line


## A fresh world for [param doc], its runner's start, the teleports and hurt volumes and a walker over its physics.
func _setup(doc: Dictionary) -> Dictionary:
	var game := await _fresh_world(doc)
	var runner := game.add_player(&"u1", "Runner")
	game.start()
	await _until(game, WoGame.Phase.COURSE)
	var world: DotMapWorld = game.stage.io.world

	# A start-line teleport moves everybody on the first ticks: the start is where the runner is after them.
	await _steps(game, TICK_RATE)
	await _steps(game, 8)
	var start := runner.controller.state.position
	var spawns := game.stage.io_spawns()
	# A runner a start teleport dropped below the water, or onto a single cell of floor, is seeded from the map's first spawn point instead.
	var isolated := false
	if not spawns.is_empty():
		var probe := _Walker.new(game.get_world_3d().direct_space_state, float(doc["water_height"]), world.ladder_boxes())
		isolated = probe.flood(start, _finish_box(doc), [], [])["cells"] < 20
	if (start.y <= float(doc["water_height"]) + 0.5 or isolated) and not spawns.is_empty():
		start = spawns[0]["origin"]
		var hit := game.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(start + Vector3(0, 0.5, 0), start - Vector3(0, 6, 0)))
		if not hit.is_empty():
			start = hit["position"]
	var water := float(doc["water_height"])
	if _debug != "":
		print("    DEBUG setup: runner %s doc start %s water %s spawns %s" % [start, doc["start"], water, spawns.slice(0, 3)])
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
				"gate": not node.active(), "open_fn": func() -> bool: return node.active() and node._filter_passes(world.io, body)})
		elif v.kind == "hurt" and node.active() and float(v.record.get("damage", 0.0)) > 0.0:
			for box: AABB in v.brush_boxes():
				if box.size.is_finite() and box.size.y > 0.1:
					hurts.append(box)

	return {"game": game, "world": world, "start": start, "tps": tps, "hurts": hurts, "space": space, "body": body,
		"finish": _finish_box(doc), "walker": _Walker.new(space, water, world.ladder_boxes())}


## Walks to a fixed point: flood, set off what the cells reached can, run the clock, flood again from every cell found so far.
func _model(ctx: Dictionary, avoid_hurts: bool) -> Dictionary:
	var tree := get_tree()
	var walker: _Walker = ctx["walker"]
	var world: DotMapWorld = ctx["world"]
	var start: Vector3 = ctx["start"]
	var tps: Array = ctx["tps"]
	var finish: AABB = ctx["finish"]
	var hurts: Array = ctx["hurts"] if avoid_hurts else []
	var m := _Model.new(world, ctx["body"], ctx["space"])
	if _debug.begins_with("ents"):
		var list: Array = []
		for e: DotMapEntity in world.io.entities:
			if e.classname in ["func_button", "func_door", "func_movelinear", "func_tracktrain", "func_plat", "trigger_teleport", "func_rotating", "func_door_rotating", "prop_door_rotating"] or e is DotMapTrigger:
				var o := e.origin(world.io)
				if e is DotMapMoverNode and (e as DotMapMoverNode).hit_half != Vector3.ZERO:
					o = (e as DotMapMoverNode).hit_frame.origin
				var outs := PackedStringArray()
				for l: Dictionary in e.links:
					outs.append("%s>%s.%s" % [l["output"], l["target"], l["input"]])
				list.append([o.distance_to(start), "%s %s%s at %s spawnflags %s locked %s -> %s" % [e.classname, e.targetname, "#%d" % e.index, o, e.key("spawnflags"), e.key("spawnflags"), ", ".join(outs).left(160)]])
		list.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
		print("    DEBUG start %s finish %s" % [start, finish])
		for it in list.slice(0, 40):
			print("    DEBUG ent %.0f m: %s" % [it[0], it[1]])
	var seeds: Array[Vector3] = []
	var res: Dictionary = {}
	var prev := -1
	var prev_rides := -1
	var quiet := 0
	var told := {}
	for _round in 40:
		res = walker.flood(start, finish, tps, hurts, seeds)
		m.reached = res["queue"]
		for i in tps.size():
			if res["tp_hit"][i] and not told.has(i):
				told[i] = true
				m.log.append("teleport %s" % [(tps[i]["node"].volume.targetname if tps[i]["node"].volume.targetname != "" else "#%d" % i)])
		seeds = []
		seeds.append_array(res["queue"])
		seeds.append_array(m.ride_cells)
		var n := m.fire(m.reached)
		m.advance(_Model.BATCH_SECONDS)
		walker.falls.clear()
		# the movers are animatable bodies: the physics server takes their pose on its next frames
		await tree.physics_frame
		await tree.physics_frame
		if n == 0 and res["cells"] == prev and m.ride_cells.size() == prev_rides:
			quiet += 1
			if quiet >= 3:
				break
		else:
			quiet = 0
		prev = res["cells"]
		prev_rides = m.ride_cells.size()
	await tree.physics_frame
	res = walker.flood(start, finish, tps, hurts, seeds)
	if _debug != "":
		var f := finish.get_center()
		var q: Array[Vector3] = res["queue"]
		q.sort_custom(func(x: Vector3, y: Vector3) -> bool: return x.distance_to(f) < y.distance_to(f))
		if _debug == "map":
			var lo := Vector3(INF, INF, INF)
			var hi := -lo
			for c in q:
				lo = lo.min(c)
				hi = hi.max(c)
			var have := {}
			for c in q:
				have[Vector2i(floori(c.x / 2.0), floori(c.z / 2.0))] = true
			var space := walker.space
			print("    DEBUG map x %d..%d z %d..%d (2 m), y %.1f..%.1f, finish %s" % [lo.x - 20, hi.x + 20, lo.z - 20, hi.z + 20, lo.y, hi.y, finish.get_center()])
			var z := lo.z - 20.0
			while z < hi.z + 20.0:
				var row := ""
				var x := lo.x - 20.0
				while x < hi.x + 20.0:
					var ch := " "
					if have.has(Vector2i(floori(x / 2.0), floori(z / 2.0))):
						ch = "#"
					else:
						var hq := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, hi.y + 25.0, z), Vector3(x, lo.y - 25.0, z)))
						if not hq.is_empty():
							ch = "." if (hq["normal"] as Vector3).y > 0.7 else "|"
					row += ch
					x += 2.0
				print("    DEBUG " + row)
				z += 2.0
		for i in mini(3, q.size()):
			print("    DEBUG frontier %s -> %s" % [q[i], walker.why(q[i], f)])
		_unreached_report(walker, q, q[0] if not q.is_empty() else start, finish)
		if _debug.begins_with("slice:"):
			_slice(walker, q, _debug.substr(6).split(","))
		if _debug.begins_with("ray:"):
			_ray(walker, _debug.substr(4).split(","))
		if _debug == "toggles":
			for e: DotMapEntity in world.io.entities:
				if e is DotMapToggleBrush and e.node != null:
					var lo2 := Vector3(INF, INF, INF)
					var hi2 := -lo2
					for cs in e.node.find_children("*", "CollisionShape3D", true, false):
						var sh := (cs as CollisionShape3D).shape
						if sh != null:
							var bb := (cs as CollisionShape3D).global_transform * sh.get_debug_mesh().get_aabb()
							lo2 = lo2.min(bb.position)
							hi2 = hi2.max(bb.end)
					print("    DEBUG toggle %s#%d enabled %s solid %s box %s..%s" % [e.targetname, e.index, e.enabled, (e as DotMapToggleBrush).is_solid(), lo2.snappedf(0.1), hi2.snappedf(0.1)])
	# what a longer jump and a taller step (bhop-style air control) would add, measured on the final state of the world
	walker.max_gap = RELAXED_GAP
	walker.max_up = RELAXED_UP
	walker.max_drop = RELAXED_DROP
	var relaxed := walker.flood(start, finish, tps, hurts, seeds)
	walker.max_gap = 5
	walker.max_up = STEP_UP
	walker.max_drop = 8.0
	res["relaxed"] = relaxed["finish"]
	res["relaxed_nearest"] = relaxed["nearest"]
	res["relaxed_cells"] = relaxed["cells"]
	res["route"] = m.log.slice(0, 14) if m.log.size() <= 14 else m.log.slice(0, 14) + ["... %d more" % (m.log.size() - 14)]
	res["unfired"] = m.nearest_unfired(res["near_at"])
	var keys: Array = []
	for c: Vector3 in res["queue"]:
		keys.append(walker._key(c))
	keys.sort()
	res["hash"] = str(keys).hash()
	return res


## Debug: standing spots on a 2 m grid that no cell reached, nearest to the frontier and nearest to the finish.
func _unreached_report(walker: _Walker, reached: Array[Vector3], frontier: Vector3, finish: AABB) -> void:
	var have := {}
	for c in reached:
		var k := Vector2i(roundi(c.x / 2.0), roundi(c.z / 2.0))
		if not have.has(k):
			have[k] = []
		(have[k] as Array).append(c.y)
	var lo := finish.get_center().min(frontier) - Vector3(60, 0, 60)
	var hi := finish.get_center().max(frontier) + Vector3(60, 0, 60)
	for c in reached:
		lo = lo.min(c - Vector3(30, 0, 30))
		hi = hi.max(c + Vector3(30, 0, 30))
	var spots: Array[Vector3] = []
	var x := lo.x
	while x < hi.x:
		var z := lo.z
		while z < hi.z:
			var top := 400.0
			for _i in 12:
				var hit := walker.space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -400.0, z)))
				if hit.is_empty():
					break
				var p: Vector3 = hit["position"]
				top = p.y - 0.3
				if (hit["normal"] as Vector3).y < 0.7 or p.y <= walker.water:
					continue
				var seen := false
				for dx in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						for y: float in have.get(Vector2i(roundi(x / 2.0) + dx, roundi(z / 2.0) + dz), []):
							if absf(y - p.y) < 1.6:
								seen = true
				if not seen:
					var sq := PhysicsShapeQueryParameters3D.new()
					sq.shape = walker._probe
					sq.transform = Transform3D(Basis.IDENTITY, p + Vector3(0, 0.75, 0))
					if walker.space.intersect_shape(sq, 1).is_empty():
						spots.append(p)
			z += 2.0
		x += 2.0
	print("    DEBUG %d unreached standing spots on the grid" % spots.size())
	var bins := {}
	for c in reached:
		var bk := Vector3i(floori(c.x / 6.0), floori(c.y / 6.0), floori(c.z / 6.0))
		if not bins.has(bk):
			bins[bk] = []
		(bins[bk] as Array).append(c)
	var pairs: Array = []
	for sp in spots:
		var bk := Vector3i(floori(sp.x / 6.0), floori(sp.y / 6.0), floori(sp.z / 6.0))
		var best := INF
		var from := Vector3.ZERO
		for ox in [-1, 0, 1]:
			for oy in [-1, 0, 1]:
				for oz in [-1, 0, 1]:
					for c: Vector3 in bins.get(bk + Vector3i(ox, oy, oz), []):
						var d := c.distance_to(sp)
						if d < best:
							best = d
							from = c
		if best < INF:
			pairs.append([best, from, sp])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var shown := {}
	var lines := 0
	for pr: Array in pairs:
		var kk := Vector3i(roundi((pr[1] as Vector3).x / 4.0), roundi((pr[1] as Vector3).y / 4.0), roundi((pr[1] as Vector3).z / 4.0))
		if shown.has(kk):
			continue
		shown[kk] = true
		var f2: Vector3 = pr[1]
		var t2: Vector3 = pr[2]
		print("    DEBUG gap: from (%.0f,%.1f,%.0f) to unreached (%.0f,%.1f,%.0f): across %.1f m, up %+.1f m" % [f2.x, f2.y, f2.z, t2.x, t2.y, t2.z, Vector2(t2.x - f2.x, t2.z - f2.z).length(), t2.y - f2.y])
		lines += 1
		if lines >= 14:
			break
	for ref: Vector3 in [frontier, finish.get_center()]:
		var sorted := spots.duplicate()
		sorted.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(ref) < b.distance_to(ref))
		var out := PackedStringArray()
		for i in mini(8, sorted.size()):
			var v: Vector3 = sorted[i]
			out.append("(%.0f,%.1f,%.0f) %.1f m" % [v.x, v.y, v.z, v.distance_to(ref)])
		print("    DEBUG nearest unreached floor to %s: %s" % [ref.snappedf(0.1), " | ".join(out)])


## Debug: every collider along a segment, `x1,y1,z1,x2,y2,z2`: its path, class and the entry point.
func _ray(walker: _Walker, a: PackedStringArray) -> void:
	var from := Vector3(float(a[0]), float(a[1]), float(a[2]))
	var to := Vector3(float(a[3]), float(a[4]), float(a[5]))
	var skip: Array[RID] = []
	for _i in 12:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = skip
		var hit := walker.space.intersect_ray(q)
		if hit.is_empty():
			break
		var c := hit["collider"] as Node
		print("    DEBUG ray hit %s (%s) at %s normal %s layer %d" % [c.get_path(), c.get_class(), hit["position"], hit["normal"], (c as CollisionObject3D).collision_layer])
		skip.append(hit["rid"])

## Debug: a vertical slice of the physics world along a line, `x1,z1,x2,z2,y_low,y_high[,step]`; # solid, + a reached cell.
func _slice(walker: _Walker, reached: Array[Vector3], a: PackedStringArray) -> void:
	var p1 := Vector3(float(a[0]), 0, float(a[1]))
	var p2 := Vector3(float(a[2]), 0, float(a[3]))
	var y0 := float(a[4])
	var y1 := float(a[5])
	var step := float(a[6]) if a.size() > 6 else 0.5
	var probe := SphereShape3D.new()
	probe.radius = step * 0.45
	var length := p1.distance_to(p2)
	print("    DEBUG slice from (%.1f,%.1f) to (%.1f,%.1f), y %.1f..%.1f, %.2f m a character" % [p1.x, p1.z, p2.x, p2.z, y0, y1, step])
	var y := y1
	while y >= y0:
		var row := ""
		var d := 0.0
		while d <= length:
			var at := p1.lerp(p2, d / length)
			var ch := " "
			var sq := PhysicsShapeQueryParameters3D.new()
			sq.shape = probe
			sq.transform = Transform3D(Basis.IDENTITY, Vector3(at.x, y, at.z))
			if not walker.space.intersect_shape(sq, 1).is_empty():
				ch = "#"
			for c in reached:
				if absf(c.y - (y - step * 0.5)) < step * 0.5 and Vector2(c.x - at.x, c.z - at.z).length() < step * 0.7:
					ch = "+"
					break
			row += ch
			d += step
		print("    DEBUG %6.2f %s" % [y, row])
		y -= step


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
	var max_gap := 5
	var max_up := 1.2
	var max_drop := 8.0
	## Landings per hole, dropped whenever the machinery changes the world.
	var falls := {}
	const FALL_DRIFT := 0.4
	const FALL_STEP := 1.5
	const FALL_MAX := 30.0

	func _init(s: PhysicsDirectSpaceState3D, w: float, l: Array[AABB]) -> void:
		space = s
		water = w
		ladders = l
		_probe.radius = 0.35

	func _free(c: Vector3) -> bool:
		var sq := PhysicsShapeQueryParameters3D.new()
		sq.shape = _probe
		sq.transform = Transform3D(Basis.IDENTITY, c)
		return space.intersect_shape(sq, 1).is_empty()

	## Where a body that steps into the open air at [param at] (feet) can land: free air below it on a coarse grid, drifting
	## sideways up to [constant FALL_DRIFT] of the depth fallen, so floors under an overhang count.
	func _fall(at: Vector3, from_y: float) -> Array[Vector3]:
		var lands: Array[Vector3] = []
		var start := Vector3(at.x, at.y + 0.75, at.z)
		if not _free(start) or not _free(start + Vector3(0, -0.5, 0)):
			return lands
		var seen := {Vector3i.ZERO: true}
		var queue: Array[Vector3] = [start]
		var head := 0
		while head < queue.size() and queue.size() < 1500:
			var c := queue[head]
			head += 1
			var depth := start.y - c.y
			if depth > 1.0:
				var f: Variant = _floor(c.x, c.z, c.y, 2.25)
				if f != null and (f as Vector3).y < from_y - 1.0:
					lands.append(f)
					continue
			if c.y - 0.75 <= water or depth > FALL_MAX:
				continue
			var budget := minf(FALL_DRIFT * depth + 1.5, 8.0)
			var nexts: Array[Vector3] = [c + Vector3(0, -FALL_STEP, 0)]
			for d: Vector2 in DIRS:
				nexts.append(c + Vector3(d.x, 0, d.y) * FALL_STEP)
			for n in nexts:
				var k := Vector3i(roundi((n.x - start.x) / FALL_STEP), roundi((n.y - start.y) / FALL_STEP), roundi((n.z - start.z) / FALL_STEP))
				if seen.has(k) or Vector2(n.x - start.x, n.z - start.z).length() > budget:
					continue
				seen[k] = true
				if _free(n):
					queue.append(n)
		return lands

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

	func why(p: Vector3, toward: Vector3) -> String:
		var out := PackedStringArray()
		var dir := Vector3(toward.x - p.x, 0, toward.z - p.z).normalized()
		for d in [1, 2, 3, 4]:
			var x: float = p.x + dir.x * d
			var z: float = p.z + dir.z * d
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, p.y + 1.1, z), Vector3(x, p.y - 7.0, z))
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				out.append("d%d none" % d)
				continue
			var hp: Vector3 = hit["position"]
			var sq := PhysicsShapeQueryParameters3D.new()
			sq.shape = _probe
			sq.transform = Transform3D(Basis.IDENTITY, hp + Vector3(0, 0.75, 0))
			out.append("d%d y%+.2f n%.2f water%s room%s blocked%s %s" % [d, hp.y - p.y, (hit["normal"] as Vector3).y, hp.y <= water, space.intersect_shape(sq, 1).is_empty(), _blocked(p, hp), (hit["collider"] as Node).get_parent().name])
		return " | ".join(out)

	func _blocked(a: Vector3, b: Vector3) -> bool:
		# Both ends at the higher floor's chest height: a block taller than 0.6 m is a jump up, not a wall.
		var h := maxf(a.y, b.y) + 0.6
		var q := PhysicsRayQueryParameters3D.create(Vector3(a.x, h, a.z), Vector3(b.x, h, b.z))
		return not space.intersect_ray(q).is_empty()

	func flood(start: Vector3, finish: AABB, tps: Array, hurts: Array, seeds: Array = []) -> Dictionary:
		var seen := {}
		var queue: Array[Vector3] = [start]
		var tp_hit: Array = []
		for _t in tps:
			tp_hit.append(false)
		seen[_key(start)] = true
		for sd: Vector3 in seeds:
			if not seen.has(_key(sd)):
				seen[_key(sd)] = true
				queue.append(sd)
		var reached := false
		var nearest := INF
		var near_at := start
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
			var dist := finish.get_center().distance_to(p)
			if dist < nearest:
				nearest = dist
				near_at = p

			var found: Array[Vector3] = []
			for dir: Vector2 in DIRS:
				for d: int in range(1, max_gap + 1):
					var x: float = p.x + dir.x * d * CELL
					var z: float = p.z + dir.y * d * CELL
					var up := max_up
					var f: Variant = _floor(x, z, p.y + up + 0.1, up + max_drop)
					if f == null:
						continue
					var n: Vector3 = f
					if n.y - p.y > up + 0.05 or _blocked(p, n):
						continue
					found.append(n)
					if d == 1:
						break

			# A hole beside the cell: step off and fall, steering in the air under whatever overhangs the shaft.
			for dir: Vector2 in DIRS.slice(0, 4):
				var fx: float = p.x + dir.x * CELL
				var fz: float = p.z + dir.y * CELL
				if _floor(fx, fz, p.y + max_up + 0.1, max_up + max_drop) != null:
					continue
				var hole := Vector3i(roundi(fx / 2.0), roundi(p.y / 2.0), roundi(fz / 2.0))
				if not falls.has(hole):
					falls[hole] = _fall(Vector3(fx, p.y, fz), p.y)
				found.append_array(falls[hole])

			for ladder in ladders:
				if ladder.grow(0.9).intersects(body):
					for off in [Vector2(1.2, 0), Vector2(-1.2, 0), Vector2(0, 1.2), Vector2(0, -1.2)]:
						var c := ladder.get_center()
						var f: Variant = _floor(c.x + off.x, c.z + off.y, ladder.end.y + 1.2, 3.0)
						if f != null and (f as Vector3).y > p.y:
							found.append(f)

			for i in tps.size():
				var t: Dictionary = tps[i]
				if not (t["open_fn"] as Callable).call():
					continue
				for box: AABB in t["boxes"]:
					# a 0.25 m trigger plane falls between 1 m cells, so pad each axis to a cell
					var pad := Vector3(maxf(box.size.x, CELL), maxf(box.size.y, CELL), maxf(box.size.z, CELL))
					if AABB(box.get_center() - pad * 0.5, pad).grow(0.2).intersects(body):
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

		return {"finish": reached, "cells": queue.size(), "capped": capped, "tp_hit": tp_hit, "nearest": nearest, "queue": queue,
			"near_at": near_at}


## The machinery of a world, run for real on the map's own io graph: what a runner standing on the cells found so far can
## set off (a trigger it walks into, a button or door it can use), the doors that then stand open (latched open: the walk
## goes through them whenever they close again), and the rides (a lift, a train, a mover): wherever a reached cell meets
## one, the cells on its top, in every pose it takes, join the walk. The io clock is advanced here, the runner is never
## moved, and the teleports are the walker's own edges (a teleport volume is never fired).
class _Model:
	const SAMPLE_TICKS := 16
	const BATCH_SECONDS := 10.0
	const DOOR_CLASSES := ["func_door", "func_door_rotating", "prop_door_rotating", "func_button", "func_rot_button"]
	const USE_REACH := 2.2
	const SHOOT_REACH := 30.0

	var io: DotMapIO
	var world: DotMapWorld
	var info: Dictionary
	var fired := {}
	var latched := {}
	var ride_cells: Array[Vector3] = []
	var ride_seen := {}
	var log: Array[String] = []
	var rides_met := {}
	var space: PhysicsDirectSpaceState3D
	var reached: Array[Vector3] = []
	var _movers: Array = []

	func _init(w: DotMapWorld, body_info: Dictionary, s: PhysicsDirectSpaceState3D) -> void:
		world = w
		io = w.io
		info = body_info
		space = s
		for e: DotMapEntity in io.entities:
			if e is DotMapMoverNode and (e as DotMapMoverNode).mover != null and e.node != null:
				_movers.append(e)
				# a synced body takes its pose on the physics step, which the walk's rays do not wait for
				for b in e.node.find_children("*", "AnimatableBody3D", true, false):
					(b as AnimatableBody3D).sync_to_physics = false

	func _info_at(p: Vector3) -> Dictionary:
		var i := info.duplicate()
		i["position"] = p
		return i

	func _label(e: DotMapEntity) -> String:
		return "%s%s" % [e.classname, "(" + e.targetname + ")" if e.targetname != "" else "#%d" % e.index]

	## The mover's hit box in the world, now.
	func _box(m: DotMapMoverNode) -> Transform3D:
		return m.pose_delta(io.now, io.rate) * m.hit_frame

	func _door_like(m: DotMapMoverNode) -> bool:
		return m.mover.kind != DotMapMover.KIND_PATH and m.mover.kind != DotMapMover.KIND_SPIN and m.classname.to_lower() in DOOR_CLASSES

	## Sets off what a body standing on any of [param cells] can; returns how many things went.
	func fire(cells: Array[Vector3]) -> int:
		var n := 0
		var bodies: Array[AABB] = []
		for p in cells:
			bodies.append(AABB(p + Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 1.8, 0.6)))
		for vn: DotMapVolumeNode in world.volumes.nodes:
			if fired.has(vn) or not vn.active() or vn.volume.kind not in ["multiple", "once"]:
				continue
			var boxes := vn.volume.brush_boxes()
			var at := -1
			for i in cells.size():
				var cb := bodies[i]
				var hit := false
				for box: AABB in boxes:
					if box.size.is_finite() and box.grow(0.1).intersects(cb):
						hit = true
						break
				if hit:
					var inf := _info_at(cells[i])
					if vn._admits(io, inf) and vn._touches(inf):
						at = i
						break
			if at < 0:
				continue
			fired[vn] = true
			n += 1
			log.append("walk into %s at (%.0f,%.0f,%.0f)" % [_label(vn.entity) if vn.entity != null else vn.volume.targetname, cells[at].x, cells[at].y, cells[at].z])
			vn._enter(io, _info_at(cells[at]))
			io._settle()
		for m: DotMapMoverNode in _movers:
			if fired.has(m) or not (m.mover.use or m.mover.touch) or m.hit_half == Vector3.ZERO or not m.alive:
				continue
			var inv := _box(m).affine_inverse()
			var at := -1
			for i in cells.size():
				var d := _dist_to_box(inv * (cells[i] + Vector3(0, 1.4, 0)), m.hit_half)
				if d <= (USE_REACH if m.mover.use else 0.6):
					at = i
					break
			if at < 0:
				continue
			var inf := _info_at(cells[at])
			if m.locked:
				continue
			if m.touched(io, inf, m.mover.use):
				fired[m] = true
				n += 1
				log.append("%s %s from (%.0f,%.0f,%.0f)" % ["use" if m.mover.use else "touch", _label(m), cells[at].x, cells[at].y, cells[at].z])
				io._settle()
		# a shot: a button that fires OnDamaged or is flagged damage-activated, a breakable that has outputs; from any cell that sees it
		for e: DotMapEntity in io.entities:
			if fired.has(e) or not e.alive or e.node == null:
				continue
			var shootable := false
			if e is DotMapMoverNode and (e as DotMapMoverNode).mover != null and (e as DotMapMoverNode).mover.kind.ends_with("button"):
				shootable = e.has_spawnflag(512) or e.links.any(func(l: Dictionary) -> bool: return str(l["output"]) == "ondamaged")
			elif e is DotMapBreakable:
				shootable = not e.links.is_empty() and (e as DotMapBreakable).health > 0.0 and not (e as DotMapBreakable).broken
			if not shootable:
				continue
			var target := _centre(e)
			for p in cells:
				var eye := p + Vector3(0, 1.6, 0)
				if eye.distance_to(target) > SHOOT_REACH:
					continue
				var q := PhysicsRayQueryParameters3D.create(eye, target)
				var hit := space.intersect_ray(q)
				if hit.is_empty() or e.node.is_ancestor_of(hit["collider"] as Node) or (hit["position"] as Vector3).distance_to(target) < 0.7:
					fired[e] = true
					n += 1
					log.append("shoot %s from (%.0f,%.0f,%.0f)" % [_label(e), p.x, p.y, p.z])
					io.hurt(e.index, 100.0, target, info)
					break
		return n

	func _centre(e: DotMapEntity) -> Vector3:
		if e is DotMapMoverNode and (e as DotMapMoverNode).hit_half != Vector3.ZERO:
			return _box(e as DotMapMoverNode).origin
		return e.node.global_position

	## The few things nobody reached that lie closest to [param p]: a trigger or a button the walk never got to.
	func nearest_unfired(p: Vector3) -> Array[String]:
		var found: Array = []
		for vn: DotMapVolumeNode in world.volumes.nodes:
			if not fired.has(vn) and vn.volume.kind in ["multiple", "once"]:
				var bs := vn.volume.brush_boxes()
				if not bs.is_empty() and (bs[0] as AABB).size.is_finite():
					found.append([(bs[0] as AABB).get_center().distance_to(p), "trigger %s" % (_label(vn.entity) if vn.entity != null else vn.volume.targetname)])
		for mv: DotMapMoverNode in _movers:
			if not fired.has(mv) and (mv.mover.use or mv.mover.touch) and mv.hit_half != Vector3.ZERO:
				found.append([_box(mv).origin.distance_to(p), "%s %s" % ["use" if mv.mover.use else "touch", _label(mv)]])
		found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
		var out: Array[String] = []
		for i in mini(4, found.size()):
			out.append("%s %.0f m" % [found[i][1], found[i][0]])
		return out

	static func _dist_to_box(q: Vector3, half: Vector3) -> float:
		var out := Vector3(maxf(absf(q.x) - half.x, 0.0), maxf(absf(q.y) - half.y, 0.0), maxf(absf(q.z) - half.z, 0.0))
		return out.length()

	## Runs the io clock; samples the rides and holds opened doors open.
	func advance(seconds: float) -> void:
		sample()
		var ticks := int(seconds * io.rate)
		for t in ticks:
			io.advance(1)
			_hold()
			if t % SAMPLE_TICKS == SAMPLE_TICKS - 1:
				sample()

	func _hold() -> void:
		for m: DotMapMoverNode in latched:
			m.node.transform = latched[m]

	func sample() -> void:
		for m: DotMapMoverNode in _movers:
			if m.node == null or not m.alive:
				continue
			if _door_like(m):
				if not latched.has(m) and m._to >= 1.0 and not m.mover.kind.ends_with("button"):
					var t := m.mover.transform_at(1.0, m._side)
					latched[m] = Transform3D(t.basis * m._base.basis, m._base.origin + t.origin)
					log.append("%s opens" % _label(m))
				continue
			if m.hit_half == Vector3.ZERO:
				continue
			var xf := _box(m)
			var box := xf * AABB(-m.hit_half, m.hit_half * 2.0)
			var around := AABB(box.position - Vector3(1.5, 1.8, 1.5), box.size + Vector3(3.0, 1.8 + 0.8 + 1.8, 3.0))
			var boarded := rides_met.has(m)
			if not boarded:
				for p in reached:
					if around.has_point(p + Vector3(0, 0.5, 0)):
						boarded = true
						rides_met[m] = true
						log.append("meets %s at (%.0f,%.0f,%.0f)" % [_label(m), p.x, p.y, p.z])
						break
			if not boarded:
				continue
			var x := box.position.x + 0.5
			while x < box.end.x:
				var z := box.position.z + 0.5
				while z < box.end.z:
					var p := Vector3(x, box.end.y, z)
					var k := Vector3i(roundi(p.x), roundi(p.y * 2.0), roundi(p.z))
					if not ride_seen.has(k):
						ride_seen[k] = true
						ride_cells.append(p)
					z += 1.0
				x += 1.0


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
