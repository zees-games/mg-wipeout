extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")
const WoWorld := preload("../game/wo_world.gd")
const WoEvents := preload("../game/net/wo_events.gd")
const WoGame := preload("../game/wo_game.gd")
const WoNetBridge := preload("../game/net/wo_net_bridge.gd")
const WoPlayer := preload("../game/wo_player.gd")
const WoEvent := preload("../game/net/wo_event.gd")
const WoRequest := preload("../game/net/wo_request.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue — so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claim the whole game rests on:[/b] a course is sent once,
## as a document, and after that the client and the server agree about every obstacle on it
## at every tick without one more byte about any of them. If that is false, a knock the
## client predicts is a knock the server never decided, and the player is corrected through
## an arm. So this asserts it from both ends — the same transform at the same tick, and a
## knock predicted and decided — and then everything else that crosses: progress, the arena,
## the weapons on its floor, the result.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 15
const CHECKS := 79

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3
## A second connected player, who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 8
const BYSTANDER_SESSION := 43

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _server_game: WoGame = null
var _client_game: WoGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: WoNetBridge = null
var _client_bridge: WoNetBridge = null
var _stand_in: WoPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0
## Every event the server sent while a section listens: `[peer_id, kind]`.
var _sent_events: Array = []
var _listening := false

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("wipeout over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_course_arrives()
		await _test_the_toys_reach_the_client()
		await _test_obstacles_agree()
		await _test_a_knock_is_predicted()
		await _test_the_local_player_is_predicted()
		await _test_progress_crosses()
		await _test_free_roam_crosses()
		await _test_the_final_death_crosses()
		await _test_an_imported_mesh_arrives()
		await _test_leaving()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after
	# a course was rebuilt mid-tick printed `!is_inside_tree()` on green runs of these suites.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := WoEvents.read_hello(DotNetReader.new(
		WoEvents.write_hello(SESSION, 64, 1234, 0, 4.0, 210.0, 4.0, 100.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION and int(hello["team_count"]) == 0
		and absf(float(hello["course_seconds"]) - 210.0) < 0.1
		and absf(float(hello["countdown_seconds"]) - 4.0) < 0.01, "HELLO", str(hello))

	var doc := WoCatalogue.practice()
	var stage := WoEvents.read_stage(DotNetReader.new(WoEvents.write_stage(WoCourseDoc.encode(doc))))
	var decoded := WoCourseDoc.decode(stage["encoded"]) if bool(stage["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no stage")
	_check(decoded.ok and WoCourseDoc.digest(decoded.value) == WoCourseDoc.digest(doc), "STAGE carries the document whole")

	var toys := WoEvents.read_toys(DotNetReader.new(WoEvents.write_toys(&"wo_first_splash", PackedInt64Array([7, 300, 9001]))))
	_check(bool(toys["ok"]) and toys["stage_id"] == &"wo_first_splash" and toys["ids"] == PackedInt64Array([7, 300, 9001]),
		"TOYS carries the stage and its toys' ids in order", str(toys))

	var join := WoEvents.read_join(DotNetReader.new(WoEvents.write_join(SESSION, 9, "Ada", 101, null)))
	_check(bool(join["ok"]) and int(join["team"]) == 101,
		"JOIN carries a solo side, numbered past any team", str(join.get("team")))

	var round_info := WoEvents.read_round(DotNetReader.new(WoEvents.write_round(3, false, 104, "Bo won the final death")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == 104 and str(round_info["why"]) == "Bo won the final death",
		"ROUND carries the winning side and the sentence")

	var moved := WoEvents.read_progress(DotNetReader.new(WoEvents.write_progress(SESSION, WoEvents.Progress.FINISHED, 2, 61.25)))
	_check(bool(moved["ok"]) and int(moved["kind"]) == WoEvents.Progress.FINISHED and int(moved["value"]) == 2
		and absf(float(moved["seconds"]) - 61.25) < 0.01, "PROGRESS", str(moved))

	var pickup := WoEvents.read_pickup(DotNetReader.new(WoEvents.write_pickup(5, &"shotgun", Vector3(3, 0.7, -12))))
	_check(bool(pickup["ok"]) and pickup["weapon_id"] == &"shotgun"
		and (pickup["position"] as Vector3).distance_to(Vector3(3, 0.7, -12)) < 0.01, "PICKUP")

	var gone := WoEvents.read_pickup_gone(DotNetReader.new(WoEvents.write_pickup_gone(5, SESSION)))
	_check(bool(gone["ok"]) and int(gone["by"]) == SESSION, "PICKUP_GONE")

	var clock := WoEvents.read_clock(DotNetReader.new(WoEvents.write_clock(2, 12.5, 40.25, WoGame.Phase.FINALE, 3, 2, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == WoGame.Phase.FINALE
		and absf(float(clock["course_elapsed"]) - 40.25) < 0.1 and int(clock["finished"]) == 3, "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(WoEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [WoEvents.Kind.size(), WoEvent.KIND_BITS])
	_check(WoRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [WoEvents.Ask.size(), WoRequest.KIND_BITS])
	_check(WoEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), WoEvents.CHAT_KIND_BITS])

	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a course is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.stage.doc.is_empty() and _client_game.catalogue == null,
		"the client has no course and reads no course files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = WoNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = WoNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.stage_received.connect(func(id: StringName, arena: bool) -> void:
		_heard["stage"] = [id, arena])
	_client_bridge.progress_received.connect(func(who: int, kind: int, value: int, seconds: float) -> void:
		_heard["progress_%d" % kind] = [who, value, seconds])
	_client_bridge.pickup_received.connect(func(pickup_id: int, weapon: StringName, at: Vector3) -> void:
		_heard["pickup"] = [pickup_id, weapon, at])
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")

	# Started AFTER the bridge exists, which is what the module does: a course laid out before
	# anything listened to `world_rebuilt` would be a course no client is ever sent.
	_server_game.start()
	_check(_server_game.stage.is_course(), "the server lays its course out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE and _client_game.stage.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate, and so does its course", "%d / %d" % [_client_game.tick_rate, _client_game.stage.tick_rate])
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps for %d Hz" % [Engine.max_physics_steps_per_frame, SERVER_TICK_RATE])
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())
	var mine := _mine()
	_check(mine != null and _client_game.team_of(mine.player_id) == _server_game.team_of(mine.player_id),
		"and agrees with the server about its own side")
	_finished()


func _test_the_course_arrives() -> void:
	_section("the course arrives, as the document the server built")
	_check(not _client_game.stage.doc.is_empty() and _client_game.stage.is_course(), "the client built a course")
	_check(WoCourseDoc.digest(_client_game.stage.doc) == WoCourseDoc.digest(_server_game.stage.doc),
		"the same document, to the byte", WoCourseDoc.digest(_client_game.stage.doc))
	_check(_client_game.stage.pieces.size() == _server_game.stage.pieces.size(), "every piece", "%d" % _client_game.stage.pieces.size())
	_check(_heard.has("stage") and not bool(_heard["stage"][1]), "and the client said so, as a course")
	_finished()


## An imported course: the document crosses, the mesh does not. The client reads it from a pack
## mounted under `res://dot_cloud/` (what `maps_delivery: client` leaves on a real client), not
## from any directory the catalogue added, so `WoWorld.dirs` is emptied before the client builds.
func _test_an_imported_mesh_arrives() -> void:
	_section("an imported course's mesh is the same on the client, found in a mounted pack")
	var mount := "res://dot_cloud/test/maps/1.0.0/worlds"
	DirAccess.make_dir_recursive_absolute(mount)

	for file in DirAccess.get_files_at("res://worlds"):
		var _copied := DirAccess.copy_absolute("res://worlds".path_join(file), mount.path_join(file))

	var kept := WoWorld.dirs.duplicate()
	var added := _server_game.catalogue.add_directory("res://courses")
	var kept_ids := _server_game.config.course_ids
	_server_game.config.course_ids = PackedStringArray(["wo_practice", "wo_office_course"])
	var chosen := _server_game.change_course_now(&"wo_office_course")
	_check(added >= 0 and chosen.ok, "the server changes to the Office Course", str(chosen.error) if not chosen.ok else "")
	WoWorld.dirs = PackedStringArray()
	_exchange()
	await _steps(6)

	_check(String(_client_game.stage.doc.get("id", "")) == "wo_office_course", "the client was sent it",
		str(_client_game.stage.doc.get("id", "")))
	var server_world := _world_node(_server_game)
	var client_world := _world_node(_client_game)
	_check(server_world != null and client_world != null, "both ends built the mesh")

	if server_world != null and client_world != null:
		_check(client_world.get_child_count() == server_world.get_child_count(), "with the same hulls",
			"%d / %d" % [client_world.get_child_count(), server_world.get_child_count()])
		_check((client_world.get_node("Drawn") as Node3D).get_child_count() == (server_world.get_node("Drawn") as Node3D).get_child_count(),
			"and the same drawn faces")

	var back := _server_game.change_course_now(&"wo_practice")
	_exchange()
	await _steps(6)
	_check(back.ok and String(_client_game.stage.doc.get("id", "")) == "wo_practice", "then both go back to the practice course")
	WoWorld.dirs = kept
	_server_game.config.course_ids = kept_ids

	for file in DirAccess.get_files_at(mount):
		DirAccess.remove_absolute(mount.path_join(file))

	var path := mount

	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()

	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


func _world_node(game: WoGame) -> Node3D:
	for piece: Dictionary in game.stage.pieces:
		if str(piece["kind"]) == "world":
			return piece["node"] as Node3D

	return null


## The start pen's toys over the wire: paired by index on both ends, frozen copies, a ball kicked on
## the server followed on the client. Then a client without the stage (one whose STAGE never
## came): it still registers the toys' mirrors from TOYS and reads every snapshot to its end,
## because dot-net stops reading one at the first entity a client does not know; and pairs them
## when the stage comes. Armed: registering the mirrors only once the stage was built here read
## none of those snapshots.
func _test_the_toys_reach_the_client() -> void:
	_section("the start pen's toys reach the client, with or without its stage")
	await _steps(4)
	var count := _server_game.stage.toys.count()
	_check(count == 2 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every toy is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	var server_ball := _server_game.stage.toys.toy(0)
	var client_ball := _client_game.stage.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative and not server_ball.body.freeze, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.stage.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(1, 0.3, 0), 2.0)
	await _steps(60)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(client_ball.body.global_position.distance_to(start) > 0.5 and apart < 0.4,
		"a ball kicked on the server is followed on the client", "%.2f m moved, %.2f m apart" % [client_ball.body.global_position.distance_to(start), apart])

	# The client loses its stage, and is told the toys again (a joiner whose STAGE never built).
	var ids: Array = []
	for behaviour: Node in (_server_bridge.get("_toy_nets") as Array):
		ids.append((behaviour.get("identity") as DotNetIdentity).net_id)
	# As a STAGE this build could not build does it: the old stage cleared, nothing in its place.
	_client_game.world_clearing.emit()
	_client_game.stage.clear()
	_server_bridge._tell(CLIENT_PEER, WoEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
	await _steps(2)
	var applied := [0]
	var count_applied := func(_t: int) -> void: applied[0] += 1
	_client_net.snapshot_applied.connect(count_applied)
	var received := _client_net.stats.snapshots_received
	var _again := _server_game.stage.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(-1, 0.3, 0), 2.0)
	await _steps(30)
	_client_net.snapshot_applied.disconnect(count_applied)
	received = _client_net.stats.snapshots_received - received
	var known := ids.filter(func(id: int) -> bool: return _client_net.registry.has(id)).size()
	_check(known == ids.size() and ids.size() == 2 and _client_bridge.toy_count() == 0,
		"without its stage the client still registers every toy, paired with nothing", "%d of %d known" % [known, ids.size()])
	_check(received > 10 and applied[0] == received, "and reads every snapshot to its end", "%d of %d applied" % [applied[0], received])

	_server_bridge._tell(CLIENT_PEER, WoEvents.Kind.STAGE, _server_bridge.get("_stage_body"))
	await _steps(30)
	client_ball = _client_game.stage.toys.toy(0) if _client_game.stage.toys != null else null
	_check(_client_bridge.toy_count() == 2 and client_ball != null
		and client_ball.body.global_position.distance_to(server_ball.body.global_position) < 0.4,
		"when the stage comes, the same mirrors pose its toys where the server has them",
		"%d paired" % _client_bridge.toy_count())
	_finished()


## The claim: the same tick, the same obstacle, on both ends, and nothing sent about it.
func _test_obstacles_agree() -> void:
	_section("every obstacle is where the server has it, at every tick, with nothing sent")
	var worst := 0.0

	for tick in [0, 17, 64, 300, 1001]:
		_server_game.stage.pose_at(tick)
		_client_game.stage.pose_at(tick)

		for index in range(_server_game.stage.pieces.size()):
			var server_piece: Dictionary = _server_game.stage.pieces[index]
			var client_piece: Dictionary = _client_game.stage.pieces[index]

			if not bool(server_piece["moving"]):
				continue

			var a := _shape_of(server_piece)
			var b := _shape_of(client_piece)
			worst = maxf(worst, a.origin.distance_to(b.origin))

	_check(worst < 0.0001, "the moving pieces agree at five ticks", "worst %.6f m" % worst)

	var limits := Vector3(8.0, 22.0, 5.5)
	var agree := 0
	var asked := 0

	for tick in range(0, 640, 8):
		for at in [Vector3(1.8, 0.0, -21.5), Vector3(-2.0, 0.0, -21.0), Vector3(0.0, 0.0, -38.0)]:
			asked += 1
			if _server_game.stage.knock(at, false, tick, limits) == _client_game.stage.knock(at, false, tick, limits):
				agree += 1

	_check(agree == asked, "and so does every knock asked of them", "%d of %d" % [agree, asked])
	_finished()


func _shape_of(piece: Dictionary) -> Transform3D:
	var node: Node3D = piece["node"]

	match str(piece["kind"]):
		"spinner":
			return (node.get_node(^"Arms") as Node3D).transform
		"pendulum":
			return (node.get_node(^"Arm") as Node3D).transform
		"pusher":
			return (node.get_node(^"Ram") as Node3D).transform
		"tiles":
			return (node.get_child(0) as Node3D).transform
		_:
			return node.transform


## A knock the client predicts is the knock the server decides, so the client is not
## corrected through the arm: both ends count one, and they end up in the same place.
func _test_a_knock_is_predicted() -> void:
	_section("a knock is predicted, and it is the one the server decides")
	await _run_course_open()
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var hub := _spinner_hub(_server_game)
	server_me.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var client_before := _mine().knocks
	var server_before := server_me.knocks

	# Two arms at seventy-five degrees a second: one comes round every 2.4 s at the most.
	for _i in range(SERVER_TICK_RATE * 4):
		await _step()

		if server_me.knocks > server_before and _mine().knocks > client_before:
			break

	_check(server_me.knocks > server_before, "the server threw them", "%d" % (server_me.knocks - server_before))
	_check(_mine().knocks > client_before, "and the client, predicting, threw them too", "%d" % (_mine().knocks - client_before))
	await _steps(40)
	var apart := _mine().controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.6, "and they agree where the flight ended", "%.2f m apart" % apart)
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("the local player is predicted, and the server agrees")
	var mine := _mine()
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var start: Vector3 = _server_game.course_doc["checkpoints"][0]["at"]
	server_me.place_at(start, 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(24, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


func _test_progress_crosses() -> void:
	_section("checkpoints and the finish cross")
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var checkpoint: Dictionary = _server_game.course_doc["checkpoints"][0]
	server_me.place_at(checkpoint["at"], 0.0)
	await _steps(8)
	_check(_heard.has("progress_%d" % WoEvents.Progress.CHECKPOINT), "a checkpoint is announced")
	_check(_mine().checkpoint == 0, "and the client's player has it", "%d" % _mine().checkpoint)

	var finish: Dictionary = _server_game.course_doc["finish"]
	server_me.place_at(finish["at"], 0.0)
	await _steps(8)
	_check(_heard.has("progress_%d" % WoEvents.Progress.FINISHED)
		and int(_heard["progress_%d" % WoEvents.Progress.FINISHED][0]) == SESSION, "the finish is announced, with who")
	_check(_mine().finished, "and the client's player is across")

	# Into the water from the lounge: back to the lounge, and the client is told it was a fall.
	server_me.place_at(Vector3(40.0, 1.0, -30.0), 0.0)
	# Seven metres down to the water is most of a second.
	await _steps(SERVER_TICK_RATE * 2)
	_check(_heard.has("progress_%d" % WoEvents.Progress.FELL), "a fall is announced")
	_finished()


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	var rules := _server_game.spectate_rules
	var key := WoNetBridge.player_key(SESSION)
	var stand_key := _stand_in.player_id
	# Out: not alive to the manager (a watcher is in the gallery), then the death camera, which
	# hands over to the stand-in after its second or so.
	var me: WoPlayer = _server_game.players[key]
	me.watching = true
	spectate.on_died(key, stand_key, false, Vector3(0, 2, 0), 0.0, _tick)
	await _steps(SERVER_TICK_RATE * 4)
	_check(spectate.is_spectating(key) and not spectate.is_roaming(key),
		"a watcher starts on a player, not in a free camera", str(spectate.mode_of(key)))
	_check(_client_game.spectate.is_spectating(key), "and the client's mirror is watching too")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(key), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(key), "and the client's mirror is told ROAMING")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"the same key hands the camera back to a player on both ends")

	rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"mp_freeroam 0 refuses the request")
	rules.allow_roaming = true

	rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key), "mp_forcecamera 1 refuses it too")
	rules.force_camera = 0

	_client_bridge.ask_roam()
	await _steps(6)
	rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	rules.allow_roaming = true
	# Back in play, as the next section expects.
	me.watching = false
	spectate.on_spawned(key)
	await _steps(6)
	_finished()


