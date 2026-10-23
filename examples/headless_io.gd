extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourseIo := preload("../game/wo_course_io.gd")
const WoEvents := preload("../game/net/wo_events.gd")
const WoGame := preload("../game/wo_game.gd")

## A course that runs its map's own entities (dot-map's DotMapWorld), played on the server's step.
##
## A bot cannot finish such a course: its buttons, doors and pushes are the puzzle and no route
## document describes them. So what is checked is the machinery, on the real map: the world loads
## with nothing its entities ask for left unhandled, a runner spawns on the map's own spawn
## points, every kind of thing the map does fires from a body or a press (a hurt volume, a push,
## a button through the use key, a trigger that starts a mover), the movers move, a mover carries
## a runner standing on it, and the state reaches a client over the wire format.

## Each course and what it must run: [sections, checks, lava room (a hurt that a trigger enables after a delay), ladder,
## a push that starts on (default true)].
const COURSES := {
	&"wo_oaks_course": [8, 28, false, false],
	&"wo_office_course": [10, 33, true, true],
	&"wo_dans_course": [9, 30, false, true],
	&"wo_pauls_course": [8, 26, false, false, false],
	&"wo_scary_course": [8, 26, false, false, false],
}
const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()
var _world: WoGame = null
var _expect_sections := 0
var _expect_checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: courses run by their map's own entities")
	print("")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")

	for id: StringName in COURSES:
		if not catalogue.courses.has(id):
			print("(%s is not installed: no mg-wipeout-maps link, nothing to check)" % id)
			continue

		var plan: Array = COURSES[id]
		_expect_sections += int(plan[0])
		_expect_checks += int(plan[1])
		print("== %s" % id)
		await _play(catalogue, id, bool(plan[2]), bool(plan[3]), plan.size() < 5 or bool(plan[4]))

	_report(_expect_sections, _expect_checks)


