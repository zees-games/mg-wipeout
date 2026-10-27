extends DotGameCheckSuite

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Do stand-ins finish the courses that are a map's own world? Each is run with one stand-in, which has no route
## document there and walks a navigation mesh baked from the map's static colliders (WoIoBot, dot-bot's DotBotNav).
##
## Per course, eight checks: the mesh bakes; a path leads from the start; the floor alone leads to the finish
## (`floor`); the stand-in walked a route of its own; it finished (`finish`) or did not, and the plan says why; and
## a finish came inside `limit` seconds; and the stand-in pressed `fired` buttons or triggers and took `taken` teleports on its way (the
## map's own logic that dot-bot's DotBotLinks finds and the stand-in goes to; a count that changes means the way on changed). A course whose way on is the map's own logic (a button, a teleport, a ride)
## cannot be finished from the floor (`route`: steps of the course's `io_route` a person scripted, all of which the stand-in must walk): `why` records the diagnosis and the suite fails when the picture changes, so
## somebody looks. headless_routes finds which teleports and doors a walk can fire.

const COURSES := {
	&"wo_oaks_course": {"floor": false, "finish": false, "limit": 90, "why": "13 m on the floor ends at the pit past the start door; dot-map's nav export lists the start door (SpawnDoorT) with no opener, only the round's own logic moves it, so there is no button to press"},
	&"wo_pauls_course": {"floor": false, "finish": false, "limit": 90, "fired": 3, "taken": 1, "why": "presses three buttons, which enables two teleports, and takes one; it lands on an island 16 m above the finish with no drop edge down, so it stalls short"},
	&"wo_scary_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "fires one trigger but the mesh still ends 47 m out (movers are not in the bake), then the map's AFK_KILLER trigger_hurt kills the idle stand-in once (1 fall; a respawn is protected from the hurt volumes it stands in, see WoGame._protect_from_hurts); no teleport"},
	&"wo_lego_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "fires one trigger but the mesh still ends 96 m out (movers are not in the bake), then the map's 'afk' trigger_hurt kills the idle stand-in once (1 fall, respawn protected); no teleport"},
	&"wo_dc_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 292 m out; two teleports join but the stand-in is killed (3 falls, was 100 before respawn protection) by the 'spawnkill' trigger_hurt around its spawn, not at an edge, before reaching one (a logic_auto enables it 40 s after map spawn as an anti-camp rule, so a stand-in still near the spawn then dies on every respawn; the 'finish' is a row of frag volumes at the far end of a deathmatch map)"},
	&"wo_waytobar_course": {"floor": false, "finish": false, "limit": 90, "why": "hop edges across the start pool (stepping pads 1.9 m wide) join 8 islands to the start, ending 26 m out at the glass slab, a lethal trigger_hurt carved out of the mesh; the six teleports are on islands the pads do not reach, and the AFK_KILLER trigger_hurt kills the stand-in (3 falls, was 121 before respawn protection)"},
	&"wo_dans_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "presses the door button (23) but stalls 96 m out; of three teleports one joins and two lie off the mesh with nothing found to enable them"},
	&"wo_office_course": {"floor": false, "finish": false, "limit": 90, "route": 1, "why": "BLOCKER: the lava-room hurt floor and the timed Spawn_HURT; the stand-in now leaves the spawn room (its Spawn_brush door was solid, see WoCourseIo.reseat_brushes) and walks 70+ m, but never reaches the finish; a death seats it in the lounge, which is inside the finish box (that, not a finish, was the 20 s result)"},
	&"wo_labo_course": {"floor": false, "finish": false, "limit": 90, "fired": 5, "why": "presses five buttons and doors but the mesh still ends 131 m out; the three teleports lie off the mesh and 14 touch doors stand between"},
	&"wo_sweet_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 251 m out; three of five teleports join, one is disabled with no button found, and the stand-in stalls after 27 m"},
}
const CHECKS_PER_COURSE := 8
const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
## Seconds the bake may take before the suite gives up.
const BAKE_WAIT := 90.0

var _entered := 0
var _finished_count := 0
var _world: WoGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: stand-ins on the courses that are a map's own world")
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			only = a.substr(9)

	var expected := 0
	for id: StringName in COURSES:
		if only != "" and not (id in only.split(",")):
			continue
		if not catalogue.courses.has(id):
			print("(%s is not installed: no mg-wipeout-maps link, nothing to check)" % id)
			continue
		expected += 1
		await _course(catalogue.courses[id], id, COURSES[id])

	_report_sections(_entered, _finished_count, expected, expected * CHECKS_PER_COURSE)


