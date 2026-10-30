extends RefCounted

## How a stand-in runs a course that is a map's own world (see [WoCourseIo]): it walks dot-bot's navigation mesh,
## baked from static colliders, to the finish; teleports are edges and kill volumes are cut out ([DotBotLinks]).
## Movers are left out of the bake, so where the way on needs one the path ends short; [method reaches_finish] says.

const CHANNEL := "wo.io_bot"

## Metres a path point is reached within, and ticks between new paths.
const REACHED := 0.6
const REPATH_TICKS := 32
## A jump is taken for a point this far above the feet; a second without half a metre of progress is a jump too.
const JUMP_RISE := 0.4
## A step this long in one tick is the map's doing, not the stand-in's.
const TELEPORTED := 3.0
const STUCK_TICKS := 64
const STUCK_METRES := 0.5
## Metres from the end of the path at which the floor has nothing more to offer.
const STALLED := 2.0
## Metres (flat) from the finish within which the end of the floor is dived off, straight at it.
const DIVE_REACH := 80.0
## Ticks standing where a button or trigger fires before it counts as fired (a box test is looser than the brush).
const HOLD_TICKS := 24
## Replans (32 ticks each) an errand may take before it is given up.
const ERRAND_REPATHS := 200
## Windows of a second without progress after which an errand is given up.
const GIVE_UP_STUCK := 5
## Ticks a platform may be waited for, at a dock or aboard, before the leg is given up.
const RIDE_PATIENCE := 64 * 25
## Metres from a leg's start within which a bot waits for the platform.
const DOCK_REACH := 1.4
## Metres from a hop edge's start at which the jump is pressed.
const HOP_REACH := 0.7
## Metres from a ladder edge's foot at which the climb starts.
const LADDER_REACH := 0.7
## Metres ahead of the feet a hurt volume is looked for.
const KILL_LOOK := 1.3
## Ticks held at a kill edge before the edge is given up, and ticks another mesh point is walked to in its place.
const EDGE_PATIENCE := 96
const WANDER_TICKS := 64 * 12
## Flat metres within which a route point is reached, and ticks one step may take before it is given up.
const ROUTE_REACH := 0.8
const ROUTE_PATIENCE := 64 * 25

var nav: DotBotNav = DotBotNav.new()
## The io instance this was baked for: a new one means a new course.
var source: Object = null
## The map's teleports (joined once the mesh is ready) and kill volumes (cut out of it).
var links: DotBotLinks = null
var _joined := false
## Buttons and triggers already gone to (entity index to true), and the one being walked to now.
var _done := {}
var _errand := {}
var _held := 0
var _age := 0
## Windows of a second in a row without half a metre of progress.
var _stuck := 0
## A course's scripted steps (`io_route` in its document) walked before the mesh takes over: `{"to": [x, y, z]}` a
## point walked straight to (`"jump": true` hops on the way, `"speed": 0.5` walks slower so a hop lands short), `{"use": entity}` a button used, `{"wait": seconds}`.
## What the mesh cannot know (a door, a button chain, an arrival the map teleports to) is named here by a person.
var _route: Array = []
var _route_at := 0
var _route_since := 0
## Steps finished, and steps given up after ROUTE_PATIENCE ticks.
var route_done := 0
var route_skipped := 0
## Strides held back for a hurt volume ahead.
var _avoided := 0
## Consecutive ticks held at a kill edge, and the mesh point walked to instead once that passes EDGE_PATIENCE.
var _edge := 0
var _wander := Vector3.INF
var _wander_until := 0
var _wander_rng := DotRandomStream.new(900).stream(&"wo_io_bot_wander")

## The platform leg being ridden (a link of [member DotBotLinks.platform_links]) and the ticks spent on it.
var _clock := 0
var _hops: Array[Dictionary] = []
var _ladder_rides: Array[Dictionary] = []
## The ladder being climbed (dot-bot's step function), or null.
var _climb: DotBotClimb = null
var _hops_for: NavigationMesh = null
var _ride := {}
var _ride_ticks := 0

var _world: Node3D = null
var _agent := {}
## Ticks at which the mesh is baked again, after a button or trigger changed the map (a wall that breaks, a door that goes).
var _rebakes: Array[int] = []

