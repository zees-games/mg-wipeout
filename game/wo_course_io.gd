extends RefCounted

const WoWorld := preload("wo_world.gd")

## A course that runs a map's own entity logic: dot-map's [DotMapWorld] hosted under a stage.
## The server steps it once a tick and sends changes through [signal message]; a client builds the same world
## without logic and poses every mover for its tick (game tick `T` is logic tick `T - base`).

const CHANNEL := "wo.io"

## Before a client has heard from the server's clock.
const NO_BASE := -2147483648

## `(peer, message)`: one message for one peer, from the world's state sync. Server only.
signal message(peer: Variant, msg: Dictionary)

var world: DotMapWorld = null
var stage_id: StringName = &""
var authoritative: bool = true
var rate: int = 64
var base: int = NO_BASE

## Collider instance id to the mover entity whose model carries it.
var _movers: Dictionary = {}
## Touch doors, teleports and kill volumes read from the map ([DotBotLinks]); built on first use.
var _links: DotBotLinks = null
## Set while a stand-in plays: it opens touch doors the way a body walking in would (dot-map does it); a person is not helped.
var touch_doors: bool = false:
	set(value):
		touch_doors = value
		if world != null:
			world.touch_doors = value
			world.touch_interval_steps = rate
var _posed: int = NO_BASE


## Builds the world of the `world` piece [param spec]; null with a line when it would not.
func build(spec: Dictionary, p_stage_id: StringName, hooks: Dictionary, p_authoritative: bool,
		draw: bool, p_rate: int) -> DotMapWorld:
	stage_id = p_stage_id
	authoritative = p_authoritative
	rate = p_rate
	var wired := hooks.duplicate()
	wired["send_fn"] = func(peer: Variant, msg: Dictionary) -> void:
		var sent := msg.duplicate()
		sent["stage"] = String(stage_id)
		sent["base"] = base
		message.emit(peer, sent)

	if not p_authoritative:
		wired.erase("send_fn")

	world = WoWorld.build_io(spec, wired, p_authoritative, draw, p_rate)
	return world


## Switches the map's brushes to their state again: the world layer put on every body after the map's start
## undid the ones it had switched off (a spawn wall that is off until a timer closes it).
func reseat_brushes() -> void:
	for e: DotMapEntity in world.io.entities:
		if e is DotMapToggleBrush and e.node != null:
			e._view_changed("enabled", e.enabled)


## Names the movers' bodies, once the world is in the tree.
func index_movers() -> void:
	_movers.clear()

	if world == null:
		return

	for e: DotMapEntity in world.io.entities:
		if e is DotMapMoverNode and (e as DotMapMoverNode).node != null:
			var node: Node = (e as DotMapMoverNode).node

			if node is CollisionObject3D:
				_movers[node.get_instance_id()] = e

			for body: Node in node.find_children("*", "CollisionObject3D", true, false):
				_movers[body.get_instance_id()] = e


## Server: the logic's clock starts now, at game tick [param tick].
func begin(tick: int) -> void:
	if authoritative:
		base = tick


## Server, once a tick after the players moved: advance the logic and the volumes. [param bodies]
## are [DotMapVolumes] body dictionaries.
func step(tick: int, bodies: Array) -> void:
	if world == null or not authoritative or base == NO_BASE:
		return

	world.step(bodies)
	_mirror()
	_posed = tick


## What the map's entities say about where a body can go and what opens by touch.
func links() -> DotBotLinks:
	if _links == null:
		_links = DotBotLinks.read(world, {"nav_export": DotMapNavLinks.read(world)})
	return _links


## Both ends, before a body moves on [param tick]: movers where the server had them when it
## simulated that tick. The server posed them at the end of the last tick; a client works it out.
func pose_at(tick: int) -> void:
	if world == null or authoritative or base == NO_BASE or tick == _posed:
		return

	_posed = tick
	world.io.now = tick - base - 2
	world.io.advance(1)
	_mirror()


## A client takes one message the server sent for this stage.
func apply(msg: Dictionary) -> void:
	if authoritative:
		return

	if msg.get("base") is int or msg.get("base") is float:
		base = int(msg["base"])

	var applied := world.apply_state(msg)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a map state message was refused", {"why": applied.error.message})

	_posed = NO_BASE


## The displacement of whoever stands on [param collider], carried as the mover under it moves
## from the pose of `tick` to the next, or zero when it is not a mover's.
func carry(collider: int, at: Vector3, tick: int) -> Vector3:
	var mover: DotMapMoverNode = _movers.get(collider)

	if mover == null or base == NO_BASE or not mover.alive:
		return Vector3.ZERO

	var now := mover.pose_delta(tick - base, rate)
	var before := mover.pose_delta(tick - base - 1, rate)
	return (now * before.affine_inverse()) * at - at


## The mover whose model carries the body [param collider], or null.
func mover_of(collider: int) -> DotMapMoverNode:
	return _movers.get(collider)


func carries(collider: int) -> bool:
	return _movers.has(collider)


## A joiner gets the whole state, then every change (server).
func add_peer(peer: Variant) -> void:
	if world != null and authoritative:
		world.add_peer(peer)


func remove_peer(peer: Variant) -> void:
	if world != null and authoritative:
		world.remove_peer(peer)


## Every mover's body into the physics server now: a node's transform reaches it a frame late,
## and a replayed tick would be swept against where the machinery was a frame ago.
func _mirror() -> void:
	for id: int in _movers:
		var body := instance_from_id(id) as CollisionObject3D

		if body != null and body.is_inside_tree():
			PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
				body.global_transform)


func describe() -> Dictionary:
	return {"stage": String(stage_id), "base": base, "movers": _movers.size(),
		"world": world.describe() if world != null else {}}
