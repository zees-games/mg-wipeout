extends "headless_run_flashlight.gd"
## Falling off, being knocked, and dying at once, and the gusts and lightning: what a course does to somebody on it.


func _test_the_knock() -> void:
	_section("an arm throws whoever it meets, up and away")
	var game := await _world()
	var victim := game.add_player(&"u1", "Ada")
	var spinner := _piece(game, "spinner")
	var spec: Dictionary = spinner["spec"]
	var hub: Vector3 = spec["at"]
	# Standing on the arm's circle, and waiting for it to come round.
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var thrown := false
	var top_speed := 0.0
	var top_lift := 0.0

	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		var v := victim.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(v.x, v.z).length())
		top_lift = maxf(top_lift, v.y)

		if victim.knocks > 0:
			thrown = true

	_check(thrown, "the arm came round and threw them", "%d knocks" % victim.knocks)
	_check(top_speed >= game.config.knock_min_speed - 0.01, "at least the floor speed",
		"%.1f m/s" % top_speed)
	_check(top_lift >= game.config.knock_lift - 0.5, "and up", "%.1f m/s" % top_lift)
	_finished()


func _test_a_fall() -> void:
	_section("falling in is a restart from the last checkpoint, not a death")
	var game := await _world()
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	runner.place_at(checkpoint["at"], 0.0)
	await _step(game, 3)
	_check(runner.checkpoint == 0, "standing in the checkpoint crosses it")

	runner.place_at(Vector3(30.0, 2.0, -10.0), 0.0)
	await _step(game, TICK_RATE * 2)
	_check(runner.falls == 1, "into the water is one fall", "%d" % runner.falls)
	_check(runner.is_alive(), "and nobody died")
	_check(runner.controller.state.position.distance_to(checkpoint["at"]) < 4.0,
		"they are back at the checkpoint", str(runner.controller.state.position))
	_finished()


func _test_instant_death() -> void:
	_section("instant death: the water is fatal, and out lasts until the round is over")
	var game := await _world(func(c: WoConfig) -> void:
		c.instant_death = true
		c.courses_per_round = 2
		c.countdown_seconds = 0.2
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	var c := game.add_player(&"u3", "Cy")
	game.start()
	await _step(game, int(1.0 * TICK_RATE))
	a.place_at(Vector3(30.0, 2.0, -10.0), 0.0)
	await _step(game, TICK_RATE * 2)
	_check(a.watching and a.out_for_round and a.falls == 0,
		"into the water is out, not a restart", "falls %d watching %s" % [a.falls, a.watching])
	_check(not game._course_is_over(), "the others are still on the course")

	var finish: Dictionary = game.course_doc["finish"]
	b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	c.place_at(finish["at"], 0.0)
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.COUNTDOWN and a.watching and a.out_for_round,
		"the next course of the round: still out", str(game.phase))
	_check(not b.watching and not c.watching, "and the finishers are back to run it")

	game._on_round_started(game.round_number + 1)
	_check(not a.watching and not a.out_for_round, "a new round brings everybody back")
	_finished()


## The fall: a curtain of water that pushes whoever is under it off the side while it pours,
## warns with drips first, and is a function of the tick like everything else.
func _test_the_falls() -> void:
	_section("a fall pours for its duty, warns first, and pushes off the side")
	var spec := {"kind": "fall", "at": Vector3(0, 0, -20), "size": Vector3(6, 4.5, 1.2), "period": 3.0,
		"duty": 0.4, "phase": 0.0, "push": 9.0, "yaw": 0.0}
	_check(WoCourse.fall_on(spec, 0.5) and not WoCourse.fall_on(spec, 1.5) and WoCourse.fall_on(spec, 3.1),
		"on for the first two fifths of each period, off for the rest")
	_check(WoCourse.fall_warning(spec, 2.6) > 0.0 and WoCourse.fall_warning(spec, 1.5) == 0.0,
		"its drips warn in the seconds before it comes down")
	var doc := WoCatalogue.practice()
	(doc["pieces"] as Array).append({"kind": "fall", "at": [0, 0, -14], "size": [6, 4.5, 1.2], "period": 3.0,
		"duty": 0.4, "push": 9.0})
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 0.0
		c.storm_chance = 0.0, doc)
	var checked := WoCourseDoc.validate(doc)
	_check(checked.ok, "a course with a fall in it validates", checked.error.message if not checked.ok else "")
	var limits := Vector3(game.config.knock_min_speed, game.config.knock_max_speed, game.config.knock_lift)
	var pouring := game.stage.knock(Vector3(0, 0, -14), false, int(0.5 * TICK_RATE), limits)
	var dry := game.stage.knock(Vector3(0, 0, -14), false, int(1.5 * TICK_RATE), limits)
	_check(pouring.x > 5.0 and dry == Vector3.ZERO, "under it while it pours is a throw off the side; dry, nothing",
		"%s / %s" % [pouring, dry])
	_finished()


func _piece(game: WoGame, kind: String) -> Dictionary:
	for piece in game.stage.pieces:
		if str(piece["kind"]) == kind:
			return piece

	return {}


func _test_the_weather() -> void:
	_section("gusts and lightning are drawn once and computed from the tick")
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 1.0
		c.storm_chance = 1.0)
	var doc: Dictionary = game.course_doc
	var once := game.draw_weather(doc, DotRandomStream.new(7, &"weather"), 100)
	var twice := game.draw_weather(doc, DotRandomStream.new(7, &"weather"), 100)
	_check(once == twice, "the same stream draws the same weather")
	_check((once["gusts"] as Array).size() > 0 and (once["strikes"] as Array).size() == game.config.storm_strikes,
		"wind and storm on: gusts and %d strikes" % game.config.storm_strikes)

	# A known plan: one gust east from tick 200 to 600, one strike at the start at tick 300.
	var start: Vector3 = doc["start"]["at"]
	var planned := doc.duplicate(true)
	planned["weather"] = {
		"gusts": [{"from": 200, "to": 600, "dx": 1.0, "dz": 0.0, "strength": 10.0}],
		"strikes": [{"tick": 300, "x": start.x, "y": start.y, "z": start.z, "radius": 3.0}],
	}
	var _built := game.build_stage(planned)
	_check(game.stage.wind(150) == Vector3.ZERO and game.stage.wind(400).x > 9.0,
		"the wind blows only inside its gust (%.1f at 400)" % game.stage.wind(400).x)
	_check(game.stage.is_stormy() and not game.stage.strike_at(300).is_empty(), "the course knows its storm")
	_check(game.stage.strike(start, 300) != Vector3.ZERO and game.stage.strike(start, 301) == Vector3.ZERO,
		"a strike throws whoever is under it, on its tick only")
	_check(game.stage.strike(start + Vector3(10.0, 0.0, 0.0), 300) == Vector3.ZERO, "and nobody further away")
	_finished()