var _goal := Vector3.ZERO
var _finish := AABB()
var _path := PackedVector3Array()
var _path_tick := -REPATH_TICKS
var _mark := {}
var _last_feet := Vector3.INF


## Bakes the static (never the moving) colliders of [param world] and aims at [param finish].
func setup(p_source: Object, world: Node3D, finish: AABB, agent: Dictionary, p_links: DotBotLinks, p_route: Array = []) -> void:
	source = p_source
	_route = p_route
	_route_at = 0
	links = p_links
	links.carve(nav)
	_finish = finish
	_goal = Vector3(finish.get_center().x, finish.position.y + 0.5, finish.get_center().z)
	_world = world
	_agent = agent
	_bake()


## Bakes the map as it stands: static colliders, doors posed open, floor where a platform can lie.
func _bake() -> void:
	var bodies: Array = []
	_statics(_world, bodies)
	# doors baked open: shut they are walls on the mesh and nothing walks to them
	var undo := links.pose_open()
	bodies.append_array(links.swing_bodies())
	# rafts and lifts: a floor wherever one can lie, with legs between (ridden by waiting for it, see _on_platform)
	var copies := links.stop_bodies(_world, _world.get("io"))
	bodies.append_array(copies)
	var baked := nav.bake_in_background(_world, _agent, 0, bodies)
	links.free_stop_bodies(copies)
	links.restore(undo)
	if not baked.ok:
		DotLog.warn(CHANNEL, "no mesh baked", {"why": baked.error.message})


func is_ready() -> bool:
	if nav.is_ready() and not _joined and links != null:
		_joined = true
		var _stats := links.join(nav)
	return nav.is_ready()


## Whether a path from [param from] ends in the finish: the floor alone gets there.
func reaches_finish(from: Vector3) -> bool:
	return _reaches(nav.path(from, _goal))


## The metres still to walk to the nearest point the floor reaches toward the finish.
func path_to(from: Vector3) -> PackedVector3Array:
	return nav.path(from, _goal)


## Sets [param command]'s heading, movement and jump for a stand-in at [param feet] on [param tick].
func steer(feet: Vector3, grounded: bool, tick: int, player_id: StringName, command: DotFpsCommand) -> void:
	_clock = tick
	if not _rebakes.is_empty() and tick >= _rebakes[0] and nav.is_ready():
		_rebakes.pop_front()
		_bake()
		return
	if not is_ready():
		return
	# Moved by the map (a teleport): the path ahead is the one from before it.
	if _last_feet.distance_to(feet) > TELEPORTED:
		_path_tick = -REPATH_TICKS
		_climb = null
		if not _errand.is_empty() and _errand["kind"] == "teleport":
			_arrived()
	_last_feet = feet
	if tick - _path_tick >= REPATH_TICKS:
		_replan(feet)
		_path_tick = tick
	_held = _held + 1 if not _errand.is_empty() and links.at_gadget(_errand, feet) else 0
	if _held >= HOLD_TICKS:
		_arrived()
		_replan(feet)
		_path_tick = tick

	if _route_step(feet, grounded, command):
		return
	if _on_platform(feet, tick, command):
		return

	if _climb_step(feet, tick, command):
		return

	var target := _into_teleport(_next_point(feet), feet)
	if target == Vector3.INF:
		target = _dive(feet)
		if target == Vector3.INF:
			return

	var toward := target - feet
	toward.y = 0.0
	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)
	if grounded and _kill_ahead(feet, toward):
		command.move = Vector2.ZERO
		_edge += 1
		if _edge >= EDGE_PATIENCE:
			_edge = 0
			_wander = nav.random_point(_wander_rng)
			_wander_until = tick + WANDER_TICKS
			_path_tick = -REPATH_TICKS
		return
	_edge = 0

	var mark: Dictionary = _mark.get(player_id, {"tick": tick, "at": feet})
	if tick - int(mark["tick"]) >= STUCK_TICKS:
		if grounded and (mark["at"] as Vector3).distance_to(feet) < STUCK_METRES:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			_stuck += 1
		else:
			_stuck = 0
		mark = {"tick": tick, "at": feet}
	_mark[player_id] = mark

	if grounded and _at_hop(feet):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
	if grounded and target.y - feet.y > JUMP_RISE:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## Walks the scripted route; returns whether it set the command. A step is done when reached, used or waited out.
