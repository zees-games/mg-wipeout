extends "headless_run_client.gd"

## The simulation, headless: documents, the course, what it does to a player, and the round. Counts sections AND
## checks, the second being what matters: a script error aborts a section that has already announced itself, so every
## total was armed by raising it by one and watching the run fail.

const SECTIONS := 42

const CHECKS := 223


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout headless run")
	print("")

	_test_config()
	_test_documents()
	_test_the_wire()
	_test_catalogue()
	_test_delivery()
	_test_the_weapon_art_is_vendored()
	_test_formulas()
	await _test_world_builds()
	_test_client_finds_the_mesh()
	await _test_the_gate()
	await _test_the_start_box()
	await _test_a_one_life_course_has_no_start()
	await _test_a_ladder_climbs()
	await _test_the_carry()
	await _test_the_turntable()
	await _test_the_knock()
	await _test_ducking()
	await _test_a_fall()
	await _test_instant_death()
	_test_course_cfg()
	await _test_a_bot_runs_the_course()
	await _test_the_racers()
	await _test_stand_ins_pass_through_each_other()
	await _test_the_falls()
	await _test_the_show()
	await _test_one_finisher_wins()
	await _test_the_final_death()
	await _test_free_roam()
	await _test_the_toys()
	await _test_nobody_finishes()
	await _test_knocks_hurt()
	await _test_courses_per_round()
	await _test_hard_landings()
	await _test_the_weather()
	await _test_the_machinery_is_heard()
	await _test_the_client_settings()
	await _test_a_carrier_is_drawn_carrying()
	await _test_the_hud()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_offline_trigger()
	await _test_the_drawn_gun()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


func _test_config() -> void:
	_section("the configuration")
	var config := WoConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(not config.teams(), "solo by default", "team_count %d" % config.team_count)

	config.team_count = 1
	_check(not config.validate().ok, "one team is refused")

	config.team_count = 3
	_check(config.validate().ok and config.teams(), "three teams is teams")

	config.knock_max_speed = 2.0
	_check(not config.validate().ok, "a knock ceiling under its floor is refused")
	_finished()


func _test_documents() -> void:
	_section("a course is a document, and a bad one is refused with a reason")
	var practice := WoCatalogue.practice()
	_check(str(practice.get("id", "")) == "wo_practice", "the practice course validates")
	_check(practice["start"]["at"] is Vector3, "positions are normalised to vectors")
	_check((practice["pieces"][0] as Dictionary).has("yaw"), "an omitted yaw is filled in")

	var arena := WoCatalogue.practice_arena()
	_check(str(arena.get("kind", "")) == "arena" and (arena["spawns"] as Array).size() >= 2,
		"the practice arena validates, with spawn areas")

	var unknown := practice.duplicate(true)
	(unknown["pieces"] as Array).append({"kind": "trampoline", "at": [0, 0, 0]})
	var refused := WoCourseDoc.validate(unknown)
	_check(not refused.ok and str(refused.error).contains("trampoline"),
		"an unknown piece kind is refused, naming it", str(refused.error) if not refused.ok else "")

	var missing := practice.duplicate(true)
	(missing["pieces"] as Array).append({"kind": "spinner", "at": [0, 0, 0]})
	refused = WoCourseDoc.validate(missing)
	_check(not refused.ok and str(refused.error).contains("arm_length"),
		"a piece without a field it needs is refused, naming the field")

	var later := practice.duplicate(true)
	later["format"] = WoCourseDoc.FORMAT + 1
	_check(not WoCourseDoc.validate(later).ok, "a document from a later format is refused")

	var no_finish := practice.duplicate(true)
	no_finish.erase("finish")
	_check(not WoCourseDoc.validate(no_finish).ok, "a course with no finish is refused")

	var one_corner := arena.duplicate(true)
	one_corner["spawns"] = [{"at": [0, 0, 0]}]
	_check(not WoCourseDoc.validate(one_corner).ok, "an arena with one spawn area is refused")

	var zero_period := practice.duplicate(true)
	(zero_period["pieces"] as Array).append({"kind": "pendulum", "pivot": [0, 5, 0], "length": 4,
		"radius": 1, "swing": 40, "period": 0})
	_check(not WoCourseDoc.validate(zero_period).ok, "a period of zero is refused")
	_finished()


func _test_the_wire() -> void:
	_section("the document travels, and arrives as the same document")
	var practice := WoCatalogue.practice()
	var bytes := WoCourseDoc.encode(practice)
	var back := WoCourseDoc.decode(bytes)
	_check(back.ok, "it decodes", back.error.message if not back.ok else "")
	_check(back.ok and WoCourseDoc.digest(back.value) == WoCourseDoc.digest(practice),
		"its digest is the one the server sent",
		"%d bytes" % bytes.size())
	_check(bytes.size() < WoCourseDoc.WIRE_LIMIT, "it is under the wire limit")

	var torn := bytes.slice(0, bytes.size() / 2)
	_check(not WoCourseDoc.decode(torn).ok, "half of it is refused, not built")
	_finished()


func _test_catalogue() -> void:
	_section("the catalogue")
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	_check(catalogue.courses.has(&"wo_practice"), "the built-in course is always there")
	_check(catalogue.arenas.has(&"wo_practice_arena"), "the built-in arena is always there")
	_check(catalogue.refused.is_empty(), "no installed document was refused",
		", ".join(catalogue.refused.keys()))

	var ids := catalogue.playable_courses(PackedStringArray())
	_check(ids.size() == 1 or not ids.has(&"wo_practice"),
		"practice drops out once there is a real course", "%d playable" % ids.size())

	var stream := DotRandomStream.new(7)
	var first := catalogue.next_course(PackedStringArray(), true, stream, &"")
	var second := catalogue.next_course(PackedStringArray(), true, stream, StringName(str(first["id"])))
	_check(ids.size() < 2 or str(first["id"]) != str(second["id"]),
		"a shuffle does not repeat the course just played")
	_finished()


## Every bare `"res://…"` string in a shipped script that names one of this game's own
## directories, and every `class_name`. A delivered pack cannot use either; see
## mg-smash-copter's Decision 7.
func _test_delivery() -> void:
	_section("what a delivered pack cannot do, nobody here does")
	var bare := PackedStringArray()
	var named := PackedStringArray()
	var own := ["game", "props", "scenes", "assets", "textures", "courses"]

	for path in _scripts("res://game") + _scripts("res://props"):
		var lines := FileAccess.get_file_as_string(path).split("\n")

		for index in range(lines.size()):
			var line := lines[index].strip_edges()

			if line.begins_with("#"):
				continue

			if line.begins_with("class_name "):
				named.append("%s:%d" % [path, index + 1])

			for folder in own:
				var needle := "\"res://%s/" % folder

				if line.contains(needle) and not line.contains("Paths.rebase(\"res://%s/" % folder):
					bare.append("%s:%d" % [path, index + 1])

	_check(named.is_empty(), "no class_name anywhere", ", ".join(named))
	_check(bare.is_empty(), "no bare res:// path to this game's own files", ", ".join(bare))

	var root := "res://dot_cloud/someone/mg-wipeout/1.0.0/"
	var once := WoPaths.rebase_onto("res://props/wo_crate.tscn", root)
	_check(once == root + "props/wo_crate.tscn", "a path is rebased onto a mount", once)
	_check(WoPaths.rebase_onto(once, root) == once, "and a rebased path is left alone")
	_finished()


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)

	if dir == null:
		return out

	for file in dir.get_files():
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))

	for sub in dir.get_directories():
		out.append_array(_scripts(dir_path.path_join(sub)))

	return out


