extends DotGameCheckSuite

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

## The two-world harness of headless_net: state, the in-process link and the stepping.

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3
## A second connected player, who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 8
const BYSTANDER_SESSION := 43

var _sections_entered := 0
var _sections_finished := 0

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


func _events_of(kind: int, peer_id: int) -> int:
	var count := 0
	for sent: Array in _sent_events:
		if int(sent[0]) == peer_id and int(sent[1]) == kind:
			count += 1
	return count


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


## sv_workbench_remote over the real frames, in the order WoModule and WoClient register them: an admin gets a
func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
