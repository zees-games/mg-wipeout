extends Node

const WoEvent := preload("wo_event.gd")
const WoEvents := preload("wo_events.gd")
const WoNetCommand := preload("wo_net_command.gd")
const WoNetLink := preload("wo_net_link.gd")
const WoPlayerNet := preload("wo_player_net.gd")
const WoPropNet := preload("wo_prop_net.gd")
const WoRequest := preload("wo_request.gd")
const WoToyNet := preload("wo_toy_net.gd")

const WoContent := preload("../wo_content.gd")
const WoGame := preload("../wo_game.gd")
const WoWorld := preload("../wo_world.gd")
const WoCourseDoc := preload("../wo_course_doc.gd")
const WoPlayer := preload("../wo_player.gd")

## Joins an [WoGame] to a [DotNetManager]: the netcode seam, and the only file here that names both.
## The course is not replicated: it arrives once in `STAGE` and every obstacle is a function of the tick. The world
## ticks as a whole: [method ensure_game_ticked] runs it on the first behaviour through.

const CHANNEL := "wo.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands per input packet: this tick's and the four before it, so a lost packet costs no
## tick over ENet unless the next four are lost too (WebSocket never loses one).
const INPUT_COPIES := 5

## How often the round clock goes out, in ticks: twice a second, since what it carries
## changes once a second; the client advances the clock between messages.
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended. [param why] is the server's sentence about who won.
signal round_changed(number: int, began: bool, winner: int, why: String)

## The round changed half. Client side.
signal phase_received(phase: int)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName, weapon_id: StringName)

## A barrel went off, where, and how far it reached.
signal blast_received(at: Vector3, radius: float)

## Somebody was handed, or picked up, a weapon. The HUD names it.
signal armed_received(player_id: int, weapon_id: StringName)
## Your shot landed (see [signal WoGame.hit_landed]); only ever to the shooter.
signal hit_received(point: Vector3, killed: bool, headshot: bool)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: somebody else used their weapon [param times] times since the last
## snapshot. [param kind] is one of `ZeeWeaponNet.KIND_*`. Relayed from that player's own
## behaviour, because a client builds those one per JOIN and nothing else could find them.
signal weapon_used_by(session_id: int, times: int, kind: int)

## Client side: a prop arrived, at [param at].
signal prop_arrived(at: Vector3, vehicle: bool)

## Client side: the stage was rebuilt from what the server sent. The client re-places its
## camera and the HUD names the course.
signal stage_received(stage_id: StringName, is_arena: bool)

## Client side: somebody fell, crossed a checkpoint or finished. See [enum WoEvents.Progress].
signal progress_received(player_id: int, kind: int, value: int, seconds: float)

## Client side: a weapon appeared on the arena floor, or left it.
signal pickup_received(pickup_id: int, weapon_id: StringName, at: Vector3)
signal pickup_gone_received(pickup_id: int, by: int)

## Somebody pressed Enter. Server side. The bridge carries chat and decides nothing about it: who may say what, how
## often and who hears it are [DotChatRouter]'s.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: WoGame = null
var net: DotNetManager = null
var link: WoNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns the link's length in ms ([method DotClientLink.ping_ms]).
## Fed nothing, it assumes an instant link and every command is discarded as late.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [WoPlayerNet].
var _behaviours: Dictionary = {}

## The next session id for a bot, kept well above dot-server's: a player called `bot` parses
## back to session zero, which is dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

## net id -> the behaviour replicating that body, on BOTH ends.
## Keyed by net id, not instance id: an instance id is a counter in dot-props a client does not share.
var _bodies: Dictionary = {}

## Server only: `"p<instance>"` -> net id, so a removal can
## find what to unregister.
var _net_of: Dictionary = {}

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Carries the game's profile runtime over this manager (rows down, for a remote admin's panel).
var profile_link: DotNetProfileLink = null
## Server: peers whose READY came before their seat ([method add_player]). Over ENet with loss READY can overtake
## `loaded` and a dropped READY left the client waiting for a world for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether `server_tick` is on the stack, and the net ids released during it.
## A round re-laid mid-tick would otherwise let `record` recreate a history track per body.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The stage the clients were last sent, so a late joiner is sent the same bytes.
var _stage_body: PackedByteArray = PackedByteArray()

## The stage's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner, as [member _stage_body] is).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: the stage the last TOYS was for. Its mirrors are registered the moment it arrives and
## handed this end's toys when this end has built that stage ([method _pair_pending_toys]).
var _toys_stage: StringName = &""