## The formulas an obstacle is, checked where they are pure: no world, no physics.
func _test_formulas() -> void:
	_section("an obstacle is a function of the tick")
	var mover := {"from": Vector3.ZERO, "to": Vector3(0, 0, -6), "period": 4.0, "phase": 0.0}
	_check(is_zero_approx(WoCourse.mover_fraction(mover, 0.0)), "a mover starts at `from`")
	_check(is_equal_approx(WoCourse.mover_fraction(mover, 2.0), 1.0), "and is at `to` half a period on")

	var pusher := {"period": 2.0, "reach": 3.0, "duty": 0.35, "phase": 0.0, "at": Vector3.ZERO,
		"size": Vector3.ONE, "yaw": 0.0}
	_check(is_equal_approx(WoCourse.pusher_extension(pusher, 0.4), 1.0), "a pusher is out after its strike")
	_check(is_zero_approx(WoCourse.pusher_extension(pusher, 1.8)), "and home for the rest, the window a player uses")

	var tiles := {"kind": "tiles", "spec": {"period": 3.0, "down": 0.3, "seed": 5}}
	var down := 0
	var samples := 300

	for i in range(samples):
		if WoCourse.tile_down(tiles, 4, float(i) * 0.01):
			down += 1

	_check(absf(float(down) / float(samples) - 0.3) < 0.04,
		"a tile is gone for its `down` share of the cycle", "%.2f" % (float(down) / float(samples)))
	_check(WoCourse.tile_cycle(tiles["spec"], 1, 0.0) != WoCourse.tile_cycle(tiles["spec"], 2, 0.0),
		"two tiles are at different points in the cycle")

	# The tell: on for the last moments before a drop, and off the rest of the time.
	var warned_before := 0
	var warned_wrongly := 0

	for i in range(1, samples):
		var t := float(i) * 0.01
		var warning := WoCourse.tile_warning(tiles["spec"], 4, t)

		if WoCourse.tile_down(tiles, 4, t) and not WoCourse.tile_down(tiles, 4, t - 0.01) \
				and WoCourse.tile_warning(tiles["spec"], 4, t - 0.02) > 0.0:
			warned_before += 1

		if warning > 0.0 and WoCourse.tile_down(tiles, 4, t):
			warned_wrongly += 1

	_check(warned_before > 0, "a tile warns just before it drops", "%d drops warned" % warned_before)
	_check(warned_wrongly == 0, "and never while it is already gone")
	_finished()


func _test_world_builds() -> void:
	_section("a world builds its course and puts everybody on the start pad")
	var game := await _world()
	_check(game.stage != null and game.stage.is_course(), "the stage is a course")
	_check(game.stage.pieces.size() == (game.course_doc["pieces"] as Array).size(),
		"every piece in the document was built", "%d" % game.stage.pieces.size())

	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	_check(a.team != b.team and a.team >= WoGame.SOLO_SIDE_BASE, "solo players are each their own side",
		"%d, %d" % [a.team, b.team])

	await _step(game, 4)
	var start: Vector3 = game.course_doc["start"]["at"]
	_check(absf(a.controller.state.position.y - start.y) < 0.6 and a.controller.state.position.distance_to(start) < 6.0,
		"a joiner stands on the start pad", str(a.controller.state.position))
	_check(a.controller.state.position.distance_to(b.controller.state.position) > 1.0,
		"two joiners are not put inside each other")
	_finished()


func _test_client_finds_the_mesh() -> void:
	_section("a client with no courses directory finds an imported mesh in a mounted pack")
	var mount := "res://dot_cloud/test/maps/1.0.0/worlds"
	var kept := WoWorld.dirs.duplicate()
	var src := "res://worlds"
	var copied := 0
	DirAccess.make_dir_recursive_absolute(mount)

	for file in DirAccess.get_files_at(src):
		if DirAccess.copy_absolute(src.path_join(file), mount.path_join(file)) == OK:
			copied += 1

	_check(copied >= 2, "the worlds directory is here to copy from", str(copied))
	WoWorld.dirs = PackedStringArray()
	var prefix := WoWorld.prefix_of("wo_office_course")
	_check(prefix == mount.path_join("wo_office_course"), "the mounted pack's worlds/ is found", prefix)
	var body := WoWorld.build({"mesh": "wo_office_course"}, null)
	_check(body != null and body.get_child_count() > 1, "and builds the faces and hulls", str(body))

	if body != null:
		body.free()

	WoWorld.dirs = kept

	for file in DirAccess.get_files_at(mount):
		DirAccess.remove_absolute(mount.path_join(file))

	var path := mount

	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()

	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


func _test_the_gate() -> void:
	_section("the start gate holds through the countdown, and drops")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 1.5)
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.COUNTDOWN, "a round starts with the countdown")
	_check(game.stage.gate_closed, "the gate is up")

	var start: Vector3 = game.course_doc["start"]["at"]
	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.2 * TICK_RATE))
	_check(runner.controller.state.position.z > start.z - 4.6,
		"running at it during the countdown goes nowhere past it", "z %.2f" % runner.controller.state.position.z)

	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.0 * TICK_RATE))
	_check(game.phase == WoGame.Phase.COURSE and not game.stage.gate_closed, "then it drops")
	_check(runner.controller.state.position.z < start.z - 5.0, "and the runner is through",
		"z %.2f" % runner.controller.state.position.z)
	_finished()


func _in_pen(game: WoGame, at: Vector3, slack: float) -> bool:
	var start: Dictionary = game.course_doc["start"]
	var size: Vector2 = start["size"]
	var local := _yaw_inverse(float(start["yaw"])) * (at - (start["at"] as Vector3))
	return absf(local.x) <= size.x * 0.5 + slack and absf(local.z) <= size.y * 0.5 + slack


func _yaw_inverse(yaw: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw)).inverse()


func _test_the_start_box() -> void:
	_section("nobody leaves the start box before the round begins")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 3.0)
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.COUNTDOWN and game.stage.gate_closed, "the countdown holds the pen shut")
	var inside := true
	for yaw in [0.0, 90.0, 180.0, 270.0]:
		for _i in range(40):
			var command := DotFpsCommand.new()
			command.move = Vector2(0, 1)
			command.yaw = yaw
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			runner.controller.apply_command(command)
			await _step(game, 1)
			inside = inside and _in_pen(game, runner.controller.state.position, 0.0)
	_check(inside, "running and jumping at every side keeps them in the box",
		str(runner.controller.state.position))
	# What clearing a wall looks like to the motor: a body just outside the pen's edge.
	var start: Dictionary = game.course_doc["start"]
	var basis := Basis(Vector3.UP, deg_to_rad(float(start["yaw"])))
	var size: Vector2 = start["size"]
	runner.place_at((start["at"] as Vector3) + basis * Vector3(size.x * 0.5 + 0.5, 1.6, 0.0), 0.0)
	await _step(game, 2)
	_check(_in_pen(game, runner.controller.state.position, 0.0) and game.phase == WoGame.Phase.COUNTDOWN,
		"one that clears a wall is put back", str(runner.controller.state.position))
	_finished()


