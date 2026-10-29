extends "headless_world_base.gd"

const WoPlayer := preload("../game/wo_player.gd")

## The world, stepping and section helpers of headless_io.


var _sections_entered := 0
var _sections_finished := 0
var _shot_could_hurt := false



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


## Fires `DotMapWorld.shoot` at every shootable thing's middle from outside along each axis. -1: the map has none;
## the entity index of one that answered; -2: it has some and none answered.
func _shoot_something(game: WoGame, world: DotMapWorld) -> int:
	var space := game.stage.get_world_3d().direct_space_state
	var any := false
	for e: DotMapEntity in world.io.entities:
		var node: Node3D = null
		if e is DotMapMoverNode:
			node = (e as DotMapMoverNode).node as Node3D
		elif e is DotMapBreakable:
			node = (e as DotMapBreakable).node as Node3D
		if node == null or not e.key("model").begins_with("*"):
			continue
		var box := AABB()
		var found := false
		for shape: CollisionShape3D in node.find_children("*", "CollisionShape3D", true, false):
			if shape.shape != null:
				var part: AABB = shape.global_transform * shape.shape.get_debug_mesh().get_aabb()
				box = box.merge(part) if found else part
				found = true
		if not found:
			continue
		any = true
		_shot_could_hurt = e is DotMapBreakable and (e as DotMapBreakable).is_breakable() and (e as DotMapBreakable).min_damage <= 10.0
		var centre := box.get_center()
		for axis in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
			var from: Vector3 = centre + (axis as Vector3) * (box.size.length() * 0.5 + 0.3)
			if world.shoot(space, from, centre, 10.0) == e.index:
				return e.index
	return -2 if any else -1


func _centre_of(mover: DotMapMoverNode) -> Vector3:
	for shape: CollisionShape3D in mover.node.find_children("*", "CollisionShape3D", true, false):
		if shape.shape != null:
			return (shape.global_transform * shape.shape.get_debug_mesh().get_aabb()).get_center()
	return (mover.node as Node3D).global_position


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