## Client: where the mirrors live, which is not under the toys: they are registered before this
## end's stage may exist, and stay registered through a stage change.
var _toy_holder: Node3D = null


func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null


## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as WoGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

	var event := net.messages.register(
		WoEvent.NAME, WoEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		WoRequest.NAME, WoRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(WoEvent.NAME, _on_event)
	net.messages.on(WoRequest.NAME, _on_request)

	# Both ends. The server's tick is `server_tick` and the client's is `client_tick`, which
	# simulates what it predicts and leaves the rest to interpolation. A world still running
	# its own `_physics_process` would move every player twice.
	game.external_tick = true

	# The stage's toys: the server's leave the registry before their nodes go and the new ones
	# are named after STAGE; a client's mirrors stay registered and are handed this end's toys
	# when its stage is built.
	if net.is_server:
		game.world_clearing.connect(_release_toys)
	else:
		game.world_clearing.connect(_unpair_toys)
		game.world_rebuilt.connect(_pair_pending_toys)

	if net.is_server:
		_wire_server()

	return DotResult.success(true)


## Connects the server's game signals to the events that tell the clients.
func _wire_server() -> void:
	game.stage.io_message.connect(func(peer: Variant, msg: Dictionary) -> void:
		_tell(int(peer), WoEvents.Kind.WORLD_IO, WoEvents.write_world_io(msg)))
	game.player_added.connect(_on_player_added)
	game.player_removed.connect(_on_player_removed)
	game.world_clearing.connect(_on_world_clearing)
	game.world_rebuilt.connect(_on_world_rebuilt)
	game.props.spawned.connect(_on_prop_spawned)
	game.props.removed.connect(_on_prop_removed)
	game.round_began.connect(_on_round_began)
	# To the shooter alone: a hit marker is that player's business.
	game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
		var hit_peer := peer_for_player(session_of(id))
		if hit_peer > 0:
			_tell(hit_peer, WoEvents.Kind.HIT, WoEvents.write_hit(point, killed, headshot)))
	game.round_over.connect(_on_round_over)
	game.phase_changed.connect(_on_phase_changed)
	game.player_died.connect(_on_player_died)
	game.blast.connect(_on_blast)
	game.player_fell.connect(func(id: StringName, checkpoint: int) -> void:
		_broadcast(WoEvents.Kind.PROGRESS, WoEvents.write_progress(
			session_of(id), WoEvents.Progress.FELL, checkpoint + 1, 0.0))
	)
	game.checkpoint_reached.connect(func(id: StringName, index: int) -> void:
		_broadcast(WoEvents.Kind.PROGRESS, WoEvents.write_progress(
			session_of(id), WoEvents.Progress.CHECKPOINT, index, game.course_elapsed))
	)
	game.player_finished.connect(func(id: StringName, place: int, seconds: float) -> void:
		_broadcast(WoEvents.Kind.PROGRESS, WoEvents.write_progress(
			session_of(id), WoEvents.Progress.FINISHED, place, seconds))
	)
	game.pickup_placed.connect(func(pickup_id: int, weapon_id: StringName, at: Vector3) -> void:
		_broadcast(WoEvents.Kind.PICKUP, WoEvents.write_pickup(pickup_id, weapon_id, at))
	)
	game.pickup_taken.connect(func(pickup_id: int, by: StringName) -> void:
		_broadcast(WoEvents.Kind.PICKUP_GONE, WoEvents.write_pickup_gone(
			pickup_id, session_of(by) if by != &"" else 0))
	)

	if game.spectate != null:
		game.spectate.view_changed.connect(_on_spectate_changed)

	_wire_lag_compensation()


## Hands dot-combat the rewind and restore callables; unset, it resolves every shot against
## the present while the setting still reports lag compensation as on.
## The shooter is not excluded: `resolve_shot` fixes the muzzle before it rewinds anything.
func _wire_lag_compensation() -> void:
	if game.combat == null or net == null:
		return

	if game.combat.config != null:
		game.combat.config.lag_compensation = true

	game.combat.rewind_fn = func(target_tick: float) -> void:
		var _rewound := net.history.rewind(
			net.registry.all(), int(target_tick), net.clock.tick
		)

	game.combat.restore_fn = func() -> int:
		return net.history.restore()

	DotLog.debug(CHANNEL, "lag compensation is wired to the netcode's history", {
		"max_rewind_ms": game.combat.config.max_rewind_ms if game.combat.config != null else 0.0,
	})