func _test_a_one_life_course_has_no_start() -> void:
	_section("a one-life course has no start box and no countdown, and keeps its finish arch")
	var base := "user://wo_instant_fixture"
	DirAccess.make_dir_recursive_absolute(base + "/courses")
	DirAccess.make_dir_recursive_absolute(base + "/cfg")
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "wo_instant_fixture"
	var f := FileAccess.open(base + "/courses/wo_instant_fixture.json", FileAccess.WRITE)
	f.store_string(WoCourseDoc.to_json(doc))
	f.close()
	f = FileAccess.open(base + "/cfg/wo_instant_fixture.cfg", FileAccess.WRITE)
	f.store_string("wo_instant_death 1\n")
	f.close()
	var game := await _world(func(c: WoConfig) -> void:
		c.countdown_seconds = 3.0
		c.course_ids = PackedStringArray(["wo_instant_fixture"]))
	_check(not game.stage.instant, "a course with no cfg keeps its box")
	_check(game.catalogue.add_directory(base + "/courses") == 1, "the fixture course is found")
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 3)
	_check(game.stage.id() == &"wo_instant_fixture" and game.stage.instant
			and bool(game.course_doc.get("instant", false)),
		"its cfg makes it one life, and the document says so (a client builds the same)")
	var arches := 0
	for child in game.stage.get_children():
		if child.name == "Arch":
			arches += 1
	_check(game.stage.get_node_or_null("Gate") == null and not game.stage.gate_closed, "no gate")
	_check(arches == (game.course_doc["checkpoints"] as Array).size()
			and game.stage.get_node_or_null("FinishArch") != null, "checkpoint flags and a finish arch",
		"%d arches" % arches)
	_check(game.phase == WoGame.Phase.COURSE, "the round starts at once", str(game.phase))
	var start: Dictionary = game.course_doc["start"]
	var basis := Basis(Vector3.UP, deg_to_rad(float(start["yaw"])))
	var size: Vector2 = start["size"]
	runner.place_at((start["at"] as Vector3) + basis * Vector3(size.x * 0.5 + 0.5, 1.0, 0.0), 0.0)
	await _step(game, 2)
	_check(not _in_pen(game, runner.controller.state.position, 0.1), "and nothing holds them where the box was")
	DirAccess.remove_absolute(base + "/courses/wo_instant_fixture.json")
	DirAccess.remove_absolute(base + "/cfg/wo_instant_fixture.cfg")
	_finished()


func _test_a_ladder_climbs() -> void:
	_section("a ladder piece can be climbed")
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "test_ladder"
	(doc["pieces"] as Array).append({"kind": "ladder", "at": [12.0, 4.0, -20.0], "size": [0.1, 8.0, 1.6]})
	(doc["pieces"] as Array).append({"kind": "box", "at": [12.0, 8.2, -20.0], "size": [4.0, 0.4, 4.0]})
	var game := await _world(Callable(), doc)
	_check(game.stage.ladder_boxes().size() == 1, "the stage has the ladder's box")
	var runner := game.add_player(&"u1", "Ada")
	var yaw := 0.0
	for candidate in [0.0, 90.0, 180.0, 270.0]:
		if DotFpsMotor._view_basis(candidate, 0.0).forward.x > 0.9:
			yaw = candidate
	runner.place_at(Vector3(11.5, 3.0, -20.0), yaw)
	await _step(game, 20)
	for _i in range(150):
		var command := DotFpsCommand.new()
		command.move = Vector2(0.0, 1.0)
		command.yaw = yaw
		command.pitch = 50.0
		runner.controller.apply_command(command)
		await _step(game, 1)
	_check(runner.controller.state.position.y > 6.0, "walking into it and looking up climbs it",
		str(runner.controller.state.position))
	_finished()


func _test_the_carry() -> void:
	_section("a mover carries whoever is standing on it")
	var game := await _world()
	var rider := game.add_player(&"u1", "Ada")
	var mover := _piece(game, "mover")
	_check(not mover.is_empty(), "the practice course has a mover")

	var spec: Dictionary = mover["spec"]
	var period := float(spec["period"])
	# A tick where the mover is at its `from` end, so the next half period carries it to `to`.
	var tick := int(roundf(period * float(TICK_RATE))) * 4
	game._tick = tick - 1
	game.stage.pose_at(tick)
	var top := (spec["from"] as Vector3) + Vector3(0, (spec["size"] as Vector3).y * 0.5 + 0.05, 0)
	rider.place_at(top, 0.0)
	await _step(game, 6)
	var before := rider.controller.state.position
	await _step(game, int(period * 0.5 * TICK_RATE) - 6)
	var after := rider.controller.state.position
	var travelled := Vector2(after.x - before.x, after.z - before.z).length()
	var track := (spec["from"] as Vector3).distance_to(spec["to"])
	_check(travelled > track * 0.85, "standing still, the rider went most of the track",
		"%.2f of %.2f m" % [travelled, track])
	_check(after.y > (spec["from"] as Vector3).y - 0.2, "and is still on it", "y %.2f" % after.y)
	_finished()


func _test_the_turntable() -> void:
	_section("a turntable carries along the arc, not off the edge")
	var game := await _world(func(c: WoConfig) -> void: pass, _turntable_course())
	var rider := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	var disc := _piece(game, "turntable")
	var centre: Vector3 = disc["spec"]["at"]
	rider.place_at(centre + Vector3(2.5, 0.35, 0.0), 0.0)
	await _step(game, 4)
	var start_radius := Vector2(rider.controller.state.position.x - centre.x, rider.controller.state.position.z - centre.z).length()
	var start_angle := atan2(rider.controller.state.position.z - centre.z, rider.controller.state.position.x - centre.x)
	await _step(game, TICK_RATE * 3)
	var at := rider.controller.state.position
	var radius := Vector2(at.x - centre.x, at.z - centre.z).length()
	var angle := atan2(at.z - centre.z, at.x - centre.x)
	_check(absf(radius - start_radius) < 0.15, "the radius held over three seconds",
		"%.2f -> %.2f m" % [start_radius, radius])
	_check(absf(angle_difference(start_angle, angle)) > 0.5, "and the rider went round",
		"%.2f rad" % absf(angle_difference(start_angle, angle)))
	_finished()


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


func _test_ducking() -> void:
	_section("a high arm passes over somebody crouching under it")
	var game := await _world(func(c: WoConfig) -> void: pass, _high_arm_course())
	var standing := game.add_player(&"u1", "Ada")
	var crouching := game.add_player(&"u2", "Bo")
	var hub: Vector3 = _piece(game, "spinner")["spec"]["at"]
	standing.place_at(hub + Vector3(2.5, 0.05, 0.0), 0.0)
	crouching.place_at(hub + Vector3(-2.5, 0.05, 0.0), 0.0)
	var duck := DotFpsCommand.new()
	duck.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	for _i in range(TICK_RATE * 3):
		crouching.controller.apply_command(duck.duplicate_command())
		standing.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)

	_check(standing.knocks > 0, "standing, it hit them", "%d" % standing.knocks)
	_check(crouching.knocks == 0, "crouched, it did not", "%d" % crouching.knocks)
	_check(crouching.controller.state.crouch_fraction > 0.9 and standing.controller.state.crouch_fraction < 0.1,
		"the crouch fraction rises for the one ducking only", "%.2f" % crouching.controller.state.crouch_fraction)
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


