extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Do stand-ins finish the courses that are a map's own world? Each is run with one stand-in, which has no route
## document there and walks a navigation mesh baked from the map's static colliders (WoIoBot, dot-bot's DotBotNav).
##
## Per course, seven checks: the mesh bakes; a path leads from the start; the floor alone leads to the finish
## (`floor`); the stand-in walked a route of its own; it finished (`finish`) or did not, and the plan says why; and
## a finish came inside `limit` seconds; and the stand-in pressed `fired` buttons or triggers and took `taken` teleports on its way (the
## map's own logic that dot-bot's DotBotLinks finds and the stand-in goes to; a count that changes means the way on changed). A course whose way on is the map's own logic (a button, a teleport, a ride)
## cannot be finished from the floor: `why` records the diagnosis and the suite fails when the picture changes, so
## somebody looks. headless_routes finds which teleports and doors a walk can fire.

const COURSES := {
	&"wo_oaks_course": {"floor": false, "finish": false, "limit": 90, "why": "13 m on the floor ends at the pit past the start door; no teleport is read at all (the chain behind the door is not a teleport the links see), so there is no button to press"},
	&"wo_pauls_course": {"floor": false, "finish": false, "limit": 90, "fired": 3, "taken": 1, "why": "presses three buttons, which enables two teleports, and takes one; it lands on an island 16 m above the finish with no drop edge down, so it stalls short"},
	&"wo_scary_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "fires one trigger but the mesh still ends 47 m out (movers are not in the bake), then the map's AFK_KILLER trigger_hurt kills the idle stand-in (121 'falls', not edge falls); no teleport"},
	&"wo_lego_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "fires one trigger but the mesh still ends 96 m out (movers are not in the bake), then the map's 'afk' trigger_hurt kills the idle stand-in (91 'falls', not edges); no teleport"},
	&"wo_dc_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 292 m out; two teleports join but the stand-in is killed (99) by the 'spawnkill' trigger_hurt around its spawn, not at an edge, before reaching one"},
	&"wo_waytobar_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 25 m out at the glass slab, a lethal trigger_hurt carved out of the mesh; the six teleports are on islands cut off from the start, and the AFK_KILLER trigger_hurt kills the idle stand-in (121)"},
	&"wo_dans_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "presses the door button (23) but stalls 96 m out; of three teleports one joins and two lie off the mesh with nothing found to enable them"},
	&"wo_office_course": {"floor": false, "finish": false, "limit": 90, "fired": 1, "why": "presses one button and ends 2 m from the finish, but the map's own timer kills the stand-in, so it never finishes; 2 of 5 teleports are disabled until then"},
	&"wo_labo_course": {"floor": false, "finish": false, "limit": 90, "fired": 2, "why": "presses two buttons (423, 460) but the mesh still ends 128 m out; the three teleports lie off the mesh and 14 touch doors stand between"},
	&"wo_sweet_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 251 m out; three of five teleports join, one is disabled with no button found, and the stand-in stalls after 27 m"},
}
const CHECKS_PER_COURSE := 7
const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
## Seconds the bake may take before the suite gives up.
const BAKE_WAIT := 90.0

var _passed := 0
var _failed := 0
var _entered := 0
var _finished_count := 0
var _failures := PackedStringArray()
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

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var code := 1 if _failed > 0 else 0
	if _entered != _finished_count or _entered != expected or _passed + _failed != expected * CHECKS_PER_COURSE:
		print("ERROR: %d of %d courses finished, %d checks ran, %d expected." % [_finished_count, _entered, _passed + _failed, expected * CHECKS_PER_COURSE])
		code = 1
	get_tree().quit(code)


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
	if OS.get_cmdline_user_args().has("--dump"):
		var lk: DotBotLinks = game._io_bot.links
		for o in lk.off_mesh:
			print("    off_mesh %s" % [o])
		for g in lk.gadgets:
			print("    gadget %s %s box %s feeds %s" % [g["kind"], g["index"], g["box"], g["feeds"]])
		print("    finish %s start %s" % [finish, start])
		for node in game.stage.io.world.volumes.nodes:
			var vb: AABB = node.volume.bounds()
			if node.volume.kind == "hurt" and vb.grow(5.0).intersects(finish):
				print("    hurt near finish %s %s box %s dmg %s outputs %s" % [node.volume.classname, node.volume.targetname, vb, node.volume.record.get("damage"), node.volume.outputs])
	var tracing := OS.get_cmdline_user_args().has("--trace")
	var limit: float = float(plan["limit"])
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
			if node.volume.kind != "hurt" and nb.grow(20.0).has_point(here):
				var ent = node.entity
				print("    vol %s %s name=%s box %s active=%s outs=%s" % [node.volume.kind, node.volume.classname, node.volume.targetname, nb, node.active(), (ent.links if ent != null else node.volume.outputs).map(func(l): return "%s>%s:%s" % [l["output"], l["target"], l["input"]])])
		for ent in game.stage.io.world.io.entities:
			var mv = ent.get("mover")
			if mv != null and ent.hit_half != Vector3.ZERO and ent.hit_frame.origin.distance_to(here) < 20.0:
				print("    mover %s %s kind=%s name=%s at %s half %s use=%s touch=%s locked=%s outs=%s" % [ent.index, ent.classname, mv.kind, ent.targetname, ent.hit_frame.origin, ent.hit_half, mv.use, mv.touch, ent.locked, ent.links.map(func(l): return "%s>%s:%s" % [l["output"], l["target"], l["input"]])])
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


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return
	_failed += 1
	var line := "%s: %s%s" % [_world.config.course_ids[0] if _world != null else "?", what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
