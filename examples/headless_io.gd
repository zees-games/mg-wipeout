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

const COURSE_ID := &"wo_oaks_course"
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
	print("wipeout: a course run by its map's own entities")
	print("")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")

	if not catalogue.courses.has(COURSE_ID):
		print("(%s is not installed: no mg-wipeout-maps link, nothing to check)" % COURSE_ID)
		get_tree().quit(0)
		return

	var doc: Dictionary = catalogue.courses[COURSE_ID]

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
	var spawn := _nearest_spawn(game, runner.controller.state.position)
	var from := runner.controller.state.position
	_check(spawn < 2.5, "on one of the map's spawn points", "%.2f m from the nearest" % spawn)
	_check(runner.is_alive() and not runner.finished, "alive and in the round")
	await _steps(game, 90)
	_check(runner.controller.state.position.y > from.y - 0.5, "standing on its floor a second and a half later",
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
	var pushed := _volume(manifest, "push", false)
	var hurt := _volume(manifest, "hurt", false, 100.0)
	_check(not pushed.is_empty(), "the map has a push that starts on")
	_check(not hurt.is_empty(), "and a hurt volume that starts on")

	if not pushed.is_empty():
		runner.place_at(pushed["centre"], 0.0)
		await _steps(game, 4)
		_check(int(game.io_log["pushes"]) > int(before["pushes"]), "the push moves the runner", str(game.io_log))

	if not hurt.is_empty():
		var other := game.add_player(&"u2", "Other")
		await _steps(game, 2)
		var struck := int(game.io_log["hurts"])
		other.place_at(hurt["centre"], 0.0)
		await _steps(game, 4)
		_check(int(game.io_log["hurts"]) > struck, "the hurt volume hits a runner", str(game.io_log))
		_check(other.out_for_round and other.watching, "and a one-life course puts him out for the round")
		_check(runner.is_alive(), "while the runner is still in the round")
	_finished()

	world = game.stage.io.world
	_section("a button")
	var button := _button(world)
	_check(button != null, "the map has a button")

	if button != null:
		var seen := int(game.io_log["uses"])
		var pressed := world.io.delivered
		var box := _centre_of(button)

		# From each side in turn, eyes on its middle, the grab key pressed for one tick.
		for side in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
			var feet := Vector3(box.x + side.x * 1.2, box.y - 1.6, box.z + side.y * 1.2)
			runner.place_at(feet, rad_to_deg(atan2(side.x, side.y)))
			runner.wants_grab = true
			await _steps(game, 1)
			runner.wants_grab = false
			await _steps(game, 1)

			if int(game.io_log["uses"]) > seen:
				break

		_check(int(game.io_log["uses"]) > seen, "the use key presses it from where a runner stands", str(game.io_log))
		await _steps(game, 40)
		_check(world.io.delivered > pressed, "and its OnPressed outputs are delivered", "%d before, %d after" % [pressed, world.io.delivered])
	_finished()

	_section("the finish")
	var finish: Vector3 = (doc["finish"] as Dictionary)["at"]
	runner.place_at(finish + Vector3(0.0, 0.1, 0.0), 0.0)
	await _steps(game, 4)
	_check(runner.finished, "standing in the last room ends the course for the runner")
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

	var client_world := client.build(piece, COURSE_ID, {}, false, false, TICK_RATE)
	add_child(client_world)
	_check(client_world != null, "a client builds the same world without its logic")

	for entry: Array in inbox:
		var back := WoEvents.read_world_io(DotNetReader.new(WoEvents.write_world_io(entry[1])))
		wired = wired and bool(back["ok"]) and str((back["msg"] as Dictionary).get("stage")) == String(COURSE_ID)
		client.apply(back["msg"])
		tick = maxi(tick, int((back["msg"] as Dictionary).get("tick", 0)))

	_check(wired, "every message survives the wire format", str(inbox.size()))
	_check(client.base == io.base and client_world.io.now >= tick, "and sets the client's clock to the server's",
		"base %d, now %d, tick %d" % [client.base, client_world.io.now, tick])
	_finished()

	_report(8, 27)


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


func _io_piece(doc: Dictionary) -> bool:
	for piece: Dictionary in doc["pieces"]:
		if str(piece["kind"]) == "world" and bool(piece.get("io", false)):
			return true
	return false


func _nearest_spawn(game: WoGame, at: Vector3) -> float:
	var best := INF

	for spawn: Dictionary in game.stage.io_spawns():
		var origin: Vector3 = spawn["origin"]
		best = minf(best, origin.distance_to(at))

	return best


## The roomiest volume of [param kind] in the manifest that is not [param disabled], with its middle
## (a thin slab is no place to stand a body for a check).
func _volume(manifest: Dictionary, kind: String, disabled: bool, damage: float = 0.0) -> Dictionary:
	var best := {}
	var room := 0.0

	for v: Dictionary in manifest["volumes"]:
		if str(v["kind"]) != kind or bool(v.get("disabled", false)) != disabled:
			continue
		if float(v.get("damage", 0.0)) < damage:
			continue
		var extent := _brush_extent(v)
		var size := extent.size.x * extent.size.y * extent.size.z
		if extent.size.is_finite() and size > room:
			room = size
			best = {"entity": v["entity"], "centre": extent.get_center()}
	return best


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


func _button(world: DotMapWorld) -> DotMapMoverNode:
	for e: DotMapEntity in world.io.entities:
		if e.classname == "func_button" and e is DotMapMoverNode and (e as DotMapMoverNode).node != null:
			return e as DotMapMoverNode
	return null


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