## Opens the link under [param parent], whose NAME is half the RPC routing: Godot routes an
## RPC by node path, so a link opened elsewhere delivers nowhere, with no error.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = WoNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die with this bridge. A bare
	# add_child left a second link after a module reload and Godot renamed the live one, losing RPCs. DotGameLink
	# frees it without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, parent, self, WoNetLink.NODE_NAME)


## How every dot-net message reaches a peer, routed by DELIVERY: snapshots on the snapshot
## call, the rest reliable (events from the server, requests from the client).
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## Somebody the world drives itself: a stand-in, or a test's player.
## The same entity a peer gets, with a peer id of zero: replicated, scored and crushed like a person, minus a socket.
func add_bot(display_name: String, team: int = 0) -> WoPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	if game.stage != null and game.stage.io != null:
		game.stage.io.remove_peer(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, whose handler releases the
	# entity and broadcasts the LEAVE. Releasing first empties `_behaviours`, so this stays the one place a leaving
	# player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(WoEvents.Kind.LEAVE, WoEvents.write_player(session_id))
	roster_changed.emit(session_id)


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# Every id on the wire is `u<session>`; anything else parses back to zero. A player called `bot` would replicate
	# under session 0, also dot-net's broadcast address, and a second would silently replace the first. Refused with
	# a line rather than accepted quietly.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or WoNetBridge.player_key()",
		})
		return

	var player: WoPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(WoEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(WoEvents.Kind.LEAVE, WoEvents.write_player(session_id))
		roster_changed.emit(session_id)


func _build_entity(player: WoPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := WoPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, which on a course is the difference between
	# clearing an arm and being told it already hit you.
	identity.authority = DotNetIdentity.Authority.SHARED
	# Always, and the map is why: interest management saves where most players are out of sight, but a course is open
	# air, so culling would only make a runner vanish in mid-jump.
	identity.always_relevant = true
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	# Only ever emitted on a mirror, where the snapshot is what says a weapon was used.
	behaviour.weapon_used.connect(func(times: int, kind: int) -> void:
		weapon_used_by.emit(session_id, times, kind)
	)
	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: WoPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)


## The stage is about to be rebuilt. Nothing on it is replicated, so there is nothing to
## let go of; the props on it go through `PROP_GONE` as dot-props removes them.
func _on_world_clearing() -> void:
	pass


## A new course or arena: the whole document, to everybody, before anything that stands on it.
func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.stage == null or game.stage.doc.is_empty():
		return

	_stage_body = WoEvents.write_stage(WoCourseDoc.encode(game.stage.doc))
	_broadcast(WoEvents.Kind.STAGE, _stage_body)
	_register_toys()

	if game.stage.io != null:
		for peer_id in _ready_peers.keys():
			game.stage.io.add_peer(int(peer_id))


## Server: an entity for each of the stage's toys, and TOYS naming them, after STAGE.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.stage != null and game.stage.toys != null:
		for toy in game.stage.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = WoEvents.write_toys(game.stage.id() if game.stage != null else &"", ids)
	_broadcast(WoEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0 allocates one: the server).
## Null when the registry refused it. The behaviour goes before the identity, which collects behaviours in its
## `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> WoToyNet:
	var behaviour := WoToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		for node: Node in [behaviour, identity]:
			at.remove_child(node)
			node.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry [b]and out of the tree at once[/b]: a new identity on the
## same toy collects every behaviour under it in its `_ready`, and a freed one still found there
## broke the next snapshot (game-playground found it). A stage change, or a new TOYS.
func _release_toys() -> void:
	for behaviour: WoToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and _toy_holder != null and at.get_parent() == _toy_holder:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client, on TOYS: a mirror for every id at once. A client must know every entity a snapshot
## carries, as dot-net stops reading at the first unknown one. Paired with this end's toys by index.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_stage = told["stage_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's stage is the one TOYS
## named; none while it is not.
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.stage.toys if game.stage != null and game.stage.toys != null and game.stage.id() == _toys_stage else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's stage has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: WoToyNet = _toy_nets[i]
		if is_instance_valid(behaviour):
			behaviour.toy = box.toy(i) if box != null else null


## Client: the old stage's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: WoToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client's: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: WoToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


## How many toy entities this end has registered (a client's paired or not). For a check.
func toy_entities() -> int:
	return _toy_nets.size()


## Every prop the world puts out becomes a replicated entity, announced reliably (what it IS,
## by path so a pack can deliver it) and moved by snapshot.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	if net == null or not net.is_server or prop == null or prop.node == null:
		return

	var body := prop.node as Node3D

	if body == null:
		return

	var behaviour := WoPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var net_id := _replicate_body(behaviour, body)

	if net_id == 0:
		return

	_net_of["p%d" % prop.instance_id] = net_id
	behaviour.pull()

	_broadcast(WoEvents.Kind.PROP, WoEvents.write_prop(
		net_id, prop.def.id, body.global_position, false
	))


func _on_prop_removed(prop: DotPropInstance, reason: StringName) -> void:
	_forget_body("p%d" % prop.instance_id, reason)


## The half every replicated body does identically.
func _replicate_body(behaviour: DotNetBehaviour, body: Node3D) -> int:
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	# SERVER, not SHARED: nothing about a rigid body is predicted here, so there is no owner
	# to share with.
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a body", {"error": str(registered.error)})
		return 0

	_bodies[identity.net_id] = behaviour
	return identity.net_id


func _forget_body(key: String, reason: StringName) -> void:
	if net == null or not net.is_server or not _net_of.has(key):
		return

	var net_id := int(_net_of[key])
	_net_of.erase(key)
	_bodies.erase(net_id)

	_unregister(net_id)
	_broadcast(WoEvents.Kind.PROP_GONE, WoEvents.write_prop_gone(net_id, reason))


func net_id_of_node(node: Node) -> int:
	if node == null:
		return 0

	for net_id in _bodies:
		var behaviour: WoPropNet = _bodies[net_id] as WoPropNet

		if behaviour != null and behaviour.prop == node:
			return int(net_id)

	return 0


func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(WoEvents.Kind.ROUND, WoEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int, why: String) -> void:
	_broadcast(WoEvents.Kind.ROUND, WoEvents.write_round(number, false, winner, why))


func _on_phase_changed(phase: int) -> void:
	_broadcast(WoEvents.Kind.PHASE, WoEvents.write_phase(phase))


func _on_player_died(player_id: StringName, by: StringName, why: StringName, weapon_id: StringName) -> void:
	var who: WoPlayer = game.players.get(player_id) if game != null else null
	_broadcast(WoEvents.Kind.DEATH, WoEvents.write_death(
		session_of(player_id), session_of(by) if by != &"" else 0, why,
		who.death if who != null else null, weapon_id
	))


func _on_blast(at: Vector3, radius: float) -> void:
	_broadcast(WoEvents.Kind.BLAST, WoEvents.write_blast(at, radius))


## A view changed on the server. Told to its owner only: who somebody is watching is private, and a stand-in (peer
## zero) is told nothing, which `_tell` guarantees.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, WoEvents.Kind.SPECTATE, WoEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


## Says what somebody was handed. Called by the game through the module.
func announce_armed(player_id: StringName, weapon_id: StringName) -> void:
	_broadcast(WoEvents.Kind.ARMED, WoEvents.write_armed(session_of(player_id), weapon_id))


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities and the first player behaviour calls
	# `ensure_game_ticked`. A server with nobody on it has no behaviours, and a world that ticked only when somebody
	# was connected would stop its round clock between players.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(WoEvents.Kind.CLOCK, _clock_body())


func _clock_body() -> PackedByteArray:
	return WoEvents.write_clock(
		game.round_number,
		game.phase_elapsed,
		game.course_elapsed,
		game.phase,
		game.finished_count(),
		game.alive_count(),
		game.sides_are_playable()
	)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: WoPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wanted_slot = behaviour.last_slot
			behaviour.player.wants_grab = behaviour.last_grab

	game.tick_once(tick)

	# After the world moved everything, before the snapshot is built: a body pulled before the physics step would
	# replicate where it was last tick, correct data at the wrong instant.
	# Checked for life: a freed body's behaviour is not removed from dot-net's registry.
	for net_id in _bodies.keys():
		var behaviour: Variant = _bodies[net_id]

		if not is_instance_valid(behaviour):
			_bodies.erase(net_id)
			continue

		# Out of the tree but not yet freed is the ordinary state for the rest of a frame in
		# which a round was re-laid, and a behaviour in it has nothing to say.
		if not (behaviour as Node).is_inside_tree():
			continue

		(behaviour as DotNetBehaviour).call(&"pull")

	# The toys where the physics left them, before the snapshot.
	for behaviour: WoToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.pull()


func client_tick(tick: int, command: DotFpsCommand, slot: int = 0, grab: bool = false) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := WoNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.slot = slot
	packet.grab = grab

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: WoPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move
		mine.last_slot = slot
		mine.last_grab = grab

		if mine.player != null:
			mine.player.wanted_slot = slot

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: the props are drawn from snapshots, and the
	# course is posed by the predicted player's own controller at each tick it simulates.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.phase_elapsed += net.clock.tick_duration()

		if game.phase == game.Phase.COURSE:
			game.course_elapsed += net.clock.tick_duration()


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return WoNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## Text for one player: a refusal, a rate limit, a command's reply. To the one who asked, never broadcast: a broadcast
## refusal is a punishment announced to everybody.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, WoEvents.Kind.NOTICE, WoEvents.write_notice(text))


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, WoEvents.Kind.CHAT, WoEvents.write_chat(wire))