func _test_the_final_death_crosses() -> void:
	_section("the final death crosses: the arena, the floor, the gallery, the result")
	# The stand-in across too, so two sides finished and the course closes into a fight.
	_server_game._finish_count += 1
	_stand_in.finished = true
	_stand_in.place = _server_game._finish_count
	_server_game.course_elapsed = _server_game.course_limit()
	await _steps(6)
	_check(_server_game.phase == WoGame.Phase.HANDOVER, "the server is in a handover")
	_check(_client_game.stage.is_arena() and WoCourseDoc.digest(_client_game.stage.doc) == WoCourseDoc.digest(_server_game.stage.doc),
		"the client built the same arena")
	_check(_heard.has("pickup") and _client_game.pickups.size() == _server_game.pickups.size(),
		"the weapons on its floor arrived", "%d" % _client_game.pickups.size())

	await _steps(40)
	var bodies := int(_client_bridge.describe()["bodies"])
	_check(bodies == _server_game.props.world_count() and bodies > 0, "and every prop", "%d" % bodies)
	_check(not _mine().watching, "a finisher is fighting, not watching")

	# The gun in their hand, as somebody else draws it. Armed on the server as a pickup arms
	# them, and announced as the module announces it (this suite has no module); the client's
	# copy of this player, drawn as a watcher would, holds it at the end of its right arm.
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var _armed := _server_game.arm(server_me, &"pistol")
	_server_bridge.announce_armed(server_me.player_id, &"pistol")
	await _steps(4)
	var copy := _mine()
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		copy.figure != null and copy.figure.holding == &"pistol" and copy.figure.held != null
			and copy.figure.held.equipped() == &"pistol"
			and hand != null and hand.get_parent() is BoneAttachment3D,
		"a watcher draws the weapon in their hand (the person's gun-hand bone)",
		"%s drawn, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-", str(copy.dealt)
		]
	)

	await _steps(int(_server_game.config.handover_seconds * SERVER_TICK_RATE) + 4)
	_check(_client_game.phase == WoGame.Phase.FINALE, "the client knows the fight is on")
	_finished()

	await _test_a_hit_is_the_shooters()

	_section("the final death's result crosses")
	var damage := DotDamage.make(0, _stand_in.entity_id, 500.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == _server_game.team_of(WoNetBridge.player_key(SESSION)),
		"the last one standing wins, and the client is told who", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("final death"),
		"with the server's own sentence")
	_finished()


