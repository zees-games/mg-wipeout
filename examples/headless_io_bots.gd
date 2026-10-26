extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Do stand-ins finish the courses that are a map's own world? Each is run with one stand-in, which has no route
## document there and walks a navigation mesh baked from the map's static colliders (WoIoBot, dot-bot's DotBotNav).
##
## Per course, six checks: the mesh bakes; a path leads from the start; the floor alone leads to the finish
## (`floor`); the stand-in walked a route of its own; it finished (`finish`) or did not, and the plan says why; and
## a finish came inside `limit` seconds. A course whose way on is the map's own logic (a button, a teleport, a ride)
## cannot be finished from the floor: `why` records the diagnosis and the suite fails when the picture changes, so
## somebody looks. headless_routes finds which teleports and doors a walk can fire.

const COURSES := {
	&"wo_oaks_course": {"floor": false, "finish": false, "limit": 90, "why": "13 m on the floor ends at the pit past the start door; the one teleport is disabled until a button chain enables it, which links do not read"},
	&"wo_pauls_course": {"floor": false, "finish": false, "limit": 90, "why": "12 m short of the finish; both open teleports lie off the mesh, 52 are disabled (button-enabled) and one is filtered"},
	&"wo_scary_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 47 m out and the stand-in then idles and the map's AFK_KILLER trigger_hurt kills it every 0.5 s from 30 s (121 'falls' are not edge falls); no teleport on the course"},
	&"wo_lego_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 96 m out and the stand-in then idles and the map's 'afk' trigger_hurt kills it from 45 s (91 'falls', not edges); no teleport, trigger_once chains and four touch doors are the way on"},
	&"wo_dc_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 292 m out; two teleports join but the stand-in is killed (99) by the 'spawnkill' trigger_hurt around its spawn, not at an edge, before reaching one"},
	&"wo_waytobar_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 25 m out at the glass slab; all six teleports lie off the mesh, and the idle stand-in is killed (121) by the map's AFK_KILLER trigger_hurt from 30 s, not at an edge"},
	&"wo_dans_course": {"floor": false, "finish": false, "limit": 90, "why": "stalls 99 m out; of three teleports one joins, two lie off the mesh, and a touch door (hamwallet) is on the way"},
	&"wo_office_course": {"floor": false, "finish": false, "limit": 90, "why": "never finishes: the map's own timer kills the stand-in, and the lounge it is seated in used to count as the finish; the mesh ends 70 m out, 2 of 5 teleports join"},
	&"wo_labo_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 128 m out; all three teleports lie off the mesh and 14 touch doors stand between"},
	&"wo_sweet_course": {"floor": false, "finish": false, "limit": 90, "why": "the mesh ends 251 m out; three of five teleports join and the stand-in stalls after 27 m"},
}
const CHECKS_PER_COURSE := 6
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
			print("    t=%.0f at %s falls=%d path_end=%s" % [i * TICK, at, bot.falls, str(tail[tail.size() - 1]) if not tail.is_empty() else "-"])
		last = at
		# an eliminated stand-in is seated in the lounge, which lies inside the finish box: not a finish
		if bot.finished and not bot.watching:
			finished_at = game.course_elapsed
			break
		if game.phase != WoGame.Phase.COURSE:
			break
	var nearest := bot.controller.state.position.distance_to(finish.get_center())
	print("  walked %.0f m, %.0f m from the finish, %d falls, finished %s" % [travelled, nearest, bot.falls, str(bot.finished and not bot.watching)])
	_check(travelled > 3.0, "the stand-in walks a route of its own", "%.1f m" % travelled)
	_check((bot.finished and not bot.watching) == bool(plan["finish"]), "it %s" % ("finishes" if plan["finish"] else "does not finish: " + str(plan["why"])),
		"%d falls, %.0f m from the finish" % [bot.falls, nearest])
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