func _test_course_cfg() -> void:
	_section("a course's cfg: set when it loads, put back when the next one does")
	var parsed := WoCourseCfg.parse("// one life\nwo_instant_death 1\n# c\n\nWO_COURSES_PER_ROUND \"2\"\nlonely\n")
	_check(parsed.size() == 2 and parsed[0] == ["wo_instant_death", "1"] and parsed[1] == ["wo_courses_per_round", "2"],
		"a file is a cvar and a value a line, comments and strays dropped", str(parsed))

	var console := DotConsole.new()
	add_child(console)
	var death := console.cvar("wo_instant_death", "0")
	var rounds := console.cvar("wo_courses_per_round", "3")
	var other := console.cvar("sv_other", "5")
	var cfg := WoCourseCfg.new()
	var text := "wo_instant_death 1\nwo_courses_per_round 2\nsv_other 9\nwo_nothing 1\n"
	_check(cfg.apply(console, text) == 2 and death.get_string() == "1" and rounds.get_string() == "2",
		"the course's lines are applied")
	_check(other.get_string() == "5", "and only wo_ cvars: a pack never sets anything else")
	var _set := rounds.set_value("4")
	_check(cfg.apply(console, "") == 0 and death.get_string() == "0",
		"the next course puts back what it changed")
	_check(rounds.get_string() == "4", "unless the operator changed it since")

	# The catalogue finds `<root>/../cfg/<id>.cfg` beside the courses directory.
	var base := "user://wo_cfg_fixture"
	DirAccess.make_dir_recursive_absolute(base + "/courses")
	DirAccess.make_dir_recursive_absolute(base + "/cfg")
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "wo_cfg_fixture"
	var f := FileAccess.open(base + "/courses/wo_cfg_fixture.json", FileAccess.WRITE)
	f.store_string(WoCourseDoc.to_json(doc))
	f.close()
	f = FileAccess.open(base + "/cfg/wo_cfg_fixture.cfg", FileAccess.WRITE)
	f.store_string("wo_instant_death 1\n")
	f.close()
	var catalogue := WoCatalogue.new()
	var read := catalogue.add_directory(base + "/courses")
	_check(read == 1 and catalogue.course_cfg.has(&"wo_cfg_fixture"),
		"the catalogue finds a course's cfg beside its directory", str(catalogue.course_cfg))
	_check(catalogue.course_cfg.size() == 1, "and a course without one has none")
	DirAccess.remove_absolute(base + "/courses/wo_cfg_fixture.json")
	DirAccess.remove_absolute(base + "/cfg/wo_cfg_fixture.cfg")
	console.queue_free()
	_finished()


func _test_a_bot_runs_the_course() -> void:
	_section("a stand-in runs the practice course to the finish, on its route")
	var game := await _world(func(c: WoConfig) -> void:
		c.bot_mistakes = 0.0
		c.countdown_seconds = 0.5
	)
	var bot := game.add_player(&"u900000", "Bot")
	bot.is_bot = true
	var other := game.add_player(&"u2", "Bo")
	game.start()
	var finished_at := -1.0

	for i in range(TICK_RATE * 40):
		other.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)

		if bot.finished:
			finished_at = game.course_elapsed
			break

	_check(bot.finished, "it finished", "%d falls, checkpoint %d, at %s" % [
		bot.falls, bot.checkpoint, bot.controller.state.position])
	_check(bot.place == 1, "first", "#%d" % bot.place)
	_check(finished_at > 0.0 and finished_at < 30.0, "inside thirty seconds", "%.1f s" % finished_at)
	_finished()


## How the stand-ins race: dot-bot's preset picks the column, an override outlives a preset,
## `bot_mistakes` 0 is never wrong, every bot is its own runner, and the finale aims through
## dot-bot's DotBotAim.
func _test_the_racers() -> void:
	_section("stand-ins race by bot_difficulty, each its own runner, and aim with dot-bot")
	var game := await _world()
	var settings := DotBotSettings.of(game)
	var racer: WoRacer = game.racer
	_check(racer != null and is_equal_approx(racer.value("fumble"), WoRacer.preset_value("medium", "fumble")),
		"medium by default, its fumble chance the medium column", "%s" % (racer.value("fumble") if racer != null else -1.0))
	var _hard := settings.set_difficulty("hard")
	_check(is_equal_approx(racer.value("hop_miss"), WoRacer.preset_value("hard", "hop_miss"))
			and racer.reaction() <= DotBotProfile.preset_value("hard", "reaction") + 0.001,
		"bot_difficulty hard moves the racing columns and the reaction with it")
	var _over := racer.set_value("fumble", "20")
	var _easy := settings.set_difficulty("easy")
	_check(is_equal_approx(racer.value("fumble"), 20.0) and is_equal_approx(racer.value("timing"), WoRacer.preset_value("easy", "timing")),
		"an override (wo_bot_fumble 20) outlives a preset change; the rest follow it")
	racer.mistakes = 0.0
	_check(racer.value("fumble") == 0.0 and racer.value("timing") == 0.0 and is_equal_approx(racer.value("landing"), 1.0)
			and racer.reaction() == 0.0,
		"bot_mistakes 0 is a stand-in that is never wrong")
	racer.overrides.clear()
	racer.mistakes = 1.0

	var a := game.add_player(&"u900010", "A")
	a.is_bot = true
	var b := game.add_player(&"u900011", "B")
	b.is_bot = true
	var fa := float(game._racer_of(a)["factor"])
	var fb := float(game._racer_of(b)["factor"])
	var spread := racer.value("variety")
	_check(not is_equal_approx(fa, fb) and absf(fa - 1.0) <= spread + 0.001 and absf(fb - 1.0) <= spread + 0.001,
		"two stand-ins are two runners: their own share of the mistakes", "%.2f and %.2f" % [fa, fb])

	# The finale's aim: dot-bot's DotBotAim, so the view turns at bot_turn_rate and the trigger
	# waits for bot_reaction after the target first comes into view.
	var _medium := settings.set_difficulty("medium")
	var profile := settings.profile
	a.place_at(Vector3(0.0, 0.0, 0.0), 0.0)
	b.place_at(Vector3(-8.0, 0.0, 6.0), 0.0)
	var command := DotFpsCommand.new()
	command.yaw = a.controller.state.yaw
	var first := -1.0
	var fastest := 0.0
	var start := game._bot_now()
	for _i in range(TICK_RATE * 2):
		var before := command.yaw
		(game._racer_of(a)["aim"] as DotBotAim).view_from(command.yaw, command.pitch)
		game._aim_bot(a, command, b)
		if command.is_pressed(DotFpsCommand.BUTTON_USER_0) and first < 0.0:
			first = game._bot_now() - start
		fastest = maxf(fastest, absf(wrapf(command.yaw - before, -180.0, 180.0)) * TICK_RATE)
		game._tick += 1
	_check(first >= profile.reaction * 0.85 and fastest <= profile.turn_rate * 1.02,
		"a stand-in in a final death turns at bot_turn_rate and fires only after bot_reaction",
		"first shot %.2f s, %.0f deg/s" % [first, fastest])
	_finished()