## The weapon-feel pass's wire half (`WoGame.hit_landed` → HIT → `hit_received`, and the owner-only
## magazine that `WoClient.correct_drawn` adopts). `headless_run` only proves the offline half,
## where the world's own signal flashes the marker and nothing crosses. Armed: with the bridge's
## HIT send removed the first check fails; sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot that lands is told to the shooter alone, and the drawn gun takes the server's count")
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var hits: Array = []
	var heard := func(point: Vector3, killed: bool, headshot: bool) -> void:
		hits.append([point, killed, headshot])
	_client_bridge.hit_received.connect(heard)

	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Bo")
	_server_bridge._admit(BYSTANDER_PEER)
	var still := DotFpsCommand.new()
	await _steps(4, still)

	# Point-blank, straight down the aim: the stand-in three metres in front of the shooter's eye,
	# hit but never killed (a kill ends the fight and takes the gun this section counts).
	var aim := DotWeaponCommand.new()
	_stand_in.place_at(server_me.global_position + aim.aim_direction() * 3.0, 180.0)
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	var full := server_me.weapons.arsenal.current().magazine
	_sent_events.clear()
	_listening = true

	var fire := DotFpsCommand.new()
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(2, fire)
	await _steps(INPUT_LEAD + 6, still)

	var to_shooter := _events_of(WoEvents.Kind.HIT, CLIENT_PEER)
	_check(not hits.is_empty() and to_shooter > 0, "the shooter's bridge is told the shot landed",
		"%d heard, %d sent to the shooter" % [hits.size(), to_shooter])
	var elsewhere := _events_of(WoEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(WoEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not hits.is_empty() and (hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the body that was hit",
		"%s, body at %s" % [str(hits[0][0]) if not hits.is_empty() else "-", str(_stand_in.global_position)])

	# Shot back: this player the victim, and a victim is told nothing.
	hits.clear()
	_sent_events.clear()
	var shot_back := DotShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := DotDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, still)
	_check(hits.is_empty() and _events_of(WoEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % hits.size())

	# The count: the magazine the server spent arrives in the owner's snapshot fields, and a drawn
	# gun that predicted wrong adopts it once quiet, through the client's own correct_drawn.
	var server_mag := server_me.weapons.arsenal.current().magazine
	var behaviour: Variant = _client_bridge._behaviours.get(SESSION)
	var net_mag := int(behaviour.get(&"net_magazine")) if behaviour != null else -1
	_check(server_mag < full and net_mag == server_mag,
		"the server's magazine, spent, crosses to the owner", "full %d, server %d, client told %d" % [full, server_mag, net_mag])

	var client: Node = (load("res://game/wo_client.gd") as GDScript).new()
	var rig := ZeeWeaponRig.new()
	rig.name = "DrawnForTest"
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = false
	rig.tick_rate = _client_game.tick_rate
	_mine().add_child(rig)
	var _set := rig.setup()
	var _given := rig.give(server_me.weapons.current_def().id)
	if rig.arsenal.current() == null or rig.arsenal.current_slot() != server_me.weapons.arsenal.current_slot():
		var _picked := rig.arsenal.select(server_me.weapons.arsenal.current_slot(), 0)
	rig.arsenal.current().magazine = rig.arsenal.current().def.magazine
	client.set(&"weapons", rig)
	client.set(&"player", _mine())
	client.set(&"bridge", _client_bridge)
	client.set(&"_offline", false)
	client.set(&"_watch_id", SESSION)
	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	var drawn_early := rig.arsenal.current().magazine
	client.set(&"_drawn_quiet", 1.0)
	var corrected: bool = client.call(&"correct_drawn")
	_check(not early and drawn_early != server_mag and corrected and rig.arsenal.current().magazine == server_mag,
		"the drawn gun takes the server's count once quiet, and not before",
		"before %d, after %d, server %d" % [drawn_early, rig.arsenal.current().magazine, server_mag])
	client.free()
	_mine().remove_child(rig)
	rig.free()

	_listening = false
	target_health.cannot_die = false
	_client_bridge.hit_received.disconnect(heard)
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


## How many events of [param kind] the server sent to [param peer_id] (0: broadcast).
func _events_of(kind: int, peer_id: int) -> int:
	var count := 0
	for sent: Array in _sent_events:
		if int(sent[0]) == peer_id and int(sent[1]) == kind:
			count += 1
	return count


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(WoNetBridge.player_key(SESSION)), "the server lets them go")
	_check(not _client_game.players.has(WoNetBridge.player_key(SESSION)) or _server_bridge.describe()["ready_peers"] == 0,
		"and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------

func _mine() -> WoPlayer:
	return _client_game.players.get(WoNetBridge.player_key(SESSION))


func _spinner_hub(game: WoGame) -> Vector3:
	for piece in game.stage.pieces:
		if str(piece["kind"]) == "spinner":
			return piece["spec"]["at"]
	return Vector3.ZERO


## Steps until the course is open, so the gate is down and hazards count.
func _run_course_open() -> void:
	for _i in range(SERVER_TICK_RATE * 8):
		if _server_game.phase == WoGame.Phase.COURSE:
			return
		await _step()


func _make_game(server: bool, parent: Node) -> WoGame:
	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.handover_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray(["wo_practice"])
	config.courses_per_round = 1
	config.arena_ids = PackedStringArray(["wo_practice_arena"])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = WoGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	# Only while a section listens: a decode on the client's registry counts what it skips.
	if method == &"event" and _listening:
		var decoded := _client_net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is WoEvent:
			_sent_events.append([peer_id, (decoded.value as WoEvent).kind])

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them: the props are rigid bodies,
## and a rigid body moves on the physics frame and nowhere else.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


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


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out
