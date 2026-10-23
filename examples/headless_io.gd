extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourseIo := preload("../game/wo_course_io.gd")
const WoEvents := preload("../game/net/wo_events.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

## A course that runs its map's own entities (dot-map's DotMapWorld), played on the server's step.
##
## A bot cannot finish such a course: its buttons, doors and pushes are the puzzle and no route
## document describes them. So what is checked is the machinery, on the real map: the world loads
## with nothing its entities ask for left unhandled, a runner spawns on the map's own spawn
## points, every kind of thing the map does fires from a body or a press (a hurt volume, a push,
## a button through the use key, a trigger that starts a mover), the movers move, a mover carries
## a runner standing on it, and the state reaches a client over the wire format.

## Each course and what it must run: sections and checks (the totals the run must reach), `lava` (a hurt a trigger
## enables after a delay), `ladders`, `push` (a push that starts on), `button`, `floor` (the metres a runner may
## sink in a second and a half on its start: measured, 0.5 where the course passes), `rejects` (how many of the
## map's volumes a team filter turns a body of no team away from, which the run prints).
const COURSES := {
	&"wo_oaks_course": {"sections": 9, "checks": 33, "lava": false, "ladders": false, "rejects": 0},
	&"wo_office_course": {"sections": 11, "checks": 38, "lava": true, "ladders": true, "rejects": 0},
	&"wo_dans_course": {"sections": 10, "checks": 35, "lava": false, "ladders": true, "rejects": 0},
	&"wo_pauls_course": {"sections": 9, "checks": 32, "lava": false, "ladders": false, "push": false, "floor": 0.7, "rejects": 3},
	&"wo_scary_course": {"sections": 9, "checks": 32, "lava": false, "ladders": false, "push": false, "rejects": 0},
	&"wo_lego_course": {"sections": 9, "checks": 29, "lava": false, "ladders": false, "push": false, "button": false, "rejects": 0},
	&"wo_dc_course": {"sections": 9, "checks": 33, "lava": false, "ladders": false, "rejects": 0},
	&"wo_waytobar_course": {"sections": 9, "checks": 33, "lava": false, "ladders": false, "rejects": 0},
	&"wo_labo_course": {"sections": 9, "checks": 33, "lava": false, "ladders": false, "rejects": 0},
	&"wo_sweet_course": {"sections": 9, "checks": 33, "lava": false, "ladders": false, "rejects": 0},
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

		var plan: Dictionary = COURSES[id]
		_expect_sections += int(plan["sections"])
		_expect_checks += int(plan["checks"])
		print("== %s" % id)
		var before := _passed + _failed
		await _play(catalogue, id, plan)
		print("  (%d checks)" % (_passed + _failed - before))

	_report(_expect_sections, _expect_checks)


func _play(catalogue: WoCatalogue, id: StringName, plan: Dictionary) -> void:
	var lava: bool = plan.get("lava", false)
	var ladders: bool = plan.get("ladders", false)
	var wants_push: bool = plan.get("push", true)
	var wants_button: bool = plan.get("button", true)
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
	var turned_away := _rejected(game, world, runner)
	print("  volumes whose team filter turns a runner (team 0) away: %s" % str(turned_away))
	var by_team := turned_away.filter(func(line: String) -> bool: return line.contains("filter_activator_team"))
	_check(by_team.size() == int(plan.get("rejects", 0)), "the team filters that turn a runner away are the ones known",
		"%d: %s" % [by_team.size(), str(by_team)])
	_finished()

	_section("a runner spawns")
	# A start-line teleport (Sweet's) moves everybody on the first ticks: where the runner is after them is the start.
	# (a countdown the map runs itself may come first: wait for it, four seconds at most).
	for _i in range(4 * TICK_RATE):
		if not _sent_to(game, runner).is_empty():
			break

		await _steps(game, 1)

	await _steps(game, 8)
	var from := runner.controller.state.position
	var spawn := _nearest_spawn(game, from)
	var sent := _sent_to(game, runner)
	# The map may move everybody off its spawn room at once (a teleport on the start line): the destination
	# it sends THIS runner to from the start is where it should be, and nowhere else.
	var arrived := not sent.is_empty() and from.distance_to(sent.back()) < 2.5
	print("  spawn %.2f m away; the map sent the runner to: %s" % [spawn, str(sent)])
	_check(spawn < 2.5 or arrived, "on one of the map's spawn points, or where its start teleport sent it", "%.2f m from the nearest spawn" % spawn)
	_check(runner.is_alive() and not runner.finished, "alive and in the round")
	await _steps(game, 90)
	var rest := runner.controller.state.position
	var tolerance := float(plan.get("floor", 0.5))
	_check(Vector2(rest.x, rest.z).distance_to(Vector2(from.x, from.z)) < 3.0, "it stays where it was put", "%s to %s" % [from, rest])
	_check(rest.y > from.y - tolerance, "standing on its floor a second and a half later (within %.1f m)" % tolerance,
		"%s to %s" % [from, rest])
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
	var floor_y := float(doc["water_height"])
	var pushes := _live(world, "push", 0.0, floor_y)
	var hurts := _live(world, "hurt", 100.0, floor_y)

	# A course that says it has no push really has none that starts on, for a player, and moves a body.
	_check(wants_push != pushes.is_empty(), "the map has a push that starts on" if wants_push else "and the map has no push that starts on",
		str(pushes.size()))

	# Roomiest first; the first that answers is the one checked (a volume may sit in a room a teleport empties, or
	# behind a filter). It answers when the body is inside THAT volume and the push followed in the same step.
	if wants_push and not pushes.is_empty():
		var moved := false
		var tried_pushes := ""
		var pusher := game.add_player(&"u4", "Pushed")
		await _steps(game, 2)

		for pushed in pushes:
			var pushes_before := int(game.io_log["pushes"])
			pusher.place_at(pushed["centre"], 0.0)
			await _steps(game, 1)

			var inside := (pushed["node"] as DotMapVolumeNode).inside.has(String(pusher.player_id))
			tried_pushes += " [%s at %s inside %s pushes %d->%d, body now %s, volume on %s]" % [(pushed["node"] as DotMapVolumeNode).volume.targetname, pushed["centre"], inside, pushes_before, int(game.io_log["pushes"]), pusher.controller.state.position, (pushed["node"] as DotMapVolumeNode).active()]

			if inside and int(game.io_log["pushes"]) > pushes_before:
				moved = true
				break

		_check(moved, "the push moves the runner", tried_pushes.substr(0, 900))

	_check(not hurts.is_empty(), "the map has a hurt volume that starts on")

	if not hurts.is_empty():
		var out := false
		var struck_by := false
		var survived := true
		var tried := 0
		var outs := ""

		for hurt in hurts:
			# A fresh body for each volume: the counters and the round's list start from nothing.
			var other := game.add_player(StringName("h%d" % tried), "Other%d" % tried)
			tried += 1
			await _steps(game, 2)
			var hurts_before := int(game.io_log["hurts"])
			other.place_at(hurt["centre"], 0.0)
			await _steps(game, 1)
			var node: DotMapVolumeNode = hurt["node"]
			var here := _inside_of(world, "hurt", String(other.player_id))

			if int(game.io_log["hurts"]) > hurts_before and here == [node]:
				struck_by = true
				await _steps(game, 40)
				out = other.out_for_round and other.watching
				outs = "alive %s out %s watching %s damage %s" % [other.is_alive(), other.out_for_round, other.watching, node.volume.record.get("damage")]
				survived = runner.is_alive()
				break

		_check(struck_by, "the hurt volume hits a runner standing in it alone", "%d tried, %s" % [tried, str(game.io_log)])
		_check(out, "and a one-life course puts him out for the round", outs)
		_check(survived, "while the runner is still in the round")
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

	await _map_end(game, world, doc)

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
	await _button_section(game, game.stage.io.world, wants_button)


## Last, because a button may do what the map means by it, which can end the course for everybody (a teleport to
## the winners' room).
func _button_section(game: WoGame, world: DotMapWorld, wants_button: bool) -> void:
	_section("a button")
	var buttons := _buttons(world)
	if wants_button:
		_check(not buttons.is_empty(), "the map has a button")

	if not buttons.is_empty():
		# A fresh body: the runner may have been carried over the finish line by the push check.
		var presser := game.add_player(&"u7", "Presser")
		await _steps(game, 2)
		var seen := int(game.io_log["uses"])
		var pressed := false
		var followed := false
		var baseline := 0
		var sent_by_it := 0
		var trail := ""

		# Each button in turn, from each side, eyes on its middle, the grab key pressed for one tick: the first
		# that answers and delivers is the one checked (some start locked or sit behind a door).
		for button in buttons:
			var box := _centre_of(button)

			# A locked one waits for the map's own unlock somewhere else on the course: the press itself is what is checked.
			if button.locked:
				button.accept(world.io, "Unlock", "", null, null)
				trail += " [%d unlocked by the check]" % button.index
				await _steps(game, 2)

			var was_in: bool = button._in

			for side in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
				# At the height the button's own eyes would be, and at floor level with the head tipped down
				# to it (a button low on a wall is pressed looking down).
				for drop in [1.6, 1.1, 0.6]:
					if game.phase != WoGame.Phase.COURSE:
						break

					var feet := Vector3(box.x + side.x * 1.2, box.y - drop, box.z + side.y * 1.2)
					var yaw := rad_to_deg(atan2(side.x, side.y))
					presser.place_at(feet, yaw)
					var to := box - presser.eye_position()
					var pitch := rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
					var look := DotFpsCommand.new()
					look.yaw = yaw
					look.pitch = pitch
					presser.controller.apply_command(look)
					baseline = int(world.io.delivered_from.get(button.index, 0))
					presser.wants_grab = true
					await _steps(game, 1)

					if game.phase != WoGame.Phase.COURSE:
						break

					presser.wants_grab = false
					presser.controller.apply_command(look)
					await _steps(game, 1)

					if int(game.io_log["uses"]) > seen:
						break

				if int(game.io_log["uses"]) > seen:
					break

			trail += " [%d locked %s in %s->%s uses %d->%d]" % [button.index, button.locked, was_in, button._in, seen, int(game.io_log["uses"])]
			# This button went from released to pressed in this press; the delivery that counts follows it.
			if int(game.io_log["uses"]) > seen and button._in and not was_in:
				pressed = true
				var wait := clampi(int(_press_delay(button) * float(TICK_RATE)) + 20, 40, 640)
				# Zero-delay outputs have left already; the course may close on them (a teleport to the winners' room).
				sent_by_it = int(world.io.delivered_from.get(button.index, 0)) - baseline

				if game.phase == WoGame.Phase.COURSE:
					await _steps(game, wait)

				if is_instance_valid(world) and game.phase == WoGame.Phase.COURSE:
					sent_by_it = int(world.io.delivered_from.get(button.index, 0)) - baseline

				# A button with outputs to deliver ends the search; one without (a switch that only gates another) does not.
				if sent_by_it > 0:
					followed = true
					break

			seen = int(game.io_log["uses"])

			if game.phase != WoGame.Phase.COURSE:
				break

		_check(pressed, "the use key presses it from where a runner stands", trail.substr(0, 700))
		_check(followed, "and its outputs are delivered after that press, by that button",
			"%d delivered from the last button pressed" % sent_by_it)
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
	var room := _named_volume(world, "hurt", "Obstacle2_Hurt")
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


## The ways the map itself ends a course, each tried with a fresh body the way a runner would meet it: a score
## volume or a teleport that lands in the finish box fires for a body of no team and the course ends there; a
## kill slab beside the finish is walked into from the course side and the finish arrives first.
func _map_end(game: WoGame, world: DotMapWorld, doc: Dictionary) -> void:
	_section("the map's own end")
	var ends := _ends(world, doc)
	_check(not ends.is_empty(), "the map has an end of its own (a score, an arrival in the finish or a kill slab)")
	var rejected := 0
	var failed := 0
	var unreached := 0
	var passed_ends := 0
	var index := 0

	for end: Dictionary in ends:
		var node: DotMapVolumeNode = end["node"]
		var walker := game.add_player(StringName("e%d" % index), "End%d" % index)
		index += 1
		await _steps(game, 2)
		var live := node.active()
		var turned := false

		# A runner walks at the end from the far side of the finish box: the finish has to end the course before the
		# map's own end (a teleport, a kill) does, whichever it is. A score the map gives a runner of no team is
		# reported when its filter turns him away.
		turned = end["kind"] != "slab" and live and not node._filter_passes(world.io, game.io_body(walker))
		var walked := await _walk_into(game, doc, walker, end["box"])
		var result: String = walked["why"]
		var fired: bool = walked["finished"] and not walker.out_for_round
		unreached += 0 if walked["reached"] else 1

		# A walk can be stopped by what the map puts on the way (a push, a mover, a rail): then a body put where the
		# end overlaps the finish box must finish in its first tick, before the end's own effect.
		if not fired:
			var stood := game.add_player(StringName("s%d" % index), "Stand%d" % index)
			await _steps(game, 2)
			var box: AABB = end["box"]
			var at := _finish_box(doc).get_center().clamp(box.position, box.end)
			stood.place_at(Vector3(at.x, box.position.y + 0.05, at.z), 0.0)
			await _steps(game, 3)
			# Finished AND killed in one tick is the race a runner never meets (the finish box comes first on any route).
			fired = stood.finished
			result += "; stood at %s, now %s: finished %s, out %s, alive %s" % [at, stood.controller.state.position, stood.finished, stood.out_for_round, stood.is_alive()]

		rejected += 1 if turned else 0
		# An end the map keeps off (until some other part of the course turns it on) cannot be tried from the start.
		failed += 0 if fired or not live else 1
		passed_ends += 1 if fired else 0
		var wires := node.volume.outputs.map(func(o: Dictionary) -> String: return "%s>%s.%s" % [o.get("output", ""), o.get("target", ""), o.get("input", "")])
		print("  end %s %s box %s finish %s: %s  outputs %s" % [end["kind"], node.volume.targetname, end["box"], _finish_box(doc), result, str(wires)])

	_check(rejected == 0, "no end of the map turns a runner away on its team")
	_check(failed == 0 and passed_ends > 0, "each end the map has on ends the course for the runner",
		"%d live ones did not, %d of %d ended it, %d had no floor to walk in from" % [failed, passed_ends, ends.size(), unreached])
	_finished()


## The map's ends within eight metres of the finish box: volumes with an ApplyScore output, teleports that land
## inside it, and kill slabs of 1000 damage or more (which may score too). At most six.
func _ends(world: DotMapWorld, doc: Dictionary) -> Array:
	var finish := _finish_box(doc)
	var out: Array = []
	var slabs: Array = []

	for node: DotMapVolumeNode in world.volumes.nodes:
		var v := node.volume
		var box := _widest(v)

		if not box.size.is_finite():
			continue

		var kind := ""

		for o: Dictionary in v.outputs:
			if str(o.get("input", "")).to_lower() == "applyscore":
				kind = "score"

		# A plane thinner than a hand (a floor's kill sheet under the floor) cannot be walked into.
		var kills := v.kind == "hurt" and not v.disabled and float(v.record.get("damage", 0.0)) >= 1000.0 and box.size.y > 0.1

		if kills:
			if finish.grow(8.0).intersects(box.grow(0.01)):
				slabs.append({"node": node, "box": box, "kind": "slab"})
			continue

		if kind == "score" and _gap(finish, box) > 8.0:
			continue

		if kind == "" and v.kind == "teleport" and world.io.destinations.get(v.target) is Dictionary:
			var at: Array = world.io.destinations[v.target]["at"] if world.io.destinations[v.target].has("at") else [0, 0, 0]

			# A sheet thinner than a hand (Labo's zonetp9 is 0.019 m) is stepped over between two ticks; noted on the board, not walked.
			if finish.grow(0.5).has_point(Vector3(at[0], at[1], at[2])) and minf(box.size.x, box.size.z) >= 0.1:
				kind = "arrival"

		if kind != "":
			out.append({"node": node, "box": box, "kind": kind})

	slabs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _gap(finish, a["box"]) < _gap(finish, b["box"]))
	out.append_array(slabs.slice(0, 3))

	return out.slice(0, 6)


## The finish box of the document as a world box (its yaw is a multiple of 90 degrees on the imports).
func _finish_box(doc: Dictionary) -> AABB:
	var finish: Dictionary = doc["finish"]
	var at: Vector3 = finish["at"]
	var size: Vector3 = finish["size"]
	var turned := int(roundf(float(finish["yaw"]) / 90.0)) % 2 != 0
	var half := Vector3(size.z, size.y, size.x) * 0.5 if turned else size * 0.5
	return AABB(Vector3(at.x - half.x, at.y - 0.5, at.z - half.z), Vector3(half.x * 2.0, size.y + 0.5, half.z * 2.0))


func _gap(a: AABB, b: AABB) -> float:
	var d := Vector3.ZERO

	for axis in 3:
		d[axis] = maxf(0.0, maxf(a.position[axis] - b.end[axis], b.position[axis] - a.end[axis]))

	return d.length()


## A body put on the floor just outside the finish box on the far side from [param slab], walking at it: the
## finish must end the course before the slab does. Returns whether it did.
func _walk_into(game: WoGame, doc: Dictionary, who: WoPlayer, slab: AABB) -> Dictionary:
	var finish := _finish_box(doc)
	var centre := finish.get_center()
	var away := Vector3(centre.x - slab.get_center().x, 0.0, centre.z - slab.get_center().z)
	away = away.normalized() if away.length() > 0.05 else Vector3(0.0, 0.0, 1.0)
	var space := game.get_world_3d().direct_space_state
	var tried: Array = []

	# The course side first (beyond the finish from the slab), then the other three: whichever has floor to stand on.
	for turn in [0.0, 90.0, -90.0, 180.0]:
		var dir := away.rotated(Vector3.UP, deg_to_rad(turn))
		var reach := 0.0

		while finish.has_point(Vector3(centre.x + dir.x * reach, centre.y, centre.z + dir.z * reach)) and reach < 30.0:
			reach += 0.25

		var start := centre + dir * (reach + 1.5)
		var query := PhysicsRayQueryParameters3D.create(Vector3(start.x, finish.end.y + 3.0, start.z), Vector3(start.x, finish.position.y - 4.0, start.z))
		var hit := space.intersect_ray(query)

		if hit.is_empty():
			tried.append("no floor at %s" % start)
			continue

		var yaw := rad_to_deg(atan2(dir.x, dir.z))
		who.place_at((hit["position"] as Vector3) + Vector3(0.0, 0.05, 0.0), yaw)
		await _steps(game, 2)
		var walked := 0
		var path := ""

		for _i in range(160):
			if who.finished or who.out_for_round or not who.is_alive():
				break

			var command := DotFpsCommand.new()
			command.move = Vector2(0.0, 1.0)
			command.yaw = yaw
			who.controller.apply_command(command)
			await _steps(game, 1)
			walked += 1

			if walked % 12 == 0:
				var at := who.controller.state.position
				path += " (%.1f %.1f %.1f)" % [at.x, at.y, at.z]

		return {"finished": who.finished, "reached": true, "why": "walked %d ticks from %s to %s, finished %s, out %s, path%s" % [walked, start, who.controller.state.position, who.finished, who.out_for_round, path if not who.finished else ""]}

	return {"finished": false, "reached": false, "why": "no floor beside the finish: %s" % str(tried)}


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


func _named_volume(world: DotMapWorld, kind: String, target: String) -> Dictionary:
	for node: DotMapVolumeNode in world.volumes.nodes:
		if node.volume.kind == kind and node.volume.targetname == target:
			var box := _widest(node.volume)
			return {"centre": box.get_center(), "floor": box.position.y}
	return {}


func _io_piece(doc: Dictionary) -> bool:
	for piece: Dictionary in doc["pieces"]:
		if str(piece["kind"]) == "world" and bool(piece.get("io", false)):
			return true
	return false


## The metres to the nearest of the map's own spawn points.
func _nearest_spawn(game: WoGame, at: Vector3) -> float:
	var best := INF

	for spawn: Dictionary in game.stage.io_spawns():
		var origin: Vector3 = spawn["origin"]
		best = minf(best, origin.distance_to(at))

	return best


## Where the map's teleports sent [param player], in order.
func _sent_to(game: WoGame, player: WoPlayer) -> Array:
	var out: Array = []

	for entry: Dictionary in game.io_teleported:
		if entry["body"] == player:
			out.append(entry["to"])

	return out


## The volumes with a team filter that turns a body of no team away, by name: what a runner can never trigger.
func _rejected(game: WoGame, world: DotMapWorld, who: WoPlayer) -> Array:
	var body := game.io_body(who)
	var out: Array = []

	for node: DotMapVolumeNode in world.volumes.nodes:
		if node.volume.filter != "" and DotMapVolumeNode.TRIGGER_KINDS.has(node.volume.kind) and not node._filter_passes(world.io, body):
			var found := world.io.find(node.volume.filter)
			var by: String = found[0].classname if not found.is_empty() else "?"
			out.append("%s %s (%s %s)" % [node.volume.kind, node.volume.targetname if node.volume.targetname != "" else "#%d" % node.volume.entity,
				node.volume.filter, by])

	return out


## The volumes of [param kind] that are on now and would act on a player, above [param floor_y] (a body below the
## water is out of the round, as on a map's side arena), roomiest first, each with its middle (a thin slab is no
## place to stand a body for a check). At most eight.
func _live(world: DotMapWorld, kind: String, damage: float, floor_y: float) -> Array:
	var found: Array = []

	for node: DotMapVolumeNode in world.volumes.nodes:
		var v := node.volume

		if v.kind != kind or not node.active() or float(v.record.get("damage", 0.0)) < damage:
			continue
		if kind == "push" and ((v.spawnflags & 1) == 0 or _push_velocity(node) == Vector3.ZERO):
			continue

		var box := _widest(v)

		if box.size.is_finite() and box.get_center().y > floor_y:
			found.append({"node": node, "centre": box.get_center(), "room": box.size.x * box.size.y * box.size.z})

	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["room"]) > float(b["room"]))
	return found.slice(0, 8)