## A voice frame, in whichever direction. Not a [WoEvent]: voice is fifty packets a second and every event here is
## reliable. It also skips [DotNetManager], whose sealed message set buys nothing for an opaque blob that has its own
## header and validation in [DotVoicePacket].
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# One path or the other, never both: [DotGameModule] assigns `voice_relay_fn` to the services layer, so also
		# connecting `voice_requested` to the same router relays every frame twice (doubled rate limit, a sequence
		# the jitter buffer sees go backwards).
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


func _on_request(message: DotNetMessage) -> void:
	var ask := message as WoRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		WoEvents.Ask.READY:
			_admit(peer_id)
		WoEvents.Ask.SAY:
			var said := WoEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		WoEvents.Ask.TEAM:
			var wanted := WoEvents.read_ask_team(ask.reader())

			if bool(wanted["ok"]):
				_switch_team(peer_id, int(wanted["team"]))
		WoEvents.Ask.SPECTATE:
			var step := WoEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]))
		WoEvents.Ask.ROAM:
			_spectate_roam(peer_id)


## Somebody who is out asked to look at somebody else. The server's list, the server's rule. A refusal goes back as a
## notice, because a key that silently does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Somebody who is out pressed the free-roam key. The mode is the server's; the refusal
## ("Free roam is off on this server") goes back as a notice, like a refused step.
func _spectate_roam(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var toggled: DotResult = game.spectate.toggle_roam(player_key(session_id))

	if not toggled.ok:
		notice(peer_id, toggled.error.message)


func _switch_team(peer_id: int, team: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or team < 1 or team > game.config.team_count:
		return

	if not game.config.allow_team_choice:
		notice(peer_id, "This server picks the sides.")
		return

	var id := player_key(session_id)

	if not game.players.has(id):
		return

	# It lands on the next round, by rule: a player who changed sides half way along a course would carry their old
	# side's progress into their new side's win (dot-player-class documents the same for changing class).
	game.sides[id] = team
	(game.players[id] as WoPlayer).team = team

	var _moved := game.match_node.switch_team(String(id), team, _tick)
	_broadcast(WoEvents.Kind.TEAM, WoEvents.write_team(session_id, team))
	notice(peer_id, "You are on the other side from the next round.")


## Everything in the world, to one peer, once its own copy exists. On READY and not on connect: dot-server's signon
## finishes and THEN the client builds its scene, so JOIN and STAGE sent at connect land on a node that does not exist
## yet and are lost.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, WoEvents.Kind.HELLO, WoEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.config.team_count,
		game.config.countdown_seconds,
		game.course_limit(),
		game.config.handover_seconds,
		game.config.finale_seconds
	))

	# The stage, before anything that stands on it, and its toys by net id in toy order, which
	# the joiner's own copies are paired with.
	if not _stage_body.is_empty():
		_tell(peer_id, WoEvents.Kind.STAGE, _stage_body)
	if not _toys_body.is_empty():
		_tell(peer_id, WoEvents.Kind.TOYS, _toys_body)
	if game.stage != null and game.stage.io != null:
		game.stage.io.add_peer(peer_id)

	for other in _behaviours.keys():
		_tell(peer_id, WoEvents.Kind.JOIN, _join_body(int(other)))

	# And everything standing in the world. A player who joins halfway through a round has
	# to be told about every prop that is still up, or they walk into cover they cannot see.
	for net_id in _bodies:
		var behaviour: WoPropNet = _bodies[net_id] as WoPropNet

		if behaviour == null or behaviour.prop == null or not is_instance_valid(behaviour.prop):
			continue

		_tell(peer_id, WoEvents.Kind.PROP, WoEvents.write_prop(
			int(net_id),
			_kind_of(behaviour),
			behaviour.replicated_position(),
			false
		))

	for pickup_id: int in game.pickups:
		var pickup: Dictionary = game.pickups[pickup_id]
		_tell(peer_id, WoEvents.Kind.PICKUP, WoEvents.write_pickup(pickup_id, pickup["weapon"], pickup["at"]))

	_tell(peer_id, WoEvents.Kind.PHASE, WoEvents.write_phase(game.phase))
	_tell(peer_id, WoEvents.Kind.CLOCK, _clock_body())