## Stand-ins are on a layer of their own: a person stops at one, two of them never meet.
func _test_stand_ins_pass_through_each_other() -> void:
	_section("stand-ins pass through each other, and a person still stops at one")
	var game := await _world()
	var person := game.add_player(&"u3", "Person")
	var bot := game.add_player(&"u900020", "Bot")
	bot.is_bot = true
	var other := game.add_player(&"u900021", "Other")
	other.is_bot = true
	var player_layer := game.physics.layer_mask(&"player")
	var bot_layer := game.physics.layer_mask(&"bot")
	_check(bot.collision_layer & bot_layer != 0 and person.collision_layer & player_layer != 0,
		"a stand-in is on the bot layer, a person on the player layer")
	_check(person.controller.body.collision_mask & bot_layer != 0 and person.controller.body.collision_mask & player_layer != 0,
		"a person's movement stops at stand-ins and at people")
	_check(bot.controller.body.collision_mask & bot_layer == 0 and bot.controller.body.collision_mask & player_layer != 0,
		"a stand-in's stops at people only")
	bot.is_bot = false
	_check(bot.collision_layer & player_layer != 0 and bot.controller.body.collision_mask & bot_layer != 0,
		"and a stand-in that becomes a person changes over")
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


## The show: a course's dressing survives validation (unknown kinds dropped), a client builds
## stands with a crowd and big screens, a server builds none; the announcer speaks.
func _test_the_show() -> void:
	_section("stands, a crowd and screens on a client, none on a server, and an announcer")
	var doc := WoCatalogue.practice()
	doc["dressing"] = [
		{"kind": "stands", "at": [9, 0.6, -20], "size": [20, 3.3, 5.4], "yaw": 90, "text": "SHOW"},
		{"kind": "screen", "at": [-10, 0, -10], "size": [9, 4, 0.4], "yaw": 160},
		{"kind": "a_kind_from_the_future", "at": [0, 0, 0]},
	]
	var checked := WoCourseDoc.validate(doc)
	_check(checked.ok and (checked.value["dressing"] as Array).size() == 2,
		"the dressing is kept and a kind this build does not know is dropped, never refused")
	var server := await _world(Callable(), doc)
	_check(server.stage.find_child("CrowdBodies", false, false) == null and server.stage.screen_count() == 0,
		"a server builds none of it")
	var client := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 0.0, {})
	client.stage.draw_world = true
	var _built := client.build_stage(doc)
	var crowd := client.stage.find_child("CrowdBodies", false, false) as MultiMeshInstance3D
	_check(crowd != null and crowd.multimesh.instance_count > 50 and client.stage.screen_count() == 1,
		"a client builds the stands full of people and the screen",
		"%d people" % (crowd.multimesh.instance_count if crowd != null else 0))
	client.stage.cheer(1.0)
	_check(client.stage.excitement >= 0.99, "and the crowd gets on its feet when it is cheered")

	var listener := _Lines.new()
	var announcer := WoAnnouncer.new(client, null, listener)
	var runner := client.add_player(&"u7", "Runner")
	announcer.me = &"u8"
	announcer.on_finished(runner.player_id, 1, 71.5)
	_check(listener.lines.size() == 1 and String(listener.lines[0]).contains("RUNNER WINS"),
		"the first home is announced as the winner", str(listener.lines))
	_finished()


class _Lines:
	extends RefCounted
	var lines: Array = []
	func announce(text: String, _seconds: float = 3.0) -> void:
		lines.append(text)


