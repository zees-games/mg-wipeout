extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

## Every installed course is run to the finish by a stand-in, and every arena is stood in.
##
## [b]A course is content, and content is checked by playing it.[/b] A document that validates
## can still have a gap nobody clears, an arm with no window, a mover that never reaches the far
## side or a finish nobody can get to — and none of those is an error anywhere. So each course
## here is run by a bot that never fumbles, on the route the document gives, with every hazard
## live and the bot waiting for its windows the way [WoGame] lets it; a course it cannot finish
## inside its own clock is a course to fix, and this says which one and where the bot got to.
##
## [b]Ticks are not paced by the engine's frames[/b], because ten courses at real time is half
## an hour. The simulation does not notice: every tick is a fixed step the suite drives itself.
##
## Without the mg-wipeout-maps link (a fresh clone) this runs the built-in practice course and
## arena only, and says so.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()
var _world: WoGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: every course run, every arena stood in")
	print("")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var courses := catalogue.courses.keys()
	courses.sort()
	var arenas := catalogue.arenas.keys()
	arenas.sort()

	if courses.size() <= 1:
		print("(no course directory: the built-in practice course and arena only)")

	_section("every document loads")
	_check(catalogue.refused.is_empty(), "none was refused", str(catalogue.refused))
	_finished()

	# A course with a fork is run down each branch: the safe way with `wo_bot_risk` 0 and the
	# risky way with 100. A branch nobody can finish is a hole as much as a gap nobody clears.
	var forked := 0

	for id: StringName in courses:
		var doc: Dictionary = catalogue.courses[id]
		if _has_fork(doc):
			forked += 1
			await _run_course(doc, 0.0)
			await _run_course(doc, 100.0)
		else:
			await _run_course(doc)

	for id: StringName in arenas:
		await _stand_in_arena(catalogue.arenas[id])

	# No shipped course has a pad since Dan's Course was imported whole; a practice course with one added stands in.
	var padded: Dictionary = (catalogue.courses[&"wo_practice"] as Dictionary).duplicate(true)
	(padded["pieces"] as Array).append({"kind": "teleport", "at": Vector3(-106.04, -8.06, -56.3),
		"size": Vector3(3.0, 0.6, 3.0), "role": &"safe", "to": Vector3(-136.04, -13.56, -53.3),
		"heading": 180.0, "yaw": -180.0})
	await _teleport_pad(padded)

	# One audit per document, over the stage as a client draws it (sky and water included).
	for id: StringName in courses:
		await _audit_collision(catalogue.courses[id])

	for id: StringName in arenas:
		await _audit_collision(catalogue.arenas[id])

	var field_course: Dictionary = catalogue.courses.get(&"wo_first_splash", catalogue.courses[&"wo_practice"])
	await _race_by_difficulty(field_course)

	if _world != null:
		remove_child(_world)
		_world.free()

	var sections := 3 + courses.size() + forked + arenas.size() + courses.size() + arenas.size()
	var checks := 8 + (courses.size() + forked) * 4 + courses.size() * 2 + arenas.size() * (4 + 2) + courses.size() + arenas.size()

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	get_tree().quit(code)


## A teleport pad sends whoever stands on it to its `to`, facing its `heading`, and nobody who
## is beside it, above it by a jump's height more or under it. Dan's Course ends on one, so a
## stand-in finishing it (above) also proves the whole path through a round: the pad, the
## stand-in carrying on from the nearest route point, and the finish beyond it.
func _teleport_pad(doc: Dictionary) -> void:
	_section("a teleport pad")
	var game := await _fresh_world(doc)
	var _built := game.build_stage(doc)
	var pad := {}

	for piece: Dictionary in doc["pieces"]:
		if str(piece["kind"]) == "teleport":
			pad = piece

	_check(not pad.is_empty(), "the course has a pad")

	var at: Vector3 = pad["at"]
	var top := at + Vector3(0.0, (pad["size"] as Vector3).y * 0.5, 0.0)
	var sent := game.stage.teleport_at(top)
	_check(sent.size() == 2 and (sent[0] as Vector3).is_equal_approx(pad["to"]) \
		and is_equal_approx(float(sent[1]), float(pad["heading"])), "on it, a runner is sent to its destination",
		str(sent))
	_check(game.stage.teleport_at(top + Vector3(0.0, 2.5, 0.0)).is_empty(), "two and a half metres above it, nobody is")
	_check(game.stage.teleport_at(top + Vector3(0.0, -3.0, 0.0)).is_empty(), "three metres under it, nobody is")
	_check(game.stage.teleport_at(top + Vector3(3.0, 0.0, 0.0)).is_empty(), "three metres beside it, nobody is")
	_finished()


func _has_fork(doc: Dictionary) -> bool:
	for point: Dictionary in doc.get("route", []):
		if bool(point.get("risky", false)):
			return true
	return false