func _play(catalogue: WoCatalogue, id: StringName, lava: bool, ladders: bool, wants_push: bool) -> void:
	var doc: Dictionary = catalogue.courses[id]

	_section("the document")
	_check(catalogue.refused.is_empty(), "none was refused", str(catalogue.refused))
	_check(_io_piece(doc), "its world piece runs the map's entities")
	_check(bool(doc.get("instant", false)), "and it is a one-life course")
	_finished()

	var game := await _fresh_world(doc)
	var runner := game.add_player(&"u1", "Runner")
	var second := game.add_player(&"u3", "Second")
	game.start()
	await _until(game, WoGame.Phase.COURSE)
	var io := game.stage.io
	var world := io.world
	var manifest: Dictionary = world.mesh.manifest

	_section("the world loads")
	_check(world != null, "dot-map built it")
	_check(game.stage.io_spawns().size() > 0, "the map names its spawn points", str(game.stage.io_spawns().size()))
	var coverage := world.io.coverage()
	var unhandled: Dictionary = coverage["unhandled"]
	print("  unhandled by the entity runtime: %s" % str(unhandled))
	_check(unhandled.is_empty(), "nothing the map's links ask for is unhandled", str(unhandled.keys()))
	_check((coverage["unresolved"] as Dictionary).is_empty(), "every link's target exists", str(coverage["unresolved"]))
	_check((manifest["entity_report"]["unknown"] as Dictionary).is_empty(), "no entity class is unknown",
		str(manifest["entity_report"]["unknown"]))
	_finished()

	_section("a runner spawns")
	var spawn := _nearest_spawn(game, runner.controller.state.position, manifest)
	var from := runner.controller.state.position
	_check(spawn < 2.5, "on one of the map's spawn points", "%.2f m from the nearest" % spawn)
	_check(runner.is_alive() and not runner.finished, "alive and in the round")
	await _steps(game, 90)
	_check(runner.controller.state.position.y > from.y - 1.0, "standing on its floor a second and a half later",
		"%s to %s" % [from, runner.controller.state.position])
	_finished()

	_section("the machinery moves")
	var movers := 0
	var moving := 0

	for e: DotMapEntity in world.io.entities:
		if e is DotMapMoverNode and (e as DotMapMoverNode).node != null:
			var mover := e as DotMapMoverNode
			movers += 1
			if not mover.pose_delta(0, TICK_RATE).is_equal_approx(mover.pose_delta(300, TICK_RATE)):
				moving += 1

	_check(movers > 0, "the map has movers", str(movers))
	_check(moving > 0, "some are in a different place five seconds on", "%d of %d" % [moving, movers])
	_finished()

	# What the course's own cfg turns on when it loads (headless_mapcfg checks that it does).
	game.config.instant_death = true
	_section("a body in a volume")
	var before: Dictionary = game.io_log.duplicate()
	var floor_y := float(doc["water_height"])
	var pushes := _volumes(manifest, "push", false, 0.0, floor_y)
	var hurts := _volumes(manifest, "hurt", false, 100.0, floor_y)
	if wants_push:
		_check(not pushes.is_empty(), "the map has a push that starts on")
	_check(not hurts.is_empty(), "and a hurt volume that starts on")

	# Roomiest first; the first that answers is the one checked (a volume may sit in a room a teleport
	# empties, or behind a filter; a hurt that does not kill at once is followed by the next).
	if wants_push and not pushes.is_empty():
		for pushed in pushes:
			runner.place_at(pushed["centre"], 0.0)
			await _steps(game, 4)
			if int(game.io_log["pushes"]) > int(before["pushes"]):
				break

		_check(int(game.io_log["pushes"]) > int(before["pushes"]), "the push moves the runner", str(game.io_log))

	if not hurts.is_empty():
		var other := game.add_player(&"u2", "Other")
		await _steps(game, 2)
		var struck := int(game.io_log["hurts"])

		for hurt in hurts:
			other.place_at(hurt["centre"], 0.0)
			await _steps(game, 4)
			if other.out_for_round:
				break

		_check(int(game.io_log["hurts"]) > struck, "the hurt volume hits a runner", str(game.io_log))
		_check(other.out_for_round and other.watching, "and a one-life course puts him out for the round")
		_check(runner.is_alive(), "while the runner is still in the round")
	_finished()

	world = game.stage.io.world
	_section("a button")
	var buttons := _buttons(world)
	_check(not buttons.is_empty(), "the map has a button")

	if not buttons.is_empty():
		# A fresh body: the runner may have been carried over the finish line by the push check.
		var presser := game.add_player(&"u7", "Presser")
		await _steps(game, 2)
		var seen := int(game.io_log["uses"])
		var pressed := world.io.delivered
		var used := false

		# Each button in turn, from each side, eyes on its middle, the grab key pressed for one tick: the first
		# that answers and delivers is the one checked (some start locked or sit behind a door).
		for button in buttons:
			var box := _centre_of(button)
			for side in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
				# At the height the button's own eyes would be, and at floor level with the head tipped down
				# to it (a button low on a wall is pressed looking down).
				for drop in [1.6, 1.1, 0.6]:
					var feet := Vector3(box.x + side.x * 1.2, box.y - drop, box.z + side.y * 1.2)
					var yaw := rad_to_deg(atan2(side.x, side.y))
					presser.place_at(feet, yaw)
					var to := box - presser.eye_position()
					var pitch := rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
					var look := DotFpsCommand.new()
					look.yaw = yaw
					look.pitch = pitch
					presser.controller.apply_command(look)
					presser.wants_grab = true
					await _steps(game, 1)
					presser.wants_grab = false
					presser.controller.apply_command(look)
					await _steps(game, 1)

					if int(game.io_log["uses"]) > seen:
						break

				if int(game.io_log["uses"]) > seen:
					break

			# A button with outputs to deliver ends the search; one without (a switch that only gates another) does not.
			if int(game.io_log["uses"]) > seen:
				used = true
				await _steps(game, 40)

				if world.io.delivered > pressed:
					break

				seen = int(game.io_log["uses"])

		_check(used, "the use key presses it from where a runner stands", str(game.io_log))
		_check(world.io.delivered > pressed, "and its OnPressed outputs are delivered", "%d before, %d after" % [pressed, world.io.delivered])
	_finished()

	if lava:
		await _lava_room(game, world)

	if ladders:
		await _ladder(game, world)

	_section("the finish")
	var finisher := game.add_player(&"u6", "Finisher")
	await _steps(game, 2)
	_check(not finisher.finished, "a body on the spawn has not finished")
	var finish: Vector3 = (doc["finish"] as Dictionary)["at"]
	finisher.place_at(finish + Vector3(0.0, 0.1, 0.0), 0.0)
	await _steps(game, 4)
	_check(finisher.finished, "standing in the last room ends the course for the runner")
	_finished()

	_section("the state reaches a client")
	var inbox: Array = []
	game.stage.io_message.connect(func(peer: Variant, msg: Dictionary) -> void: inbox.append([peer, msg]))
	io.add_peer(7)
	await _steps(game, 3)
	_check(not inbox.is_empty(), "a joiner is sent a snapshot", str(inbox.size()))

	var wired := true
	var tick := 0
	var client := WoCourseIo.new()
	var piece := {}

	for candidate: Dictionary in doc["pieces"]:
		if str(candidate["kind"]) == "world":
			piece = candidate

	var client_world := client.build(piece, id, {}, false, false, TICK_RATE)
	add_child(client_world)
	_check(client_world != null, "a client builds the same world without its logic")

	for entry: Array in inbox:
		var back := WoEvents.read_world_io(DotNetReader.new(WoEvents.write_world_io(entry[1])))
		wired = wired and bool(back["ok"]) and str((back["msg"] as Dictionary).get("stage")) == String(id)
		client.apply(back["msg"])
		tick = maxi(tick, int((back["msg"] as Dictionary).get("tick", 0)))

	_check(wired, "every message survives the wire format", str(inbox.size()))
	_check(client.base == io.base and client_world.io.now >= tick, "and sets the client's clock to the server's",
		"base %d, now %d, tick %d" % [client.base, client_world.io.now, tick])
	# Its colliders sit in the one physics space the next course is built in.
	remove_child(client_world)
	client_world.free()
	_finished()