func _route_step(feet: Vector3, grounded: bool, command: DotFpsCommand) -> bool:
	if _route_at >= _route.size():
		return false
	var step: Dictionary = _route[_route_at]
	_route_since += 1
	if step.has("use"):
		var world: Object = source.get("world")
		var _result: Variant = world.get("io").call("use", int(step["use"]), null)
		_rebakes.append(_clock + 48)
		_rebakes.append(_clock + 64 * 5)
		_finish_step(true)
		return false
	if step.has("wait"):
		if _route_since >= int(float(step["wait"]) * 64.0):
			_finish_step(true)
		return true
	var to := Vector3(float(step["to"][0]), float(step["to"][1]), float(step["to"][2]))
	var toward := to - feet
	toward.y = 0.0
	if toward.length() < ROUTE_REACH:
		_finish_step(true)
		return false
	if _route_since > ROUTE_PATIENCE:
		_finish_step(false)
		return false
	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, clampf(float(step.get("speed", 1.0)), 0.1, 1.0))
	if grounded and (bool(step.get("jump", false)) or to.y - feet.y > JUMP_RISE):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
	_path_tick = -REPATH_TICKS
	return true


func _finish_step(reached: bool) -> void:
	_route_at += 1
	_route_since = 0
	if reached:
		route_done += 1
	else:
		route_skipped += 1


## Waits at a dock for the platform, steps aboard when it is there, stays on it until it lies at the far stop, then
## steps off. Returns whether it has set the command (the caller then steers nothing).
func _on_platform(feet: Vector3, tick: int, command: DotFpsCommand) -> bool:
	var world: Object = source.get("world") if source != null else null
	var io: Object = world.get("io") if world != null else null
	if links == null or io == null or links.platform_links.is_empty():
		return false
	if _ride.is_empty():
		var leg := links.platform_link_near(feet, DOCK_REACH)
		if leg.is_empty() or not _path_uses(leg):
			_ride_ticks = 0
			return false
		_ride_ticks += 1
		if _ride_ticks > RIDE_PATIENCE:
			# give up this leg: the path will not use it again
			_ride_ticks = 0
			return false
		if not links.platform_at_stop(int(leg["platform"]), int(leg["stop_from"]), io):
			return true
		_ride = leg
		_ride_ticks = 0
	_ride_ticks += 1
	var platform := int(_ride["platform"])
	var to: Vector3 = _ride["to"]
	var centre := links.platform_centre(platform, io)
	var arrived := links.platform_at_stop(platform, int(_ride["stop_to"]), io)
	var flat_to := Vector2(to.x - feet.x, to.z - feet.z).length()
	if _ride_ticks > RIDE_PATIENCE or (arrived and flat_to < 0.8) or (not arrived and Vector2(centre.x - feet.x, centre.z - feet.z).length() > 3.0 \
			and not links.platform_at_stop(platform, int(_ride["stop_from"]), io)):
		_ride = {}
		_ride_ticks = 0
		_path_tick = -REPATH_TICKS
		return false
	var aim := to if arrived else centre
	var toward := aim - feet
	toward.y = 0.0
	if toward.length() > 0.4:
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
	return true


## Whether one more stride toward [param toward] would carry the body into a hurt volume, learned from the live
## volumes (one that was off when the mesh was baked, or hurts less than a kill, is not cut out of it). The volume is
## then cut out of the mesh and the path planned again, so the stand-in stops short of it rather than through it.
func _kill_ahead(feet: Vector3, toward: Vector3) -> bool:
	var world: Object = source.get("world") if source != null else null
	if world == null or world.get("volumes") == null or toward.length() < 0.01:
		return false
	var probe := feet + toward.normalized() * KILL_LOOK
	var space: PhysicsDirectSpaceState3D = (_world as Node3D).get_world_3d().direct_space_state
	var ground := -INF
	var checked := false
	for node: Object in world.get("volumes").get("nodes"):
		var volume: Object = node.get("volume")
		if str(volume.get("kind")) != "hurt" or not node.call("active"):
			continue
		var box: AABB = volume.call("bounds")
		if _finish.grow(1.0).intersects(box) or box.has_point(feet) or box.grow(0.2).has_point(feet):
			continue
		if not (probe.x >= box.position.x and probe.x <= box.end.x and probe.z >= box.position.z and probe.z <= box.end.z) or box.position.y > feet.y + 2.0:
			continue
		if not checked:
			checked = true
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(probe + Vector3(0.0, 0.4, 0.0), probe + Vector3(0.0, -6.0, 0.0), 1))
			ground = (hit["position"] as Vector3).y if not hit.is_empty() else -INF
		if ground <= box.end.y + 0.05:
			var cut := AABB(box.position - Vector3(0.6, 0.0, 0.6), box.size + Vector3(1.2, 0.0, 1.2))
			if not nav.avoid.has(cut):
				nav.avoid.append(cut)
				_rebakes.append(_clock + 1)
			_avoided += 1
			return true
	return false