func _test_one_finisher_wins() -> void:
	_section("one side across the line wins the round outright")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 0.2; c.course_seconds = 12.0)
	var winner := game.add_player(&"u1", "Ada")
	var _loser := game.add_player(&"u2", "Bo")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	winner.place_at(finish["at"], 0.0)
	await _step(game, 3)
	_check(winner.finished and winner.place == 1, "crossing the finish finishes them")

	await _step(game, int(13.0 * TICK_RATE))
	_check(ended.size() == 1, "the round ended when the course closed", "%d" % ended.size())
	_check(not ended.is_empty() and int(ended[0][1]) == winner.team, "and their side won",
		str(ended[0]) if not ended.is_empty() else "")
	_check(game.stage.is_course(), "with no final death", str(game.stage.id()))
	_check(winner.points == game.config.finish_points[0] + game.config.winner_points and _loser.points == 0,
		"first across is %d points and the round's win %d more; the loser has none (%d, %d)" % [
			game.config.finish_points[0], game.config.winner_points, winner.points, _loser.points])
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(WoConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _world()
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	var id := a.player_id
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	a.watching = true
	game.spectate.on_died(id, b.player_id, false, Vector3(0, 2, 0), 0.0, 0)
	game.spectate.manager.set_mode(String(id), DotSpectatorView.Mode.CHASE)
	_check(game.spectate.can_roam(id), "somebody who is out may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")
	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")

	var restricted := await _world(func(c: WoConfig) -> void:
		c.spectate_camera = 1)
	_check(restricted.spectate_rules.force_camera == 1 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	var keys := WoBindings.make()
	_check(keys.defaults_on("G").size() == 1 and str(keys.row_for_action(WoBindings.ROAM).get("default", "")) == "G",
		"the free camera is on G, and nothing else defaults to G")
	_check(keys.defaults_on("C").size() == 1 and keys.defaults_on("Ctrl").size() == 1,
		"crouch is on Ctrl and on C (Ctrl+W closes a browser tab), and nothing else takes C")
	_finished()


func _test_the_final_death() -> void:
	_section("two sides across the line fight a final death in a drawn arena")
	var game := await _world(func(c: WoConfig) -> void:
		c.countdown_seconds = 0.2
		c.handover_seconds = 0.5
		c.finale_props_per_side = 4
		c.finale_weapons_per_side = 2
	)
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	var c := game.add_player(&"u3", "Cy")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	a.place_at(finish["at"], 0.0)
	await _step(game, 2)
	b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	_check(a.finished and b.finished and not c.finished, "two finished, one did not")

	# Nobody left on the course but Cy, so the course stays open: Cy is still running.
	_check(game.phase == WoGame.Phase.COURSE, "the course stays open while somebody is on it")

	# Close it by the clock, with Cy still on the course.
	game.course_elapsed = game.course_limit()
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.HANDOVER, "the course closed into a handover")
	_check(game.stage.is_arena(), "the stage is an arena now", str(game.stage.id()))
	_check(not a.watching and not b.watching and c.watching, "the finishers fight; the other watches")
	_check(a.health.invulnerable and b.health.invulnerable, "nobody can be hurt during the handover")

	var gallery: Dictionary = game.arena_doc["gallery"]
	_check(c.controller.state.position.distance_to(gallery["at"]) < 10.0, "the watcher is in the gallery")
	_check(a.controller.state.position.distance_to(b.controller.state.position) > 4.0,
		"the two sides start apart", "%.1f m" % a.controller.state.position.distance_to(b.controller.state.position))
	_check(game.props.world_count() > 0, "props were dropped in", "%d" % game.props.world_count())
	_check(game.pickups.size() > 0, "weapons were laid out", "%d" % game.pickups.size())

	await _step(game, int(0.6 * TICK_RATE))
	_check(game.phase == WoGame.Phase.FINALE and not a.health.invulnerable, "then the final death begins")

	# A weapon picked up off the floor.
	var pickup_id: int = game.pickups.keys()[0]
	var pickup: Dictionary = game.pickups[pickup_id]
	a.place_at((pickup["at"] as Vector3) - Vector3(0, 0.6, 0), 0.0)
	await _step(game, 3)
	_check(a.weapons != null and not game.pickups.has(pickup_id), "standing on a weapon picks it up")

	# A prop picked up and thrown at somebody.
	var prop: DotPropInstance = game.props.all_props()[0]
	var body := prop.body()
	body.global_position = b.controller.state.position + Vector3(0, 1.0, -3.0)
	body.linear_velocity = Vector3.ZERO
	var throw_from := body.global_position + Vector3(0, -0.6, -2.0)
	b.place_at(b.controller.state.position, 180.0)
	game._thrown[prop.instance_id] = {"by": a.player_id, "until": game.current_tick() + 120}
	body.linear_velocity = (b.controller.state.position + Vector3(0, 0.9, 0) - body.global_position).normalized() * 16.0
	var before := b.health.health
	await _step(game, 20)
	_check(b.health.health < before, "a thrown prop that meets somebody hurts them",
		"%.0f -> %.0f" % [before, b.health.health])
	var _unused := throw_from

	# The last one standing. Drawn first, as a client draws everybody it can see: the body that
	# falls is copied from this figure.
	var _drawn := b.present_body(false, b.controller.state.position, Color.WHITE)
	var damage := DotDamage.make(a.entity_id, b.entity_id, 500.0, null)
	damage.tick = game.current_tick()
	damage.direction = Vector3(1, 0, 0)
	var _applied := game.combat.apply_damage(damage)
	await _step(game, 3)
	_check(ended.size() == 1 and int(ended[0][1]) == a.team, "the last side standing wins",
		str(ended[0]) if not ended.is_empty() else "")

	# How the body falls: the server picked it, DEATH carries it, a client builds it.
	_check(b.death != null and b.death.direction.distance_to(Vector3(1, 0, 0)) < 0.01,
		"the server picked how the body falls, along the blow", str(b.death.describe()) if b.death != null else "none")
	var carried := WoEvents.read_death(DotNetReader.new(WoEvents.write_death(2, 1, WoGame.DIED_SHOT, b.death)))
	_check(bool(carried["ok"]) and carried.has("death") and (carried["death"] as DotPlayerDeath).reaction == b.death.reaction
		and not WoEvents.read_death(DotNetReader.new(WoEvents.write_death(2, 1, WoGame.DIED_SHOT))).has("death"),
		"DEATH carries it, and one without it still reads",
		str(WoEvents.read_death(DotNetReader.new(WoEvents.write_death(2, 1, WoGame.DIED_SHOT)))))
	var client := WoClient.new()
	client.game = game
	client._build_ragdolls()
	client.remove_child(client.ragdolls)
	add_child(client.ragdolls)
	client._fall(b)
	_check(client.ragdolls.live().size() == 1 and client.ragdolls.rules == game.ragdoll_rules,
		"a client builds the body from the figure it draws, under the game's rules")
	client.ragdolls.queue_free()
	client.free()
	_finished()


## dot-props' loose toys: beach balls in the start pen, balls in a finale's arena. A runner walks
## through one and sends it on without losing a step; a shot pushes one and goes on, because the
## combat's trace never sees a toy; a barrel's blast throws one; `sv_toys 0` takes them away.
func _test_the_toys() -> void:
	_section("toys: beach balls in the start pen, balls in the arena, never in anybody's way")
	var game := await _world()
	var toys := game.stage.toys
	var start: Vector3 = game.course_doc["start"]["at"]
	var in_pen := toys.toys.filter(func(t: DotPropToy) -> bool:
		return absf(t.global_position.x - start.x) < 5.0 and absf(t.global_position.z - start.z) < 4.0)
	_check(toys.count() == 2 and in_pen.size() == 2 and in_pen.all(func(t: DotPropToy) -> bool: return t.kind == &"ball"),
		"the practice course's two beach balls are in the start pen", "%d toys, %d in the pen" % [toys.count(), in_pen.size()])

	# Run into the right-hand ball across the pen, side on: it goes, the runner does not slow.
	var runner := game.add_player(&"u1", "Ada")
	var ball := toys.toy(1)
	var was := ball.body.global_position
	runner.place_at(Vector3(was.x - 3.0, start.y, was.z), -90.0)
	await _step(game, 4)
	var slowest := 100.0
	var met := false
	for _i in range(int(0.6 * TICK_RATE)):
		await _hold_for(game, runner, Vector2(0, 1), -90.0, 1)
		var flat := Vector2(runner.controller.state.velocity.x, runner.controller.state.velocity.z).length()
		if not met and ball.body.global_position.distance_to(was) > 0.05:
			met = true
		elif met and runner.controller.state.position.x < was.x + 0.3:
			slowest = minf(slowest, flat)
	_check(met and ball.body.global_position.distance_to(was) > 0.4, "a runner walking into a beach ball sends it on",
		"%.2f m" % ball.body.global_position.distance_to(was))
	_check(slowest > 0.9 * game.config.run_speed,
		"and loses no speed to it", "%.1f m/s at the slowest" % slowest)

	# The finale's arena: a shot down the line at a ball pushes it, and the combat's trace, which
	# is what decides who is hit, cannot see it.
	var _arena := game.build_stage(WoCatalogue.practice_arena())
	await _physics_frame()
	await _physics_frame()
	toys = game.stage.toys
	var football := toys.toy(1)
	var resting := football.body.global_position
	var shot := DotShot.new()
	shot.origin = resting + Vector3(-6.0, 0.0, 0.0)
	shot.direction = Vector3(1, 0, 0)
	shot.damage = 25.0
	shot.max_range = 40.0
	game._shoot_toys(shot)
	await _step(game, TICK_RATE / 2)
	_check(toys.count() == 2 and football.body.global_position.distance_to(resting) > 0.5,
		"the arena's balls are there, and a shot sends one off", "%.2f m" % football.body.global_position.distance_to(resting))
	var trace_mask := game.physics.layer_mask(&"world")
	_check(trace_mask & game.physics.layer_mask(&"toy") == 0 and football.body.collision_layer & trace_mask == 0,
		"and the combat's trace cannot meet one, so a ball is never cover")

	# A barrel going off beside the other ball throws it.
	var beach := toys.toy(0)
	var beach_was := beach.body.global_position
	game._on_prop_exploded(beach_was + Vector3(1.0, 0.0, 0.0), 4.0, 0.0, 0.0, &"")
	await _step(game, TICK_RATE / 2)
	_check(beach.body.global_position.distance_to(beach_was) > 0.5, "a barrel's blast throws a ball",
		"%.2f m" % beach.body.global_position.distance_to(beach_was))

	var _off := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	_check(not toys.toy(0).visible and toys.toy(0).process_mode == Node.PROCESS_MODE_DISABLED, "sv_toys 0 takes them away")
	var _on := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")
	_finished()


func _test_nobody_finishes() -> void:
	_section("nobody across the line: whoever got furthest wins")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 0.2; c.course_seconds = 10.0)
	var far := game.add_player(&"u1", "Ada")
	var _near := game.add_player(&"u2", "Bo")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	far.place_at(checkpoint["at"], 0.0)
	await _step(game, int(11.0 * TICK_RATE))
	_check(ended.size() == 1 and int(ended[0][1]) == far.team, "the one who reached a checkpoint won",
		str(ended[0]) if not ended.is_empty() else "")
	_finished()