## The cull in `WoCourse.knock` (a hazard too far off to touch is not asked) must answer exactly what
## asking every hazard does, at every point a stand-in looks from.
func _check_knock_cull(game: WoGame) -> void:
	var limits := Vector3(1.0, 1.0, 1.0)
	var asked := 0
	var differ := 0

	for point: Dictionary in game.stage.route():
		for offset in [Vector3.ZERO, Vector3(2.5, 0.0, 0.0), Vector3(0.0, 0.0, -4.0), Vector3(-7.0, 1.0, 3.0)]:
			for tick in range(0, 400, 23):
				for crouched in [false, true]:
					var feet: Vector3 = (point["at"] as Vector3) + offset
					game.stage.cull_hazards = true
					var culled := game.stage.knock(feet, crouched, tick, limits)
					game.stage.cull_hazards = false
					var every := game.stage.knock(feet, crouched, tick, limits)
					asked += 1
					differ += 1 if culled != every else 0

	game.stage.cull_hazards = true
	_check(differ == 0, "the hazard cull answers what asking every hazard does", "%d of %d differ" % [differ, asked])


func _run_course(doc: Dictionary, risk: float = -1.0) -> void:
	_section("%s — %s%s" % [doc["id"], doc["name"],
		"" if risk < 0.0 else (" (the risky way)" if risk > 50.0 else " (the safe way)")])
	var game := await _fresh_world(doc)
	if risk >= 0.0:
		var _risk := game.racer.set_value("risk", str(risk))
	var bot := game.add_player(&"u900001", "Runner")
	bot.is_bot = true
	var idle := game.add_player(&"u2", "Watcher")
	# The start pen's toys, once a course (not again down a fork's other branch).
	if risk < 50.0:
		await _check_toys(game, doc)
	_check_knock_cull(game)
	game.start()

	var limit := game.course_limit() + game.config.countdown_seconds + 1.0
	var ticks := int(limit * TICK_RATE)
	var furthest := -1
	var deepest := 0
	var started := false

	for i in range(ticks):
		idle.controller.apply_command(DotFpsCommand.new())
		game.simulate(TICK)

		# Not a physics frame per tick: every moving piece writes its transform straight into
		# the physics server (see `WoCourse._place`), so a query on the next tick already sees
		# it, and waiting on the engine's own frame pacing made ten courses take an hour.
		if i % 512 == 0:
			await get_tree().process_frame

		if game.phase == WoGame.Phase.COURSE:
			started = true
		elif started:
			break

		furthest = maxi(furthest, bot.checkpoint)
		deepest = maxi(deepest, int(game._bot_route.get(bot.player_id, 0)))

		if bot.finished:
			break

	var where := bot.controller.state.position
	_check(bot.finished, "a stand-in finished it", "%s in %.1f s, %d falls, %d knocks" % [
		"finished" if bot.finished else "got to route point %d of %d, last at %s, checkpoint %d" % [
			deepest, game.stage.route().size(), where, furthest],
		bot.finish_seconds if bot.finished else game.course_elapsed, bot.falls, bot.knocks])
	_check(furthest == game.stage.checkpoint_count() - 1 or not bot.finished,
		"crossing every checkpoint on the way", "%d of %d" % [furthest + 1, game.stage.checkpoint_count()])
	_check(game.stage.pieces.size() >= 5 or str(doc["id"]) == "wo_practice",
		"with something in it", "%d pieces, %d hazards" % [game.stage.pieces.size(), game.stage.describe()["hazards"]])
	_finished()


## A field of six at easy and six at nightmare round the same course, every mistake on: the
## presets have to MEAN something. Nightmare's median finish is not slower than easy's, and
## every nightmare stand-in gets home. Deterministic (seeded mistakes, ticks driven here), so
## a change to a preset or the racing that turns this round is a change to look at; the full
## spread is tools/race_times.
func _race_by_difficulty(doc: Dictionary) -> void:
	_section("%s — a field at easy against one at nightmare" % doc["id"])
	var medians := {}
	var home := {}

	for difficulty in ["easy", "nightmare"]:
		var game := await _fresh_world(doc)
		game.config.bot_mistakes = 1.0
		game.config.knock_damage_per_speed = 1.0
		var _set := DotBotSettings.of(game).set_difficulty(difficulty)
		var field: Array[WoPlayer] = []
		for i in range(6):
			var bot := game.add_player(StringName("u%d" % (900200 + i)), "R%d" % i)
			bot.is_bot = true
			field.append(bot)
		game.start()
		var started := false
		for i in range(int((game.course_limit() + 2.0) * TICK_RATE)):
			game.simulate(TICK)
			if i % 512 == 0:
				await get_tree().process_frame
			if game.phase == WoGame.Phase.COURSE:
				started = true
			elif started:
				break
		var times: Array[float] = []
		for bot in field:
			if bot.finished:
				times.append(bot.finish_seconds)
		times.sort()
		medians[difficulty] = times[times.size() / 2] if not times.is_empty() else INF
		home[difficulty] = times.size()

	_check(int(home["nightmare"]) == 6, "every nightmare stand-in gets home", "%d of 6" % int(home["nightmare"]))
	_check(float(medians["nightmare"]) <= float(medians["easy"]), "and the nightmare field's median is not slower than easy's",
		"nightmare %.1f s, easy %.1f s (%d home)" % [float(medians["nightmare"]), float(medians["easy"]), int(home["easy"])])
	_finished()