## Climbs a ladder edge the path crosses: begins at its foot, then follows dot-bot's [DotBotClimb] to the top.
## Returns whether it set the command. A ladder is no hop: a jump at its foot only bounces off it.
func _climb_step(feet: Vector3, tick: int, command: DotFpsCommand) -> bool:
	var now := float(tick) / 64.0
	if _climb == null:
		if links == null or not _path_has_ladder():
			return false
		for ride in _ladder_rides:
			var from: Vector3 = ride["from"]
			if Vector2(from.x - feet.x, from.z - feet.z).length() < LADDER_REACH and absf(from.y - feet.y) < 1.0 and _path_uses(ride):
				var ladder := links.ladder_of(int(ride["id"]))
				if not ladder.is_empty():
					_climb = DotBotClimb.begin(ladder, now)
					break
		if _climb == null:
			return false
	var r := _climb.step(feet, now)
	if r["done"]:
		_climb = null
		_path_tick = -REPATH_TICKS
		return false
	if not is_nan(float(r["yaw"])):
		command.yaw = float(r["yaw"])
	command.move = r["move"]
	if bool(r["jump"]):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
	_edge = 0
	return true


func _path_has_ladder() -> bool:
	if _hops_for != nav.mesh:
		_index_rides()
	return not _ladder_rides.is_empty()


## Whether the body stands at the start of a hop edge the path crosses: a gap is cleared by jumping off its rim.
func _at_hop(feet: Vector3) -> bool:
	if _hops_for != nav.mesh:
		_index_rides()
	for hop in _hops:
		var from: Vector3 = hop["from"]
		if Vector2(from.x - feet.x, from.z - feet.z).length() < HOP_REACH and absf(from.y - feet.y) < 1.0 and _path_uses(hop):
			return true
	return false


func _index_rides() -> void:
	_hops_for = nav.mesh
	_hops.clear()
	_ladder_rides.clear()
	for ride in nav.rides():
		var id := int(ride["id"])
		if id >= DotBotLinks.LADDER_ID:
			_ladder_rides.append(ride)
		elif id >= DotBotLinks.HOP_ID:
			_hops.append(ride)


func _path_uses(leg: Dictionary) -> bool:
	var to: Vector3 = leg["to"]
	for point in _path:
		if Vector2(point.x - to.x, point.z - to.z).length() < 0.6 and absf(point.y - to.y) < 1.0:
			return true
	return false


## The path to the finish, or while that does not end in it, to the nearest button or trigger that enables a teleport.
func _replan(feet: Vector3) -> void:
	var world: Object = source.get("world") if source != null else null
	if links != null and world != null and links.refresh(nav, world.get("io").get("destinations")) > 0:
		_errand = {}
	if _clock < _wander_until:
		_path = nav.path(feet, _wander)
		return
	_path = nav.path(feet, _goal)
	if links == null or _reaches(_path):
		_errand = {}
		return
	# an errand that cannot be reached (a door in the way) is given up after a while
	_age += 1
	if not _errand.is_empty() and (_age > ERRAND_REPATHS or _stuck >= GIVE_UP_STUCK):
		_stuck = 0
		_done[_errand["index"]] = true
		_errand = {}
	if _errand.is_empty() or _done.has(_errand["index"]):
		_errand = links.next_gadget(nav, feet, _done)
	var end_flat := Vector2(_path[_path.size() - 1].x - feet.x, _path[_path.size() - 1].z - feet.z).length() if not _path.is_empty() else 0.0
	var stalled := end_flat < STALLED
	# at the end of the floor: a teleport not yet taken, nearest first, before any other button
	if _errand.is_empty() and stalled:
		_errand = links.next_teleport(nav, feet, _done)
	# held up by a door nothing walks through, or nothing else left: any button or trigger in reach may be the way on
	if _errand.is_empty() and (_stuck >= 2 or stalled):
		_errand = links.next_gadget(nav, feet, _done, true)
	if _errand.is_empty():
		_age = 0
	else:
		_path = nav.path(feet, _errand["at"])