func _report(sections: int, checks: int) -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_sections_finished, _sections_entered, sections])
		code = 1

	if checks > 0 and _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	get_tree().quit(code)


## The hurt that a trigger enables three seconds after somebody steps in (the lava room's own links): quiet
## at two seconds, striking at three and a half.
func _lava_room(game: WoGame, world: DotMapWorld) -> void:
	_section("the lava room heats up three seconds after entry")
	var room := _named_volume(world.mesh.manifest, "hurt", "Obstacle2_Hurt")
	_check(not room.is_empty(), "the map has the room's hurt volume, disabled until triggered")

	if not room.is_empty():
		var victim := game.add_player(&"u9", "Lava")
		await _steps(game, 2)
		var struck := int(game.io_log["hurts"])
		var centre: Vector3 = room["centre"]
		victim.place_at(Vector3(centre.x, room["floor"], centre.z), 0.0)
		await _steps(game, 2 * TICK_RATE)
		_check(int(game.io_log["hurts"]) == struck and not victim.out_for_round, "two seconds in, nothing has happened")
		await _steps(game, int(1.5 * TICK_RATE))
		_check(int(game.io_log["hurts"]) > struck and victim.out_for_round, "at three and a half the floor has hurt him out of the round",
			str(game.io_log))
	_finished()


## Walks into the first ladder box looking up, from each side in turn: a ladder is climbed when any side gains height.
func _ladder(game: WoGame, world: DotMapWorld) -> void:
	_section("a ladder climbs")
	var boxes := world.ladder_boxes()
	_check(not boxes.is_empty(), "the map has ladders", str(boxes.size()))
	var best := -INF
	var tried := AABB()

	if not boxes.is_empty():
		var climber := game.add_player(&"u8", "Climber")
		await _steps(game, 2)

		# At the middle of each ladder, a hand's breadth off its face on each side in turn, looking up and
		# pushing forward (a body that touches one and falls past it is on it): it must go up.
		for box in boxes:
			if best > 1.5:
				break
			tried = box
			var normal_x := box.size.x < box.size.z
			var centre := box.get_center()

			for sign in [1.0, -1.0]:
				var face := Vector3(sign, 0.0, 0.0) if normal_x else Vector3(0.0, 0.0, sign)
				var half := (box.size.x if normal_x else box.size.z) * 0.5
				var yaw := 0.0
				for candidate in [0.0, 90.0, 180.0, 270.0]:
					if DotFpsMotor._view_basis(candidate, 0.0).forward.dot(-face) > 0.9:
						yaw = candidate
				climber.place_at(Vector3(centre.x, centre.y - 0.5, centre.z) + face * (half + 0.3), yaw)
				await _steps(game, 3)
				var start_y := climber.controller.state.position.y
				var top := start_y

				for _i in range(60):
					var command := DotFpsCommand.new()
					command.move = Vector2(0.0, 1.0)
					command.yaw = yaw
					command.pitch = 50.0
					climber.controller.apply_command(command)
					await _steps(game, 1)
					top = maxf(top, climber.controller.state.position.y)

				best = maxf(best, top - start_y)
				if best > 1.5:
					break

		_check(best > 1.5, "walking into it and looking up climbs it", "%.2f m gained, ladder %s" % [best, tried])
	_finished()