## Which catalogue entry a replicated body came from. Read off the spawners rather than remembered beside the table,
## so there is no second copy to disagree; only asked for on a join.
func _kind_of(behaviour: WoPropNet) -> StringName:
	var prop := game.props.prop_for_node(behaviour.prop) if game.props != null else null
	return prop.def.id if prop != null and prop.def != null else WoContent.CRATE


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: WoPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return WoEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		game.team_of(behaviour.player.player_id),
		behaviour.player.avatar
	)


## Tells everybody who somebody is now (a late profile, a wardrobe change, a rename). Server only.
## Through JOIN, which a client already applies and which is idempotent, rather than a second message with a second
## arrival order. An empty [param display_name] keeps the current one.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: WoPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(WoEvents.Kind.JOIN, _join_body(session_id))
	return true


## To every peer that has said it is ready, and nobody else. An empty body is dropped, not sent: it means an encoder
## was handed something already gone, and a zero-length event decodes on the far end as a valid message about nothing.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## One peer, and never zero: `net.send(msg, 0)` is a BROADCAST in dot-net, so passing a missing peer id straight
## through would send one player's private message to everybody.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(WoEvent.new(kind, body), peer_id)


func ask_ready() -> void:
	_ask(WoEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(WoEvents.Ask.SAY, WoEvents.write_say(channel_id, text))


func ask_team(team: int) -> void:
	_ask(WoEvents.Ask.TEAM, WoEvents.write_ask_team(team))


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_roam() -> void:
	_ask(WoEvents.Ask.ROAM, WoEvents.write_ask_roam())


func ask_spectate(direction: int) -> void:
	_ask(WoEvents.Ask.SPECTATE, WoEvents.write_ask_spectate(direction))


## Sends one encoded voice packet to the server. Client side.
func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(WoRequest.new(kind, body), 1)


func _on_event(message: DotNetMessage) -> void:
	var event := message as WoEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		WoEvents.Kind.HELLO:
			_apply_hello(reader)
		WoEvents.Kind.STAGE:
			_apply_stage(reader)
		WoEvents.Kind.TOYS:
			var told := WoEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		WoEvents.Kind.WORLD_IO:
			var mapped := WoEvents.read_world_io(reader)
			if bool(mapped["ok"]) and game != null and game.stage != null:
				game.stage.io_receive(mapped["msg"])
		WoEvents.Kind.JOIN:
			_apply_join(reader)
		WoEvents.Kind.LEAVE:
			var session_id := WoEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(player_key(session_id))
			roster_changed.emit(session_id)
		WoEvents.Kind.TEAM:
			var side := WoEvents.read_team(reader)

			if bool(side["ok"]):
				var id := player_key(int(side["player_id"]))
				game.sides[id] = int(side["team"])

				if game.players.has(id):
					(game.players[id] as WoPlayer).team = int(side["team"])

				roster_changed.emit(int(side["player_id"]))
		WoEvents.Kind.PROP:
			_apply_prop(reader)
		WoEvents.Kind.PROP_GONE:
			_apply_prop_gone(reader)
		WoEvents.Kind.CLOCK:
			_apply_clock(reader)
		WoEvents.Kind.ROUND:
			_apply_round(reader)
		WoEvents.Kind.PHASE:
			_apply_phase(reader)
		WoEvents.Kind.DEATH:
			var death := WoEvents.read_death(reader)

			if bool(death["ok"]):
				# The fall goes on the player before anybody hears of the death, so the client
				# that draws it reads the server's pick.
				var fell: WoPlayer = game.players.get(player_key(int(death["player_id"]))) \
					if game != null else null
				if fell != null and death.has("death"):
					fell.death = death["death"]
				death_received.emit(
					int(death["player_id"]), int(death["by"]), death["why"], death["weapon_id"]
				)
		WoEvents.Kind.BLAST:
			var went_off := WoEvents.read_blast(reader)

			if bool(went_off["ok"]):
				blast_received.emit(went_off["position"], float(went_off["radius"]))
		WoEvents.Kind.HIT:
			var hit := WoEvents.read_hit(reader)

			if bool(hit["ok"]):
				hit_received.emit(hit["point"], bool(hit["killed"]), bool(hit["headshot"]))
		WoEvents.Kind.ARMED:
			var armed := WoEvents.read_armed(reader)

			if bool(armed["ok"]):
				# Noted on the player here rather than by whoever listens, so every client
				# draws the gun in a watched player's hand: see `WoPlayer.dealt`.
				var dealt_to: WoPlayer = game.players.get(player_key(int(armed["player_id"]))) \
					if game != null else null
				if dealt_to != null:
					dealt_to.note_dealt(armed["weapon_id"], game.round_number)
				armed_received.emit(int(armed["player_id"]), armed["weapon_id"])
		WoEvents.Kind.CHAT:
			var wire := WoEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		WoEvents.Kind.NOTICE:
			var text := WoEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		WoEvents.Kind.SPECTATE:
			_apply_spectate(reader)
		WoEvents.Kind.PROGRESS:
			var moved := WoEvents.read_progress(reader)

			if bool(moved["ok"]):
				progress_received.emit(int(moved["player_id"]), int(moved["kind"]),
					int(moved["value"]), float(moved["seconds"]))
		WoEvents.Kind.PICKUP:
			var lying := WoEvents.read_pickup(reader)

			if bool(lying["ok"]):
				game.pickups[int(lying["pickup_id"])] = {"weapon": lying["weapon_id"], "at": lying["position"]}
				pickup_received.emit(int(lying["pickup_id"]), lying["weapon_id"], lying["position"])
		WoEvents.Kind.PICKUP_GONE:
			var gone := WoEvents.read_pickup_gone(reader)

			if bool(gone["ok"]):
				game.pickups.erase(int(gone["pickup_id"]))
				pickup_gone_received.emit(int(gone["pickup_id"]), int(gone["by"]))


func _apply_round(reader: DotNetReader) -> void:
	var round_info := WoEvents.read_round(reader)

	if bool(round_info["ok"]):
		game.round_number = int(round_info["round"])

		if bool(round_info["began"]):
			game.phase_elapsed = 0.0
			game.course_elapsed = 0.0

		round_changed.emit(
			int(round_info["round"]),
			bool(round_info["began"]),
			int(round_info["winner"]),
			str(round_info["why"])
		)


func _apply_phase(reader: DotNetReader) -> void:
	var moved := WoEvents.read_phase(reader)

	if bool(moved["ok"]):
		game.phase = int(moved["phase"])
		game.phase_elapsed = 0.0

		if game.stage != null and game.stage.is_course():
			game.stage.gate_closed = game.phase == game.Phase.COUNTDOWN \
				or game.phase == game.Phase.IDLE

		phase_received.emit(int(moved["phase"]))


func _apply_spectate(reader: DotNetReader) -> void:
	var view := WoEvents.read_spectate(reader)

	if bool(view["ok"]) and game.spectate != null:
		game.spectate.apply_view(
			player_key(int(view["viewer"])),
			int(view["mode"]),
			player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
			player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
			view["death_at"]
		)
		spectate_received.emit(
			int(view["viewer"]), int(view["mode"]), int(view["target"])
		)


func _apply_hello(reader: DotNetReader) -> void:
	var hello := WoEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# The server's tick rate, before anything is derived from it, and before `sync_from_server`, whose clock converts
	# its error and lead through `tick_rate`. A client that counted at its export's 60 against a server on 128 got
	# every replicated time wrong, and a one-process suite cannot see it because both ends share an engine rate.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.team_count = clampi(int(hello["team_count"]), 0, 6)
	game.config.countdown_seconds = float(hello["countdown_seconds"])
	game.config.course_seconds = float(hello["course_seconds"])
	game.config.handover_seconds = float(hello["handover_seconds"])
	game.config.finale_seconds = float(hello["finale_seconds"])

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client (world, controllers and the ENGINE) on the server's rate: at 60 against 128 the clock ran
## ticks in bursts and the camera stuttered. A server never calls this; adopting a peer's rate is a client telling it.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to
	# a quarter second of ticks, so a slow-frame client keeps up with the server. A shell built
	# before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## The stage, which on a client is a document it builds exactly as the server did. Refused with a line, never half
## built: a client a format behind gets no course and a WARN rather than a course with holes in it.
func _apply_stage(reader: DotNetReader) -> void:
	var told := WoEvents.read_stage(reader)

	if not bool(told["ok"]) or game == null:
		return

	var decoded := WoCourseDoc.decode(told["encoded"])

	if not decoded.ok:
		DotLog.warn(CHANNEL, "the server sent a stage this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return

	# Awaits only when a mesh is not mounted and a pack groups it; otherwise this runs straight through.
	for mesh in WoWorld.missing(decoded.value):
		var got: DotResult = await WoWorld.fetch(mesh)

		if not got.ok:
			DotLog.warn(CHANNEL, "a course mesh would not download", {"mesh": mesh, "why": got.error.message})

	var built := game.build_stage(decoded.value)

	if built.ok:
		stage_received.emit(game.stage.id(), game.stage.is_arena())


func _apply_join(reader: DotNetReader) -> void:
	var join := WoEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: WoPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# Owner 0 made `is_owner` false for the local player, so `client_tick` simulated nobody and every check still passed.
		# By session, not a wire peer id (JOIN carries none): `is_owner` compares against THIS registry's local peer.
		# HELLO precedes every JOIN, but [method _apply_hello] still claims a player that got here first.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	game.sides[id] = int(join["team"])
	player.team = int(join["team"])
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client for its own, the server's 0 otherwise. Never the local peer
## for anybody else, or it would predict a person whose keys it never had. A local peer of 0 claims nothing (0 is the
## server's owner id; `WoClient` never gets 0).
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was. Belt and braces: `_admit` sends
## HELLO first, but a JOIN ahead of it would leave the local player unpredicted with every check still passing (see
## [method _apply_join]).
func _claim_local_player() -> void:
	var mine: WoPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


## A prop or a chopper the server has put out.
func _apply_prop(reader: DotNetReader) -> void:
	var info := WoEvents.read_prop(reader)

	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	if _bodies.has(net_id):
		return

	var kind_id: StringName = info["kind_id"]
	var scene_path := _scene_for(kind_id, bool(info["vehicle"]))

	if scene_path == "":
		# Not an error: a server may run a catalogue this build does not have, and the
		# honest answer is to draw nothing rather than to guess.
		DotLog.debug(CHANNEL, "something this build does not have", {"id": String(kind_id)})
		return

	var scene: PackedScene = load(scene_path)

	if scene == null:
		DotLog.warn(CHANNEL, "a scene would not load", {"path": scene_path})
		return

	var body := scene.instantiate() as Node3D

	if body == null:
		return

	game.add_child(body)
	body.global_position = info["position"]

	# [b]Frozen before anything else touches it.[/b] A mirrored body must not be simulated
	# locally as well: an unfrozen [RigidBody3D] fights every position written into it and
	# the result is a crate jittering against gravity while the packets say it is falling.
	var rigid := body as RigidBody3D

	if rigid != null:
		rigid.freeze = true

	var behaviour := WoPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a body", {"error": str(registered.error)})
		body.queue_free()
		return

	_bodies[net_id] = behaviour
	prop_arrived.emit(body.global_position, bool(info["vehicle"]))


## Where a client finds the scene for something the server named. Both catalogues, because the event carries a
## catalogue id and each build turns it into its own path; that is why no script name is sent.
func _scene_for(kind_id: StringName, _vehicle: bool) -> String:
	var prop := game.props.catalogue.get_prop(kind_id) if game.props != null else null
	return prop.scene_path if prop != null else ""


func _apply_prop_gone(reader: DotNetReader) -> void:
	var info := WoEvents.read_prop_gone(reader)

	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])
	# Checked for life before it is cast: a client disconnected mid-round frees its scene with the bridge's entries
	# still in `_bodies`, and casting a freed object is a script error, not a null.
	var entry: Variant = _bodies.get(net_id)
	_bodies.erase(net_id)

	if entry == null or not is_instance_valid(entry):
		return

	var behaviour := entry as WoPropNet
	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.prop != null and is_instance_valid(behaviour.prop):
		behaviour.prop.queue_free()


func _apply_clock(reader: DotNetReader) -> void:
	var clock := WoEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.phase_elapsed = float(clock["elapsed"])
	game.course_elapsed = float(clock["course_elapsed"])
	game.phase = int(clock["phase"])
	game.remote_finished = int(clock["finished"])
	game.remote_alive = int(clock["alive"])
	game.remote_playable = bool(clock["playable"])


func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"bodies": _bodies.size(),
		"toys": toy_count(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"bodies     %d replicated" % _bodies.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