func _test_knocks_hurt() -> void:
	_section("on the course a knock hurts, a bad one is fatal, a checkpoint heals")
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var victim := game.add_player(&"u1", "Ada")
	var other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	var hub: Vector3 = _piece(game, "spinner")["spec"]["at"]
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var before := victim.health.health
	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		if victim.knocks > 0:
			await _step(game, 1)
			break
	var expected := victim.last_knock_speed * game.config.knock_damage_per_speed
	_check(victim.knocks > 0 and absf((before - victim.health.health) - expected) < 1.0,
		"a knock costs health by how hard it threw them",
		"%.1f lost for a %.1f m/s throw" % [before - victim.health.health, victim.last_knock_speed])

	# Low enough that the next knock is fatal: out for the round, alive in the lounge.
	victim.health.health = 1.0
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var knocks := victim.knocks
	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		if victim.knocks > knocks:
			await _step(game, 2)
			break
	_check(victim.watching and victim.is_alive(), "a fatal knock takes them out of the round, watching")
	_check(not game._course_is_over() or other.finished, "and the course goes on for the rest")

	other.finished = true
	_check(game._course_is_over(), "with everybody finished or out, the course is over")
	other.finished = false

	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	other.health.health = 30.0
	other.place_at(checkpoint["at"], 0.0)
	await _step(game, 3)
	_check(other.health.health >= other.health.max_health - 0.01, "a checkpoint heals (%.0f)" % other.health.health)
	_finished()


func _test_courses_per_round() -> void:
	_section("a round runs courses_per_round courses, but only while more than one side finishes")
	var game := await _world(func(c: WoConfig) -> void:
		c.courses_per_round = 2
		c.countdown_seconds = 0.2
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int(1.0 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	a.place_at(finish["at"], 0.0)
	await _step(game, 2)
	b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	var points := a.points
	_check(game.phase == WoGame.Phase.COUNTDOWN and game.stage.is_course(),
		"two finished on course 1 of 2: a second course, not the final death", str(game.phase))
	_check(not a.finished and not b.finished and a.points == points and points > 0,
		"everybody is back to run it, with the points kept", str(a.points))
	_check(a.health.health >= a.health.max_health - 0.01, "and healed")
	await _step(game, int((game.config.countdown_seconds + 0.4) * TICK_RATE))
	_check(game.phase == WoGame.Phase.COURSE, "the second course is running")
	a.place_at(finish["at"], 0.0)
	await _step(game, 2)
	b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.HANDOVER and game.stage.is_arena(),
		"two finished on course 2 of 2: the final death", str(game.phase))

	# One finisher ends the round at once however many courses it was going to run.
	var solo := await _world(func(c: WoConfig) -> void:
		c.courses_per_round = 3
		c.countdown_seconds = 0.2
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var c1 := solo.add_player(&"u1", "Ada")
	var _c2 := solo.add_player(&"u2", "Bo")
	var ended: Array = []
	solo.round_over.connect(func(n: int, w: int, _why: String) -> void: ended.append([n, w]))
	solo.start()
	await _step(solo, int(1.0 * TICK_RATE))
	c1.place_at((solo.course_doc["finish"] as Dictionary)["at"], 0.0)
	await _step(solo, 2)
	solo.course_elapsed = solo.course_limit()
	await _step(solo, 2)
	_check(ended.size() == 1 and int(ended[0][1]) == c1.team and solo.phase != WoGame.Phase.HANDOVER,
		"one finisher of three courses: the round ends there, no more courses", str(ended))
	_finished()


func _test_hard_landings() -> void:
	_section("falls and hits cost health by how bad they were; health can be switched off")
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var victim := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))
	var start := victim.global_position

	# A drop under the safe height is free; a high one costs per metre past it.
	victim.place_at(start + Vector3(0.0, 1.5, 0.0), 0.0)
	await _step(game, int(1.5 * TICK_RATE))
	_check(victim.health.health >= victim.health.max_health - 0.01, "a one and a half metre drop is free")

	var expected := (8.0 - game.config.fall_safe_height) * game.config.fall_damage_per_metre
	victim.place_at(start + Vector3(0.0, 8.0, 0.0), 0.0)
	await _step(game, int(2.0 * TICK_RATE))
	var lost := victim.health.max_health - victim.health.health
	_check(absf(lost - expected) < 8.0 and lost > 0.0, "an eight metre drop costs per metre past the safe height",
		"%.1f lost, about %.1f expected" % [lost, expected])

	victim.health.health = victim.health.max_health
	var hard := victim.global_position
	game.config.health_enabled = false
	victim.place_at(hard + Vector3(0.0, 8.0, 0.0), 0.0)
	await _step(game, int(2.0 * TICK_RATE))
	_check(victim.health.health >= victim.health.max_health - 0.01, "with health off the same fall costs nothing")
	game.config.health_enabled = true

	# The lower the health, the wilder the knockout.
	var wild_5 := game.fling_wildness(5.0)
	var wild_40 := game.fling_wildness(40.0)
	_check(wild_5 > wild_40 and wild_40 > 0.0 and game.fling_wildness(80.0) == 0.0,
		"wildness grows as health falls and is nothing when healthy", "%.2f %.2f" % [wild_5, wild_40])
	game.config.knockout_fling_below = 0.0
	_check(game.fling_wildness(1.0) == 0.0, "knockout_fling_below 0 turns the flight off")
	game.config.knockout_fling_below = 0.5

	var hurt := DotDamage.make(0, victim.entity_id, 10.0, null)
	hurt.direction = Vector3(1.0, 0.0, 0.0)
	hurt.context = {"why": WoGame.DIED_KNOCKED, "health_before": 5.0}
	var low := game.decide_death(victim, hurt)
	hurt.context = {"why": WoGame.DIED_KNOCKED, "health_before": 40.0}
	var mid := game.decide_death(victim, hurt)
	hurt.context = {"why": WoGame.DIED_KNOCKED, "health_before": 90.0}
	var healthy := game.decide_death(victim, hurt)
	_check(low.reaction == WoGame.FLING and mid.reaction == WoGame.FLING and healthy.reaction != WoGame.FLING
		and low.damage > mid.damage, "5 hp and 40 hp are flung, 5 harder; 90 hp falls as the rules pick",
		"%.0f %.0f" % [low.damage, mid.damage])
	_check(WoGame.death_reactions().has(WoGame.FLING), "the fling is a reaction both ends know")

	# A real punch at 5 hp: out of the round, and the death that travels is the flight.
	var hub: Vector3 = _piece(game, "spinner")["spec"]["at"]
	victim.health.health = 5.0
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		if victim.watching:
			break
	_check(victim.watching and victim.death != null and victim.death.reaction == WoGame.FLING
		and victim.death.damage > 100.0, "a knock at 5 hp knocks them out with a flinging death",
		str(victim.death.describe()) if victim.death != null else "no death")

	# The same blow with health off costs nothing.
	game.config.health_enabled = false
	var other_victim := game.add_player(&"u3", "Cy")
	other_victim.health.health = 5.0
	other_victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	for _i in range(TICK_RATE * 3):
		await _step(game, 1)
	_check(not other_victim.watching and other_victim.health.health >= 5.0 and other_victim.knocks > 0,
		"with health off a knock still throws but never hurts", str(other_victim.knocks))
	_finished()


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


func _piece(game: WoGame, kind: String) -> Dictionary:
	for piece in game.stage.pieces:
		if str(piece["kind"]) == kind:
			return piece

	return {}


