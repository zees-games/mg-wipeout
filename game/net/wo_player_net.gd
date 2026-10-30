extends DotNetBehaviour

const WoNetCommand := preload("wo_net_command.gd")
const WoPlayer := preload("../wo_player.gd")

## What a networked player replicates: movement state (from [DotFpsNetSync.state_specs], never listed twice), health,
## and course progress. Side is NOT here: it changes once a round and arrives in a JOIN and a TEAM.

## Somebody this client is watching used their weapon, [param times] times since the last
## snapshot. What a game draws a muzzle flash from.
signal weapon_used(times: int, kind: int)

var player: WoPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, the one field with a hard cap on the wire. Sent against 0..1000, not the player's maximum: raising
## `player_health` mid-round would change what every earlier number MEANT.
var net_health: float = 100.0

## Where they are on the course, which the HUD of everybody watching reads: the checkpoint
## (offset by one, so "none" is zero on the wire) and whether they are across.
var net_checkpoint: int = 0
var net_finished: bool = false

## Points this match and the server's last ping for the player, for everybody's Tab board.
var net_points: int = 0
var net_ping: int = 0

## In the gallery, watching a final death they did not reach.
var net_watching: bool = false

## Carrying a prop on the gravity gun, which only the server runs. One bit, so a watcher
## draws both arms out under the prop instead of a crate following somebody about.
var net_carrying: bool = false

# Seven fields, and the pack's `ZeeWeaponNet.all_specs()` names all of them: GDScript has no dynamic properties, and
# forgetting dot-weapon's half presents as weapons silent for everybody but the holder. The magazine and reserve are
# `owner_only`: exact ammunition is information an opponent should not have.

var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false

## `WoPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `WoPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## `WoPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## What this watcher last saw of that counter, so a wrap is read as uses rather than as a
## negative. One integer per watched player, which is what lets `ZeeWeaponNet` keep none.
var _seen_fire_seq: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

## And the slot they last asked for, which is simulation state on the showdown's side of
## the round: the arsenal is edge-triggered against it.
var last_slot: int = 0

var last_grab: bool = false

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	replicate(&"net_checkpoint", DotNetVar.Type.UINT).bits(6)
	replicate(&"net_finished", DotNetVar.Type.BOOL)
	replicate(&"net_points", DotNetVar.Type.UINT).bits(16)
	replicate(&"net_ping", DotNetVar.Type.UINT).bits(10)
	replicate(&"net_watching", DotNetVar.Type.BOOL)
	replicate(&"net_carrying", DotNetVar.Type.BOOL)

	for spec in ZeeWeaponNet.all_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if bool(spec["owner_only"]):
			var _owner := declaration.to_owner_only()

	# State rather than an event, so a late joiner or a lost snapshot is corrected by the next baseline. The blind goes
	# to its owner alone, or an opponent would know the moment somebody could not see. No relevance change for a beacon:
	# turning `always_relevant` off would drop the player from everybody's snapshot.
	var _blind := replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as WoNetCommand

	if command != null:
		last_move = command.move
		last_slot = command.slot
		last_grab = command.grab

		if player != null:
			player.wanted_slot = command.slot
			player.wants_grab = command.grab


## On the authority the whole game ticks as one (players move, then platforms are stepped, then what landed on what is
## decided), so the first behaviour through drives the world. A predicting client simulates its one predicted player;
## everything else is somebody else's answer.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the controller's own tick, which poses the course at this tick
		# first and lets it act on the player after (see [WoController]) — the same three
		# steps the server takes, so a knock predicted here is the knock the server decides.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health

	net_checkpoint = clampi(player.checkpoint + 1, 0, 63)
	net_finished = player.finished
	net_points = clampi(player.points, 0, 65535)
	net_ping = clampi(player.ping_ms, 0, 1023)
	net_watching = player.watching
	net_carrying = player.grab != null and player.grab.is_carrying()
	net_blind = player.blinded
	net_beacon = player.beacon
	net_warp = player.warps & 0xF

	# After the arsenal has simulated, which on this end it has: the whole world ticks before anything is pulled. A
	# rig that does not exist yet leaves these at zero, which is a carrier holding nothing, and true.
	if player.weapons != null:
		ZeeWeaponNet.pull(player.weapons, self)


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# NOT the node, on a predicted entity: `receive_snapshot` calls this BEFORE the predictor reconciles, which reads
	# the node as "what the client is showing"; moving it makes the error the whole replay distance.
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one. The server counts the times it PUT this player
## somewhere (`WoPlayer.place_at`); a mirror that sees it change drops the interpolator's track before the new snapshot
## is added (this runs inside the snapshot read). Not on the predicted entity.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror: what the server decided about this runner.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	player.checkpoint = net_checkpoint - 1
	player.finished = net_finished
	player.points = net_points
	player.ping_ms = net_ping
	player.watching = net_watching
	player.carrying = net_carrying

	player.blinded = net_blind
	player.beacon = net_beacon

	_apply_weapons()


## What a watcher does with somebody else's weapon state: a counter in the snapshot, never an event per shot (which
## needs a reliable channel and can flash a holstered weapon). The answer is written onto the player, not handed to
## `ZeeWeaponNet.apply`, because the figure is built lazily; `WoPlayer.present_body` hands it over when drawn.
func _apply_weapons() -> void:
	var answer := ZeeWeaponNet.apply(self, null, _seen_fire_seq)
	_seen_fire_seq = int(answer["seq"])

	player.mirrored = true
	player.mirror_slot = net_slot
	player.mirror_switching = net_switching
	player.mirror_fired += int(answer["fired"])
	if int(answer["fired"]) > 0:
		player.mirror_fire_kind = int(answer["kind"])

	if int(answer["fired"]) > 0:
		weapon_used.emit(int(answer["fired"]), int(answer["kind"]))