func _push_velocity(node: DotMapVolumeNode) -> Vector3:
	if node.entity is DotMapPush:
		return (node.entity as DotMapPush).velocity()

	return node.volume.push_velocity()


## The roomiest of a volume's brush boxes.
func _widest(v: DotMapVolume) -> AABB:
	var best := AABB(Vector3.ZERO, Vector3(INF, INF, INF))
	var room := -1.0

	for box: AABB in v.brush_boxes():
		var size := box.size.x * box.size.y * box.size.z

		if size > room:
			room = size
			best = box

	return best


## The volumes of [param kind] that hold [param who] now.
func _inside_of(world: DotMapWorld, kind: String, who: String) -> Array:
	var out: Array = []

	for node: DotMapVolumeNode in world.volumes.nodes:
		if node.volume.kind == kind and node.inside.has(who):
			out.append(node)

	return out


## The longest delay of a button's OnPressed outputs, in seconds.
func _press_delay(button: DotMapMoverNode) -> float:
	var longest := 0.0

	for link: Dictionary in button.links:
		if str(link["output"]).to_lower() == "onpressed":
			longest = maxf(longest, float(link["delay"]))

	return longest


func _on_pressed(button: DotMapMoverNode) -> bool:
	for link: Dictionary in button.links:
		if str(link["output"]).to_lower() == "onpressed":
			return true

	return false


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