## Holds a direction for [param ticks]. Applied every tick, because the motor repeats a
## starved tick's view and buttons but drops its movement.
func _hold_for(game: WoGame, player: WoPlayer, move: Vector2, yaw: float, ticks: int) -> void:
	for _i in range(ticks):
		var command := DotFpsCommand.new()
		command.move = move
		command.yaw = yaw
		player.controller.apply_command(command)
		await _step(game, 1)


func _turntable_course() -> Dictionary:
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "test_turntable"
	(doc["pieces"] as Array).append({"kind": "turntable", "at": [20.0, -0.3, -10.0], "radius": 4.0,
		"thickness": 0.6, "speed": 40.0})
	return doc


func _high_arm_course() -> Dictionary:
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "test_high_arm"
	doc["pieces"] = [
		{"kind": "box", "at": [20.0, -0.5, -10.0], "size": [10.0, 1.0, 10.0]},
		{"kind": "spinner", "at": [20.0, 0.0, -10.0], "arm_length": 4.0, "arm_height": 1.5,
			"arm_thickness": 0.3, "speed": 90.0, "arms": 1},
	]
	return doc


## The machinery is heard, and from the course alone: an arm or a hammer going past, a ram
## arriving, a tile starting its warning. A real course of each kind, a listener stood beside
## one machine, twelve seconds of frames, and what dot-audio's null sink recorded.
func _test_the_machinery_is_heard() -> void:
	_section("the machinery is heard, from the course and nothing else")
	# One machine of each kind, copied from the course it was measured on, in the built-in
	# practice course: the courses are mg-wipeout-maps, which CI does not link, and a test
	# that read them heard nothing there and failed five checks.
	var cases := [
		["wo_spin_cycle", "spinner", WoAudio.MACHINE_WHOOSH, "an arm sweeping past"],
		["wo_hammer_gauntlet", "pendulum", WoAudio.MACHINE_WHOOSH, "a hammer through the bottom of its swing"],
		["wo_punch_alley", "pusher", WoAudio.MACHINE_RAM, "a ram at full reach"],
		["wo_trapdoor_run", "tiles", WoAudio.MACHINE_TILE, "a tile starting its warning"],
	]

	for case: Array in cases:
		var doc := _machine_course(str(case[1]))
		var heard := 0

		if not doc.is_empty():
			var game := await _world(Callable(), doc)
			var audio := WoAudio.new()
			add_child(audio)
			var _ready_now := audio.setup()
			var sink := audio.manager.sink as DotAudioSinkNull
			var listener := _beside_a(game.stage, str(case[1]))
			# The ears first, as the client puts them every frame: the manager culls by
			# distance from them, and left at the origin it culled a spinner 34 m away.
			audio.listen_from(listener)

			for frame in range(12 * 60):
				var _started := audio.present_machinery(game.stage, float(frame) / 60.0, listener)

			heard = sink.count_of(case[2]) if sink != null else 0
			audio.queue_free()

		_check(heard > 0, "%s is heard (%s)" % [case[3], case[0]], "%d" % heard)

	# A jump in time is not a sweep: a new stage's first frame plays nothing.
	var doc := _machine_course("spinner")
	var jumped := -1

	if not doc.is_empty():
		var game := await _world(Callable(), doc)
		var audio := WoAudio.new()
		add_child(audio)
		var _ready_now := audio.setup()
		var listener := _beside_a(game.stage, "spinner")
		audio.listen_from(listener)
		var _first := audio.present_machinery(game.stage, 0.0, listener)
		var _second := audio.present_machinery(game.stage, 0.05, listener)
		# 0.05 to 2.85 s carries the second arm across the listener's bearing (it is there at
		# 2.77 s): a jump that, read as a sweep, IS one. A longer jump can alias both arms back
		# to the side they started on and pass with the guard taken out.
		jumped = audio.present_machinery(game.stage, 2.85, listener)
		audio.queue_free()

	_check(jumped == 0, "and a jump in time plays nothing", "%d" % jumped)

	# The shipped .ogg files win over the synthesised bank, so only an id without one is a stand-in.
	var standins := WoAudio.standin_ids(WoAudio.sound_catalogue())
	_check(not standins.has("air_horn") and not standins.has("crowd_cheer"),
		"ids with a packed file are not reported as stand-ins", str(standins))

	# A frame landing exactly on the bottom of a hammer's swing (angle 0, phase 0 at t = 0)
	# is one crossing, not two: into 0 and out of it. Armed by putting `signf` back.
	var hammer := {"pivot": Vector3(0.0, 5.0, 0.0), "length": 4.0, "swing": 40.0, "period": 2.0, "phase": 0.0}
	var ears := Vector3(0.0, 1.0, 2.0)
	var bottom_audio := WoAudio.new()
	add_child(bottom_audio)
	var _set := bottom_audio.setup()
	bottom_audio.listen_from(ears)
	var through := bottom_audio._hear_pendulum(hammer, -0.02, 0.0, ears) + bottom_audio._hear_pendulum(hammer, 0.0, 0.02, ears)
	bottom_audio.queue_free()
	_check(through == 1, "and a frame exactly at the bottom of a swing whooshes once", "%d" % through)
	_finished()


## The practice course with its own [param kind] pieces swapped for one copied from the
## course each sound was measured on (`wo_spin_cycle`, `wo_hammer_gauntlet`,
## `wo_punch_alley`, `wo_trapdoor_run`), so the timings in the checks above still hold.
static func _machine_course(kind: String) -> Dictionary:
	var machines := {
		"spinner": {"kind": "spinner", "at": [0.0, 0.0, -34.3], "arm_length": 5.2, "arm_height": 0.6,
			"arm_thickness": 0.35, "speed": 65, "arms": 2, "phase": 0.0, "hub_radius": 0.6},
		"pendulum": {"kind": "pendulum", "pivot": [0.0, 6.2, -16.2], "length": 5.0, "radius": 0.95,
			"swing": 55.0, "period": 3.0, "phase": 0.0, "yaw": 0.0},
		"pusher": {"kind": "pusher", "at": [2.2, 0.9, -16.5], "size": [1.6, 1.6, 1.4], "yaw": 90.0,
			"reach": 2.4, "period": 2.6, "duty": 0.35, "phase": 0.0},
		"tiles": {"kind": "tiles", "at": [0.0, -0.25, -17.65], "cols": 3, "rows": 4, "tile": 2.0,
			"gap": 0.3, "thickness": 0.5, "period": 3.4, "down": 0.25, "seed": 3},
	}
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "wo_test_%s" % kind
	var pieces: Array = []
	for piece: Dictionary in doc["pieces"]:
		if str(piece.get("kind", "")) != kind:
			pieces.append(piece)
	pieces.append((machines[kind] as Dictionary).duplicate(true))
	doc["pieces"] = pieces
	return doc


## A point a listener stands at, a little way off the first piece of [param kind].
static func _beside_a(course: WoCourse, kind: String) -> Vector3:
	for piece: Dictionary in course.pieces:
		if str(piece.get("kind", "")) != kind:
			continue

		var spec: Dictionary = piece["spec"]

		match kind:
			"spinner":
				return (spec["at"] as Vector3) + Vector3(float(spec["arm_length"]) * 0.6, 1.0, 0.0)
			"pendulum":
				return (spec["pivot"] as Vector3) + Vector3(0.0, -float(spec["length"]), 2.0)
			_:
				return (spec["at"] as Vector3) + Vector3(0.0, 1.0, 1.5)

	return Vector3.ZERO