func _stand_in_arena(doc: Dictionary) -> void:
	_section("%s — %s" % [doc["id"], doc["name"]])
	var game := await _fresh_world(doc)
	await get_tree().physics_frame
	game.stage.pose_at(0)
	var space := game.get_world_3d().direct_space_state
	var floorless := PackedStringArray()

	for area: Dictionary in doc["spawns"]:
		if not _floor_under(space, area["at"]):
			floorless.append(str(area["at"]))

	_check(floorless.is_empty(), "every spawn area has floor under it", ", ".join(floorless))

	floorless.clear()

	for area: Dictionary in doc["drops"]:
		if not _floor_under(space, area["at"]):
			floorless.append(str(area["at"]))

	_check(floorless.is_empty(), "every drop area has floor under it", ", ".join(floorless))

	var gallery: Vector3 = doc["gallery"]["at"]
	_check(_floor_under(space, gallery), "the gallery has a floor")

	# Out of the gallery is a wall in every direction, so a watcher cannot join the fight.
	var open := PackedStringArray()

	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var from := gallery + Vector3(0, 1.5, 0)
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * 30.0)
		if space.intersect_ray(query).is_empty():
			open.append(str(direction))

	_check(open.is_empty(), "and walls all round it", ", ".join(open))
	await _check_toys(game, doc)
	_finished()


## A stage's toys (dot-props', loose only): every one built, none inside a piece, and after a
## second and a half of real physics every one still where the document put it. Two checks.
## Real physics frames, unlike the course run: a toy is a rigid body, simulated only by them.
func _check_toys(game: WoGame, doc: Dictionary) -> void:
	var box := game.stage.toys
	var placed := (doc.get("toys", []) as Array).size()
	var stuck: Array = []
	var space := game.get_world_3d().direct_space_state
	for toy in box.toys:
		for child in toy.body.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = game.physics.layer_mask(&"world")
			if not space.intersect_shape(query, 1).is_empty():
				stuck.append("%s %d at %s" % [toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1)])
				break
	# Every course has the start pen's; an arena may have none (the turning floor's).
	_check(box.count() == placed and (placed > 0 or str(doc["kind"]) == "arena") and box.missing.is_empty() and stuck.is_empty(),
		"%d toys, every one dot-props' and loose, standing clear" % placed, "; ".join(stuck))
	for _i in range(90):
		await get_tree().physics_frame
	var strayed: Array = []
	for toy in box.toys:
		if toy.body.global_position.distance_to(toy.rest.origin) > 0.3:
			strayed.append("%s %d to %s" % [toy.def["id"], toy.index, toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(strayed.is_empty(), "and still where it was put a second and a half on", "; ".join(strayed))


func _floor_under(space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3(0, 3.0, 0), at + Vector3(0, -3.0, 0))
	return not space.intersect_ray(query).is_empty()


## dot-core's [DotCollisionAudit] over the stage as a client draws it: visible geometry nothing
## collides with, which a runner walks through. Pieces are static bodies the course moves, and
## their drawing sits beside their shape, so the lenient audit is used.
func _audit_collision(doc: Dictionary) -> void:
	_section("%s: nothing drawn is walked through" % doc["id"])
	var game := await _fresh_world(doc, true)
	var res := DotCollisionAudit.audit(game.stage, true)
	var found := 0

	if res.ok:
		var report: DotCollisionAudit = res.value
		found = report.count()
		print("  %s collision audit: %d of %d" % [doc["id"], found, report.examined])

		for line in report.describe_lines().slice(1, 12):
			print("    %s" % line)

	_check(res.ok and found == 0, "no drawn geometry without a shape", "" if res.ok else res.error.message)
	_finished()


func _fresh_world(doc: Dictionary, drawn := false) -> WoGame:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := WoConfig.new()
	# What this suite proves is that a course can be FINISHED; a stand-in knocked nine times
	# before its first checkpoint would be knocked out of the round, which is a fact about the
	# stand-in. Damage and weather are headless_run's.
	config.knock_damage_per_speed = 0.0
	config.fall_damage_per_metre = 0.0
	config.courses_per_round = 1
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.bot_mistakes = 0.0
	config.keep_progress = false
	config.course_ids = PackedStringArray([str(doc["id"])]) if str(doc["kind"]) == "course" \
		else PackedStringArray(["wo_practice"])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	game.draw_world = drawn
	add_child(game)
	game.set_physics_process(false)
	_world = game

	if str(doc["kind"]) == "arena":
		var _built := game.build_stage(doc)
	elif drawn:
		game.start()

	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
