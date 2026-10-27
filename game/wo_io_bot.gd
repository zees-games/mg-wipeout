extends RefCounted

## How a stand-in runs a course that is a map's own world (see [WoCourseIo]): there is no route document, so it
## walks a path across dot-bot's navigation mesh, baked from the map's static colliders, to the finish.
##
## The map's teleports join the mesh as edges and its kill volumes are cut out of it ([DotBotLinks]). What the mesh
## still cannot know is the rest of the map's logic: a door a button opens, a mover to ride. Movers are left out of
## the bake (a door baked shut is a doorway never walked to), so where the way on needs one, the path ends at the
## nearest point the floor reaches and the stand-in stops there. [method reaches_finish] says which.

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
## Ticks standing where a button or trigger fires before it counts as fired (a box test is looser than the brush).
const HOLD_TICKS := 24
## Replans (32 ticks each) an errand may take before it is given up.
const ERRAND_REPATHS := 200
## Windows of a second without progress after which an errand is given up.
const GIVE_UP_STUCK := 5

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

var _goal := Vector3.ZERO
var _finish := AABB()
var _path := PackedVector3Array()
var _path_tick := -REPATH_TICKS
var _mark := {}
var _last_feet := Vector3.INF


## Bakes the static (never the moving) colliders of [param world] and aims at [param finish].
func setup(p_source: Object, world: Node3D, finish: AABB, agent: Dictionary, p_links: DotBotLinks) -> void:
	source = p_source
	links = p_links
	links.carve(nav)
	_finish = finish
	_goal = Vector3(finish.get_center().x, finish.position.y + 0.5, finish.get_center().z)
	var bodies: Array = []
	_statics(world, bodies)
	var baked := nav.bake_in_background(world, agent, 0, bodies)
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
	if not is_ready():
		return
	# Moved by the map (a teleport): the path ahead is the one from before it.
	if _last_feet.distance_to(feet) > TELEPORTED:
		_path_tick = -REPATH_TICKS
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

	var target := _into_teleport(_next_point(feet), feet)
	if target == Vector3.INF:
		return

	var toward := target - feet
	toward.y = 0.0
	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	var mark: Dictionary = _mark.get(player_id, {"tick": tick, "at": feet})
	if tick - int(mark["tick"]) >= STUCK_TICKS:
		if grounded and (mark["at"] as Vector3).distance_to(feet) < STUCK_METRES:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			_stuck += 1
		else:
			_stuck = 0
		mark = {"tick": tick, "at": feet}
	_mark[player_id] = mark

	if grounded and target.y - feet.y > JUMP_RISE:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## The path to the finish, or while that does not end in it, to the nearest button or trigger that enables a teleport.
func _replan(feet: Vector3) -> void:
	var world: Object = source.get("world") if source != null else null
	if links != null and world != null and links.refresh(nav, world.get("io").get("destinations")) > 0:
		_errand = {}
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
	_held = 0
	_age = 0
	_stuck = 0
	_done[_errand["index"]] = true
	if _errand["kind"] == "use":
		var world: Object = source.get("world")
		var _result: Variant = world.get("io").call("use", int(_errand["index"]), null)
	_errand = {}


func _reaches(points: PackedVector3Array) -> bool:
	return not points.is_empty() and _finish.grow(1.0).has_point(points[points.size() - 1])


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
		"teleports": links.teleports.size() if links != null else 0}


func clear() -> void:
	_done.clear()
	_errand = {}
	nav.clear()
	links = null
	_joined = false
	source = null
	_path = PackedVector3Array()
	_mark.clear()


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