func _named_volume(manifest: Dictionary, kind: String, target: String) -> Dictionary:
	for v: Dictionary in manifest["volumes"]:
		if str(v["kind"]) == kind and str(v.get("targetname", "")) == target:
			var extent := _brush_extent(v)
			return {"centre": extent.get_center(), "floor": extent.position.y}
	return {}


func _io_piece(doc: Dictionary) -> bool:
	for piece: Dictionary in doc["pieces"]:
		if str(piece["kind"]) == "world" and bool(piece.get("io", false)):
			return true
	return false


func _nearest_spawn(game: WoGame, at: Vector3, manifest: Dictionary) -> float:
	var best := INF

	# A map may move everybody off its spawn room at once (a teleport to its real start).
	for dest: Dictionary in (manifest.get("destinations", {}) as Dictionary).values():
		var where: Array = dest["at"]
		best = minf(best, Vector3(where[0], where[1], where[2]).distance_to(at))

	for spawn: Dictionary in game.stage.io_spawns():
		var origin: Vector3 = spawn["origin"]
		best = minf(best, origin.distance_to(at))

	return best


## The volumes of [param kind] in the manifest that are not [param disabled], roomiest first, each with its
## middle (a thin slab is no place to stand a body for a check), above [param floor_y] (a body below the water
## is out of the round, as on a map's side arena). At most eight.
func _volumes(manifest: Dictionary, kind: String, disabled: bool, damage: float, floor_y: float) -> Array:
	var found: Array = []

	for v: Dictionary in manifest["volumes"]:
		if str(v["kind"]) != kind or bool(v.get("disabled", false)) != disabled:
			continue
		if float(v.get("damage", 0.0)) < damage:
			continue
		var extent := _brush_extent(v)
		var size := extent.size.x * extent.size.y * extent.size.z
		if extent.size.is_finite() and extent.get_center().y > floor_y:
			found.append({"entity": v["entity"], "centre": extent.get_center(), "room": size})

	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["room"]) > float(b["room"]))
	return found.slice(0, 8)


## The box of a volume's first brush, from its axis-aligned planes.
func _brush_extent(v: Dictionary) -> AABB:
	var lo := Vector3(-INF, -INF, -INF)
	var hi := Vector3(INF, INF, INF)

	for plane: Array in v["brushes"][0]:
		for axis in 3:
			if absf(float(plane[axis])) < 0.99:
				continue
			var bound := float(plane[3]) * signf(float(plane[axis]))
			if float(plane[axis]) > 0.0:
				hi[axis] = minf(hi[axis], bound)
			else:
				lo[axis] = maxf(lo[axis], bound)

	return AABB(lo, hi - lo) if lo.is_finite() and hi.is_finite() else AABB(Vector3.ZERO, Vector3(INF, INF, INF))


func _buttons(world: DotMapWorld) -> Array[DotMapMoverNode]:
	var out: Array[DotMapMoverNode] = []
	for e: DotMapEntity in world.io.entities:
		if e.classname == "func_button" and e is DotMapMoverNode and (e as DotMapMoverNode).node != null:
			out.append(e as DotMapMoverNode)
	return out


func _centre_of(mover: DotMapMoverNode) -> Vector3:
	for shape: CollisionShape3D in mover.node.find_children("*", "CollisionShape3D", true, false):
		if shape.shape != null:
			return (shape.global_transform * shape.shape.get_debug_mesh().get_aabb()).get_center()
	return (mover.node as Node3D).global_position


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
