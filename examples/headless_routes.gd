extends "headless_routes_rig.gd"

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Can a runner get from the start to the finish of an io course? A floor-flood walker (1 m cells, step 1 m,
## jump 5 m, ladders as lifts) is driven to a fixed point with the map's io graph run for real.
## Asserted: the finish and `dead_tps` (teleport volumes no route reaches). Plan keys: `reaches`, `why`, `min_cells`, `finish`, `hurt_only`, `debug`.

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
const RELAXED_GAP := 10
## The pinned profile's jump is WoConfig.jump_height (1.25 m); a 56-unit block is 1.07 m and was out of reach at 1.0.
const STEP_UP := 1.2
const RELAXED_UP := 1.6
const RELAXED_DROP := 30.0

var _entered := 0
var _finished_count := 0
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
	_report_sections(_entered, _finished_count, _expected_sections, -1 if only != "" else _expected_sections * CHECKS_PER_COURSE)


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
		_debug_ents(world, start, finish)
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
		_debug_full(walker, world, m, res, start, finish)
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
	var spots := _unreached_spots(walker, reached, frontier, finish)
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


## Debug: the standing spots on a 2 m grid that no reached cell is within reach of.
func _unreached_spots(walker: _Walker, reached: Array[Vector3], frontier: Vector3, finish: AABB) -> Array[Vector3]:
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
	return spots



## Debug: the buttons, doors and triggers nearest the start.
func _debug_ents(world: DotMapWorld, start: Vector3, finish: AABB) -> void:
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


## Debug: the full route, the frontier, a map picture and the extras `_debug` names.
func _debug_full(walker: _Walker, world: DotMapWorld, m: _Model, res: Dictionary, start: Vector3, finish: AABB) -> void:
	print("    DEBUG full route: %s" % [m.log])
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


func _failure_prefix() -> String:
	return "%s: " % (_world.config.course_ids[0] if _world != null else "?")