## A button is used, a trigger already fired by the stand-in walking into it; either way it is not gone to again.
func _arrived() -> void:
	_rebakes.append(_clock + 48)
	_rebakes.append(_clock + 64 * 5)
	_held = 0
	_age = 0
	_stuck = 0
	_done[_errand["index"]] = true
	if _errand["kind"] == "use":
		var world: Object = source.get("world")
		var _result: Variant = world.get("io").call("use", int(_errand["index"]), null)
	elif _errand["kind"] == "shoot":
		var _shot: Variant = source.get("world").get("io").call("hurt", int(_errand["index"]), 1000.0)
	_errand = {}


func _reaches(points: PackedVector3Array) -> bool:
	return not points.is_empty() and _finish.grow(1.0).has_point(points[points.size() - 1])


## At the end of the floor with the finish near and no errand left: walk straight at it. A finish is often a pool or a
## drop below the last ledge, with no floor under it for the mesh to lead to, so the last leg is a step off the edge.
func _dive(feet: Vector3) -> Vector3:
	if not _errand.is_empty() or _path.is_empty():
		return Vector3.INF
	var end := _path[_path.size() - 1]
	if Vector2(end.x - _goal.x, end.z - _goal.z).length() > DIVE_REACH or Vector2(feet.x - end.x, feet.z - end.z).length() > REACHED + 1.0:
		return Vector3.INF
	if Vector2(_goal.x - feet.x, _goal.z - feet.z).length() < 0.5:
		return Vector3.INF
	return Vector3(_goal.x, feet.y, _goal.z)


## A teleport the path crosses may sit a step off the mesh: walk into its box rather than to its edge point.
func _into_teleport(target: Vector3, feet: Vector3) -> Vector3:
	if links == null:
		return target
	if not _errand.is_empty() and _errand["kind"] == "teleport" and Vector2(_errand["at"].x - feet.x, _errand["at"].z - feet.z).length() < 2.0:
		var inside: AABB = _errand["box"]
		return Vector3(inside.get_center().x, feet.y, inside.get_center().z)
	for t in links.teleports:
		var from: Variant = t.get("from")
		if from is Vector3 and (from as Vector3).distance_to(target) > 3.0 \
				and Vector2(from.x - feet.x, from.z - feet.z).length() < 2.0 and t["to"].distance_to(target) < 1.0:
			var box: AABB = t["box"]
			return Vector3(box.get_center().x, feet.y, box.get_center().z)
	return target


func describe() -> Dictionary:
	return {"errand": _errand.get("index", -1), "done": _done.keys(), "later": links.later.size() if links != null else 0,
		"teleports": links.teleports.size() if links != null else 0, "avoided": _avoided, "route": route_done, "route_skipped": route_skipped}


func clear() -> void:
	_done.clear()
	_errand = {}
	nav.clear()
	links = null
	_climb = null
	_joined = false
	source = null
	_path = PackedVector3Array()
	_mark.clear()
	_rebakes.clear()
	_avoided = 0
	_edge = 0
	_wander_until = 0
	_route = []
	_route_at = 0
	_route_since = 0
	route_done = 0
	route_skipped = 0
	_world = null
	_ride = {}
	_ride_ticks = 0


## The first path point not yet reached, Vector3.INF at the end of the path.
func _next_point(feet: Vector3) -> Vector3:
	for i in range(_path.size()):
		var flat := Vector2(_path[i].x - feet.x, _path[i].z - feet.z).length()
		if flat > REACHED or absf(_path[i].y - feet.y) > 1.0:
			return _path[i]
	return Vector3.INF


static func _statics(node: Node, into: Array) -> void:
	if node is StaticBody3D and not node is AnimatableBody3D:
		into.append(node)
	for child in node.get_children():
		_statics(child, into)