func _course(doc: Dictionary, id: StringName, plan: Dictionary) -> void:
	_entered += 1
	print("== %s" % id)
	var game := await _fresh_world(doc)
	var bot := game.add_player(&"u900000", "Bot")
	bot.is_bot = true
	# a person standing still: a round needs one
	var _person := game.add_player(&"u1", "Person")
	game.start()
	await _until(game, WoGame.Phase.COURSE)
	await _steps(game, 2)
	var started := Time.get_ticks_msec()
	var waited := 0.0
	while game._io_bot != null and not game._io_bot.is_ready() and waited < BAKE_WAIT:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var nav: DotBotNav = game._io_bot.nav if game._io_bot != null else null
	_check(nav != null and nav.is_ready(), "the mesh bakes", "%.1f s" % [(Time.get_ticks_msec() - started) / 1000.0])
	if nav == null or not nav.is_ready():
		for i in CHECKS_PER_COURSE - 1:
			_check(false, "needs a mesh")
		_finished_count += 1
		return

	var start := bot.controller.state.position
	var finish: AABB = game.stage.finish_box()
	var path: PackedVector3Array = game._io_bot.path_to(start)
	_check(path.size() > 1, "a path leads from where the stand-in starts", "%d points from %s" % [path.size(), start])
	var floor_reaches: bool = game._io_bot.reaches_finish(start)
	_check(floor_reaches == bool(plan["floor"]), "the floor alone %s the finish" % ("reaches" if plan["floor"] else "does not reach"),
		"path ends %.1f m from it" % [(path[path.size() - 1] if not path.is_empty() else start).distance_to(finish.get_center())])

	print("  links %s" % [game._io_bot.links.describe()])
	if OS.get_cmdline_user_args().has("--export"):
		var ex := DotMapNavLinks.read(game.stage.io.world)
		for d: Dictionary in ex["doors"]:
			print("    door %s %s %s %s opens=%s by=%s" % [d["entity"], d["classname"], d["name"], d["box"], d["opens"], (d["opened_by"] as Array).map(func(o: Dictionary) -> String: return "%s#%d/%s/%dh" % [o["kind"], o["index"], o["name"], o["hops"]])])
		for t: Dictionary in ex["teleports"]:
			print("    teleport %s %s enabled=%s to %s by=%s" % [t["entity"], t["name"], t["enabled"], t["to"], (t["opened_by"] as Array).map(func(o: Dictionary) -> String: return "%s#%d/%s/%dh" % [o["kind"], o["index"], o["name"], o["hops"]])])
	if OS.get_cmdline_user_args().has("--dump"):
		var lk: DotBotLinks = game._io_bot.links
		for o in lk.off_mesh:
			print("    off_mesh %s" % [o])
		for g in lk.gadgets:
			print("    gadget %s %s box %s feeds %s" % [g["kind"], g["index"], g["box"], g["feeds"]])
		print("    finish %s start %s" % [finish, start])
		var kinds := {}
		for ent in game.stage.io.world.io.entities:
			var mv = ent.get("mover")
			if mv != null:
				var k := "%s%s%s%s" % [mv.kind, " touch" if mv.touch else "", " use" if mv.use else "", " locked" if ent.locked else ""]
				kinds[k] = int(kinds.get(k, 0)) + 1
		print("    movers %s" % [kinds])
		for node in game.stage.io.world.volumes.nodes:
			var vb: AABB = node.volume.bounds()
			if node.volume.kind == "hurt" and vb.grow(5.0).intersects(finish):
				print("    hurt near finish %s %s box %s dmg %s outputs %s" % [node.volume.classname, node.volume.targetname, vb, node.volume.record.get("damage"), node.volume.outputs])
	if OS.get_cmdline_user_args().has("--graph"):
		var gnav: DotBotNav = game._io_bot.nav
		var goal: Vector3 = Vector3(finish.get_center().x, finish.position.y + 0.5, finish.get_center().z)
		print("  GRAPH islands %d; start island %d at %s, goal island %d (closest %s); start joined goal: %s" % [gnav.islands().size(), gnav.island_at(start), start, gnav.island_at(gnav.closest(goal)), gnav.closest(goal), gnav.joined(start, goal)])
		for t in game._io_bot.links.teleports:
			var tf: Variant = t.get("from")
			print("   tp %s from-island %s reachable-from-start %s | dest %s island %s reaches-goal %s" % [t["entity"], gnav.island_at(tf) if tf is Vector3 else "-", gnav.joined(start, tf) if tf is Vector3 else "-", t["to"], gnav.island_at(t["to"]), gnav.joined(t["to"], goal)])
		var si := gnav.island_at(start)
		for isl in gnav.islands():
			if isl["index"] == si:
				print("   START island %d area %.0f bounds %s" % [si, isl["area"], isl["bounds"]])
		for k in game._io_bot.links.kills:
			if k.grow(3.0).has_point(start):
				print("   kill box around start %s" % [k])
		for r in gnav.rides():
			if gnav.island_at(r["from"]) == si:
				print("   ride from start island id %d from %s to %s (island %d)" % [r["id"], r["from"], r["to"], gnav.island_at(r["to"])])
		var reach := 0
		for isl in gnav.islands():
			if OS.get_cmdline_user_args().has("--reach") and gnav.joined(start, isl["centre"]):
				reach += 1
				if reach < 12:
					print("   reachable island %d area %.0f bounds %s" % [isl["index"], isl["area"], isl["bounds"]])
		print("   islands reachable from start: %d" % reach)
		for isl in gnav.islands().slice(0, 12):
			print("   island %d area %.0f bounds %s joined-from-start %s" % [isl["index"], isl["area"], isl["bounds"], gnav.joined(start, isl["centre"])])
	var tracing := OS.get_cmdline_user_args().has("--trace")
	var limit: float = float(plan["limit"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seconds="):
			limit = float(a.substr(10))
	var travelled := 0.0
	var last := start
	var finished_at := -1.0
	for i in range(int(limit * TICK_RATE)):
		game.simulate(TICK)
		if i % 64 == 63:
			await get_tree().process_frame
		var at := bot.controller.state.position
		if at.distance_to(last) < 10.0:
			travelled += at.distance_to(last)
		if tracing and i % 128 == 0:
			var tail: PackedVector3Array = game._io_bot.path_to(at)
			print("    t=%.0f at %s falls=%d path_end=%s %s" % [i * TICK, at, bot.falls, str(tail[tail.size() - 1]) if not tail.is_empty() else "-", game._io_bot.describe()])
			print("      mode %s vel %s surf %s mods %s" % [bot.controller.state.mode, bot.controller.state.velocity, bot.controller.state.surface, bot.controller.state.modifiers])
			if OS.get_cmdline_user_args().has("--points"):
				print("      path %s" % [Array(tail).slice(0, 6)])
		if tracing and at.distance_to(last) > 3.0:
			print("    jump t=%.2f %s -> %s finished=%s watching=%s phase=%s" % [i * TICK, last, at, bot.finished, bot.watching, game.phase])
		last = at
		# an eliminated stand-in is seated in the lounge, which lies inside the finish box: not a finish
		if bot.finished and not bot.watching:
			finished_at = game.course_elapsed
			break
		if game.phase != WoGame.Phase.COURSE:
			break
	if OS.get_cmdline_user_args().has("--dump"):
		var lk2: DotBotLinks = game._io_bot.links
		print("  END links %s" % [lk2.describe()])
		for o in lk2.off_mesh:
			print("    off_mesh %s" % [o])
		for t in lk2.teleports:
			print("    tp %s box %s from %s to %s" % [t["entity"], t["box"], t.get("from"), t["to"]])
	if OS.get_cmdline_user_args().has("--near"):
		var here := bot.controller.state.position
		print("  NEAR %s" % here)
		for node in game.stage.io.world.volumes.nodes:
			var nb: AABB = node.volume.bounds()
			if (node.volume.kind != "hurt" and nb.grow(20.0).has_point(here)) or (node.volume.kind == "hurt" and nb.grow(3.0).has_point(here)):
				var ent = node.entity
				print("    vol %s %s name=%s box %s active=%s outs=%s" % [node.volume.kind, node.volume.classname, node.volume.targetname, nb, node.active(), (ent.links if ent != null else node.volume.outputs).map(func(l): return "%s>%s:%s" % [l["output"], l["target"], l["input"]])])
		for ent in game.stage.io.world.io.entities:
			var mv = ent.get("mover")
			if mv != null and ent.hit_half != Vector3.ZERO and ent.hit_frame.origin.distance_to(here) < 20.0:
				print("    mover %s %s kind=%s name=%s at %s half %s use=%s touch=%s locked=%s outs=%s" % [ent.index, ent.classname, mv.kind, ent.targetname, ent.hit_frame.origin, ent.hit_half, mv.use, mv.touch, ent.locked, ent.links.map(func(l): return "%s>%s:%s" % [l["output"], l["target"], l["input"]])])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ent="):
			for ent in game.stage.io.world.io.entities:
				if str(ent.targetname).contains(a.substr(6)):
					print("    ENT %s %s name=%s origin %s half %s outs=%s" % [ent.index, ent.classname, ent.targetname, ent.hit_frame.origin if ent.get("hit_frame") != null else null, ent.hit_half if ent.get("hit_half") != null else null, ent.links.map(func(l): return "%s>%s:%s" % [l["output"], l["target"], l["input"]])])
	if OS.get_cmdline_user_args().has("--bodies"):
		var here := bot.controller.state.position
		var stack: Array = [game.stage.io.world]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			stack.append_array(n.get_children())
			if n is CollisionObject3D:
				for c in n.get_children():
					if c is CollisionShape3D and c.shape != null:
						var wb: AABB = (c as CollisionShape3D).global_transform * c.shape.get_debug_mesh().get_aabb()
						if wb.grow(3.0).has_point(here) or n.collision_layer == 0:
							print("    BODY %s %s layer %d aabb %s" % [n.get_class(), n.name, n.collision_layer, wb])
	if OS.get_cmdline_user_args().has("--ring"):
		var here := bot.controller.state.position
		var space := game.stage.io.world.get_world_3d().direct_space_state
		print("  RING from %s" % here)
		for deg in range(0, 360, 45):
			var dir := Vector3(sin(deg_to_rad(deg)), 0, cos(deg_to_rad(deg)))
			var line := ""
			for dist in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]:
				var top: Vector3 = here + dir * dist + Vector3(0, 1.0, 0)
				var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(here + Vector3(0, 1, 0), top))
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, top + Vector3(0, -30, 0)))
				line += " %.0f:%s%s" % [dist, "W" if not wall.is_empty() else "", "%.1f" % (hit["position"].y - here.y) if not hit.is_empty() else "-"]
			print("   dir %3d%s" % [deg, line])
	if OS.get_cmdline_user_args().has("--locks"):
		for ent in game.stage.io.world.io.entities:
			for l in ent.links:
				if str(l["input"]).to_lower() in ["unlock", "lock", "open", "toggle", "close"]:
					var kind := ""
					var at := Vector3.INF
					if ent.get("mover") != null:
						kind = "mover/" + str(ent.mover.kind)
					if ent.get("hit_frame") != null:
						at = ent.hit_frame.origin
					print("    LINK %s %s (%s) name=%s at %s: %s > %s:%s" % [ent.index, ent.classname, kind, ent.targetname, at, l["output"], l["target"], l["input"]])
	if OS.get_cmdline_user_args().has("--paths"):
		for ent in game.stage.io.world.io.entities:
			var mv = ent.get("mover")
			if mv != null and mv.kind == "path":
				print("    path %s %s name=%s node %s hit %s half %s corners %s loop=%s" % [ent.index, ent.classname, ent.targetname, ent.node.global_position if ent.node != null else null, ent.hit_frame.origin, ent.hit_half, ent._corners, ent._ring])
	var nearest := bot.controller.state.position.distance_to(finish.get_center())
	print("  walked %.0f m, %.0f m from the finish, %d falls, finished %s" % [travelled, nearest, bot.falls, str(bot.finished and not bot.watching)])
	_check(travelled > 3.0, "the stand-in walks a route of its own", "%.1f m" % travelled)
	_check((bot.finished and not bot.watching) == bool(plan["finish"]), "it %s" % ("finishes" if plan["finish"] else "does not finish: " + str(plan["why"])),
		"%d falls, %.0f m from the finish" % [bot.falls, nearest])
	var fired := 0
	var taken := 0
	for key in game._io_bot.describe()["done"]:
		if int(key) >= DotBotLinks.TELEPORT_ID:
			taken += 1
		else:
			fired += 1
	print("  fired %d, taken %d  %s" % [fired, taken, game._io_bot.describe()])
	_check(fired == int(plan.get("fired", 0)) and taken == int(plan.get("taken", 0)), "it fired %d buttons or triggers and took %d teleports" % [plan.get("fired", 0), plan.get("taken", 0)],
		"fired %d, taken %d" % [fired, taken])
	var route_done: int = game._io_bot.route_done
	_check(route_done == int(plan.get("route", 0)) and game._io_bot.route_skipped == 0, "it walked %d scripted route steps, none given up" % int(plan.get("route", 0)),
		"done %d, given up %d" % [route_done, game._io_bot.route_skipped])
	_check(not bot.finished or finished_at < limit, "inside %d seconds" % int(limit), "%.1f s" % finished_at)
	_finished_count += 1


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
