extends "wo_course_asks.gd"

const WoCourseDoc := preload("wo_course_doc.gd")
const WoWorld := preload("wo_world.gd")

## A course or arena built from its document: the pieces, where each is at a tick, and the questions movement asks.
## An obstacle is a pure function of the tick, never replicated: a client poses every one at tick N before predicting N.
## Hazards are NOT solid; [method knock] measures them analytically (depenetration is order-dependent across machines).

const CHANNEL := "wo.course"

## dot-lighting's contact shade, loaded by path (API 4): see [method _add_contact_shade].
const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## How far below a start gate goes when it opens.
const GATE_DROP := 80.0

## Emitted when the course has been built and posed once.
signal built()

## A map-state message for one peer, from an io world (see [WoCourseIo]). Server only.
signal io_message(peer: Variant, msg: Dictionary)

## The game's callables for an io world (`damage_fn`, `move_fn`, `event_fn`...), set before [method build].
var io_hooks: Dictionary = {}

## Whether to draw the sky, the sun and the water. A client sets this; a server need not.
@export var draw_world: bool = false

## The start pen's still boxes (pad, side walls, back; never the gate, which drops), for the
## contact shade: `{transform, size}` each, in this node's frame.
var _pen_boxes: Array = []

## The collision layout everything is put on. Set by [WoGame] before [method build].
var physics: DotPhysicsLayout = null

## The normalised document this was built from. See [WoCourseDoc].
var doc: Dictionary = {}

## Whether the start gate stands. [WoGame] closes it for the countdown.
var gate_closed: bool = false:
	set(value):
		gate_closed = value
		_place_gate()

var _ladders: Array[AABB] = []

## A one-life course (`doc["instant"]`): no start pen, the round starts at once. It keeps the finish arch,
## which an imported level's finish box otherwise leaves invisible.
var instant: bool = false

## The round's weather, from `doc["weather"]` (drawn by the server and sent with the course,
## so every machine reads the same gusts and strikes): gusts as {from, to, dir, strength}
## and strikes as {tick, at, radius}, in game ticks. Empty is a calm course.
var gusts: Array[Dictionary] = []
var strikes: Array[Dictionary] = []

var _gate: StaticBody3D = null
var _gate_rest: Transform3D = Transform3D.IDENTITY

## The stage's toys (dot-props' [DotPropToyBox]): loose ones only (beach balls, a finale's balls), simulated where
## [member authoritative] and posed from snapshots elsewhere, under the game's `sv_toys*` [member toy_rules]. A runner
## pushes one through (`WoGame._advance_toys`); a fixed toy would be a way past an obstacle. Set before building.
var toys: DotPropToyBox = null
var authoritative: bool = true
var toy_rules: DotPropToyRules = null
var gravity: float = 20.0

## The kinds a stage here may place: the rigid ones a person pushes and walks through.
const TOY_KINDS: Array[StringName] = [&"ball", &"pin", &"barrel", &"tyre"]


## Builds everything [param p_doc] describes, replacing whatever was here. The old pieces leave the tree now and are
## freed at frame end: a round can change course inside the netcode's tick, and freeing a body there frees something
## [DotNetManager.server_tick] may be walking.
func build(p_doc: Dictionary) -> DotResult:
	clear()

	var checked := WoCourseDoc.validate(p_doc)

	if not checked.ok:
		return checked

	doc = checked.value
	instant = bool(doc.get("instant", false))
	_pen_boxes = []

	_read_weather()

	for index in range((doc["pieces"] as Array).size()):
		_make_piece(index, doc["pieces"][index])

	_read_ladders()

	if is_course():
		_build_start()
		_build_markers()

	if is_arena():
		_build_gallery()

	_build_toys()

	if draw_world:
		_build_world()
		_build_dressing()
		_add_contact_shade()

	if io != null:
		io.index_movers()
		_drain_io_inbox()

	pose_at_time(0.0)
	built.emit()

	DotLog.debug(CHANNEL, "built", {
		"id": id(), "kind": str(doc.get("kind", "")), "pieces": pieces.size(),
		"digest": WoCourseDoc.digest(doc),
	})
	return DotResult.success(self)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	pieces.clear()
	io = null
	_ladders = []
	_by_collider.clear()
	_screens.clear()
	_flags.clear()
	_confetti.clear()
	doc = {}
	_gate = null
	toys = null
	_posed_tick = -2147483648
	_posed_time = -1.0


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


func is_course() -> bool:
	return str(doc.get("kind", "")) == WoCourseDoc.KIND_COURSE


func is_arena() -> bool:
	return str(doc.get("kind", "")) == WoCourseDoc.KIND_ARENA


## Which kinds of piece move, carry a player along, or knock one about.
const PIECES_THAT_MOVE: Array[String] = ["mover", "turntable", "roller", "seesaw", "conveyor", "tiles", "spinner", "pendulum", "pusher", "fall"]
const PIECES_THAT_CARRY: Array[String] = ["mover", "turntable", "roller", "seesaw", "conveyor"]
const PIECES_THAT_HURT: Array[String] = ["spinner", "pendulum", "pusher", "fall"]


func _make_piece(index: int, spec: Dictionary) -> void:
	var kind := str(spec["kind"])
	var role := _role(str(spec.get("role", "deck")))
	var piece := {
		"index": index,
		"kind": kind,
		"spec": spec,
		"node": null,
		"moving": false,
		"carrier": false,
		"hazard": false,
		"bodies": [],
	}

	match kind:
		"box", "bouncer", "teleport":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role)
		"ramp":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], float(spec["pitch"]), role)
		"ball":
			piece["node"] = _static_round(spec, role, true)
		"cylinder":
			piece["node"] = _static_round(spec, role, false)
		"mover", "seesaw":
			piece["node"] = _moving_box(spec["size"], role)
		"turntable":
			piece["node"] = _moving_disc(float(spec["radius"]), float(spec.get("thickness", 0.6)), role)
		"roller":
			piece["node"] = _moving_log(float(spec["length"]), float(spec["radius"]), role)
		"conveyor":
			piece["node"] = _conveyor(spec, role)
		"world":
			if bool(spec.get("io", false)):
				piece["node"] = _make_io_world(spec)
			else:
				piece["node"] = WoWorld.build(spec, physics)
		"ladder":
			var rungs := Node3D.new()
			_not_collided(rungs)
			rungs.transform = Transform3D(Basis.IDENTITY, spec["at"])
			_add_box(rungs, spec["size"], role, false, false)
			piece["node"] = rungs
		"kill":
			var volume := Node3D.new()
			_not_collided(volume)
			volume.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])
			piece["node"] = volume
		"tiles":
			piece["node"] = _tiles(spec, role)
		"spinner":
			piece["node"] = _spinner(spec, role)
		"pendulum":
			piece["node"] = _pendulum(spec, role)
		"pusher":
			piece["node"] = _pusher(spec, role)
		"fall":
			piece["node"] = _fall(spec)

	piece["moving"] = kind in PIECES_THAT_MOVE
	piece["carrier"] = kind in PIECES_THAT_CARRY or (kind == "world" and bool(spec.get("io", false)))
	piece["hazard"] = kind in PIECES_THAT_HURT

	var node: Node3D = piece["node"]

	if node == null:
		return

	node.name = "%s_%d" % [kind, index]
	add_child(node)

	# Every collider in the piece, so a ground id finds its piece in one lookup.
	var bodies: Array = []
	_collect_bodies(node, bodies)

	for sub in range(bodies.size()):
		var body: CollisionObject3D = bodies[sub]
		_by_collider[body.get_instance_id()] = [index, sub]
		_put_on_world_layer(body)

	if io != null and io.world != null and kind == "world":
		io.reseat_brushes()

	piece["bodies"] = bodies
	pieces.append(piece)


## The toys, on their own layer: `toy`, which the course, its machinery, the props and the
## other toys stop and a person never does. A placement of a kind other than [constant TOY_KINDS]
## is left out with a line, never refused: the course still plays.
func _build_toys() -> void:
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.draw = draw_world
	if toy_rules != null:
		toys.rules = toy_rules
	toys.gravity = gravity
	# In the water is lost: home it goes.
	toys.kill_y = water_height() - 1.0
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"world")
		toys.solid_mask = physics.collision_mask(&"world")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"toy")
	add_child(toys)
	var catalogue := DotPropToyCatalogue.stock()
	toys.catalogue = catalogue
	var placements: Array = []
	var refused: PackedStringArray = PackedStringArray()
	for placement: Dictionary in doc.get("toys", []):
		var def := catalogue.get_def(StringName(str(placement.get("toy", ""))))
		if not def.is_empty() and not TOY_KINDS.has(StringName(str(def.get("kind", "")))):
			refused.append(str(placement["toy"]))
			continue
		placements.append(placement)
	if not refused.is_empty():
		DotLog.warn(CHANNEL, "a stage places toys that are not loose; they are left out", {"stage": String(id()), "toys": ", ".join(refused)})
	var built := toys.build(placements)
	if not built.ok:
		DotLog.warn(CHANNEL, "a stage's toys would not build", {"stage": String(id()), "why": built.error.message})


## What a client was told about a map's state: applied at once for this stage, held until this
## end has built it otherwise (a join's snapshot can beat the mesh download).
func io_receive(msg: Dictionary) -> void:
	if io != null and io.world != null and str(msg.get("stage", "")) == String(id()):
		io.apply(msg)
		return

	_io_inbox.append(msg)

	if _io_inbox.size() > 256:
		_io_inbox.pop_front()


func _drain_io_inbox() -> void:
	var waiting := _io_inbox
	_io_inbox = []

	for msg: Dictionary in waiting:
		if str(msg.get("stage", "")) == String(id()):
			io.apply(msg)
		else:
			_io_inbox.append(msg)


var _io_inbox: Array = []


func _make_io_world(spec: Dictionary) -> Node3D:
	io = WoCourseIo.new()
	io.message.connect(func(peer: Variant, msg: Dictionary) -> void: io_message.emit(peer, msg))
	var world := io.build(spec, id(), io_hooks, authoritative, draw_world, tick_rate)

	if world == null:
		io = null

	return world


func _collect_bodies(node: Node, into: Array) -> void:
	if node is CollisionObject3D:
		into.append(node)

	for child in node.get_children():
		_collect_bodies(child, into)


func _put_on_world_layer(body: CollisionObject3D) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, &"world")

	if not applied.ok:
		DotLog.warn(CHANNEL, "a piece could not be put on its collision layer", {
			"why": applied.error.message,
		})


static func _role(name: String) -> WoTextures.Role:
	match name:
		"pillar":
			return WoTextures.Role.PILLAR
		"cannon":
			return WoTextures.Role.CANNON
		"arena":
			return WoTextures.Role.ARENA
		"hazard":
			return WoTextures.Role.HAZARD
		"safe":
			return WoTextures.Role.SAFE
		_:
			return WoTextures.Role.DECK



func _static_box(at: Vector3, size: Vector3, yaw: float, pitch: float, role: WoTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()
	# Pitch about the piece's own X axis, positive raising its far (-Z) end: a ramp a mapper
	# writes as "pitch 15" climbs away from the start the way the course runs.
	body.transform = Transform3D(_yaw_basis(yaw) * Basis(Vector3.RIGHT, deg_to_rad(pitch)), at)
	_add_box(body, size, role, false, true)
	return body


func _static_round(spec: Dictionary, role: WoTextures.Role, sphere: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var mesh := MeshInstance3D.new()
	var shape := CollisionShape3D.new()

	if sphere:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = float(spec["radius"])
		sphere_mesh.height = float(spec["radius"]) * 2.0
		mesh.mesh = sphere_mesh

		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = float(spec["radius"])
		shape.shape = sphere_shape
	else:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = float(spec["radius"])
		cylinder.bottom_radius = float(spec["radius"])
		cylinder.height = float(spec["height"])
		mesh.mesh = cylinder

		var cylinder_shape := CylinderShape3D.new()
		cylinder_shape.radius = float(spec["radius"])
		cylinder_shape.height = float(spec["height"])
		shape.shape = cylinder_shape

	mesh.material_override = WoTextures.surface(role)
	body.add_child(mesh)
	body.add_child(shape)
	return body


func _add_box(parent: Node3D, size: Vector3, role: WoTextures.Role, moving: bool, solid: bool,
		offset: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	mesh.material_override = WoTextures.surface(role, moving)
	parent.add_child(mesh)

	if solid:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		shape.position = offset
		parent.add_child(shape)

	return mesh


## Marks a drawing as meant to be walked through, for dot-core's [DotCollisionAudit]: hazards (measured by [method
## _knock_pusher] and kin, never collided), the water plane and the markers. A SOLID piece is never marked.
static func _not_collided(node: Node) -> void:
	node.set_meta(&"dot_no_collision", true)


## A body the course moves by setting its transform each tick. STATIC, teleported: a kinematic body applies a new
## transform only at its next physics step, so replaying six predicted ticks in one frame swept all six against the
## obstacle where it was. Nothing is pushed by the solver; riding is [method carry]'s arithmetic.
static func _animatable() -> StaticBody3D:
	return StaticBody3D.new()



func _moving_box(size: Vector3, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()
	_add_box(body, size, role, true, true)
	return body


func _moving_disc(radius: float, thickness: float, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()

	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = thickness
	cylinder.radial_segments = 48
	mesh.mesh = cylinder
	mesh.material_override = WoTextures.surface(role, true)
	body.add_child(mesh)

	# Two stripes across the top, because a disc of one colour turning under a grid that is
	# stuck to it still reads as still from most angles; a bar across it does not.
	for turn in range(2):
		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(radius * 1.9, 0.04, 0.5)
		bar.mesh = bar_box
		bar.position = Vector3(0.0, thickness * 0.5 + 0.02, 0.0)
		bar.rotation = Vector3(0.0, PI * 0.5 * turn, 0.0)
		bar.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		body.add_child(bar)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = thickness
	shape.shape = cylinder_shape
	body.add_child(shape)
	return body


func _moving_log(length: float, radius: float, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()

	# Along the body's X axis: a cylinder is built along Y and turned onto X here, inside the
	# body, so the body's own rotation about X is the log rolling.
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 32
	mesh.mesh = cylinder
	mesh.rotation = Vector3(0.0, 0.0, PI * 0.5)
	mesh.material_override = WoTextures.surface(role, true)
	body.add_child(mesh)

	# Bands, for the same reason as the turntable's bars: a smooth log rolling is a log that
	# looks still.
	for band in range(4):
		var ring := MeshInstance3D.new()
		var ring_box := BoxMesh.new()
		ring_box.size = Vector3(length * 0.98, 0.12, radius * 2.04)
		ring.mesh = ring_box
		ring.rotation = Vector3(PI * 0.25 * band, 0.0, 0.0)
		ring.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		ring.scale = Vector3(1.0, 1.0, 0.98)
		body.add_child(ring)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = length
	shape.shape = cylinder_shape
	shape.rotation = Vector3(0.0, 0.0, PI * 0.5)
	body.add_child(shape)
	return body


## A belt: `speed` metres a second along its own -Z (negative runs it back toward the
## start), pitched like a ramp when `pitch` is given, so a belt can lie on a slope.
func _conveyor(spec: Dictionary, role: WoTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(_conveyor_basis(spec), spec["at"])
	var size: Vector3 = spec["size"]
	_add_box(body, size, role, false, true)

	# Slats that run, client side, so the direction of the belt can be read off it. They are
	# moved by [method _pose_piece] and are nothing but meshes.
	var slats := Node3D.new()
	slats.name = "Slats"
	body.add_child(slats)

	var count := maxi(int(size.z / 1.5), 2)

	for i in range(count):
		var slat := MeshInstance3D.new()
		var slat_box := BoxMesh.new()
		slat_box.size = Vector3(size.x * 0.96, 0.05, 0.3)
		slat.mesh = slat_box
		slat.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		slats.add_child(slat)

	return body



func _tiles(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var cols := int(spec["cols"])
	var rows := int(spec["rows"])
	var tile := float(spec["tile"])
	var gap := float(spec.get("gap", 0.25))
	var thickness := float(spec.get("thickness", 0.5))
	var pitch := tile + gap

	for row in range(rows):
		for col in range(cols):
			var body := _animatable()
			body.name = "Tile_%d_%d" % [col, row]
			body.position = Vector3(
				(float(col) - float(cols - 1) * 0.5) * pitch,
				0.0,
				(float(row) - float(rows - 1) * 0.5) * pitch
			)
			body.set_meta(&"rest", body.position)
			_add_box(body, Vector3(tile, thickness, tile), role, true, true)
			root.add_child(body)

	return root


func _spinner(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := StaticBody3D.new()
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var arm_height := float(spec.get("arm_height", 1.0))
	var hub_radius := float(spec.get("hub_radius", 0.6))
	var hub_height := float(spec.get("hub_height", arm_height + 0.6))

	# The hub is solid: it is a post a player has to go round.
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = hub_radius
	cylinder.bottom_radius = hub_radius
	cylinder.height = hub_height
	mesh.mesh = cylinder
	mesh.position = Vector3(0.0, hub_height * 0.5, 0.0)
	mesh.material_override = WoTextures.surface(WoTextures.Role.PILLAR)
	root.add_child(mesh)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = hub_radius
	cylinder_shape.height = hub_height
	shape.shape = cylinder_shape
	shape.position = mesh.position
	root.add_child(shape)

	var arms := Node3D.new()
	arms.name = "Arms"
	_not_collided(arms)
	arms.position = Vector3(0.0, arm_height, 0.0)
	root.add_child(arms)

	var length := float(spec["arm_length"])
	var thickness := float(spec.get("arm_thickness", 0.35))
	var count := maxi(int(spec.get("arms", 1)), 1)

	for arm in range(count):
		var holder := Node3D.new()
		holder.rotation = Vector3(0.0, TAU * float(arm) / float(count), 0.0)
		arms.add_child(holder)

		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(length - hub_radius, thickness, thickness)
		bar.mesh = bar_box
		bar.position = Vector3(hub_radius + (length - hub_radius) * 0.5, 0.0, 0.0)
		bar.material_override = WoTextures.surface(role, true)
		holder.add_child(bar)

		# A soft end, which is what makes an arm read as something that hits rather than
		# something that cuts.
		var tip := MeshInstance3D.new()
		var tip_sphere := SphereMesh.new()
		tip_sphere.radius = thickness * 0.9
		tip_sphere.height = thickness * 1.8
		tip.mesh = tip_sphere
		tip.position = Vector3(length, 0.0, 0.0)
		tip.material_override = WoTextures.surface(role, true)
		holder.add_child(tip)

	return root


func _pendulum(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["pivot"])

	var length := float(spec["length"])
	var radius := float(spec["radius"])
	var swing := float(spec["swing"])

	# The gantry it hangs from, drawn across the swing so a player can see where it reaches.
	var reach := sin(deg_to_rad(minf(absf(swing), 89.0))) * length + radius
	_add_box(root, Vector3(reach * 2.0 + 1.0, 0.35, 0.35), WoTextures.Role.PILLAR, false, false)

	var arm := Node3D.new()
	arm.name = "Arm"
	root.add_child(arm)

	var rod := MeshInstance3D.new()
	var rod_mesh := CylinderMesh.new()
	rod_mesh.top_radius = 0.06
	rod_mesh.bottom_radius = 0.06
	rod_mesh.height = length
	rod.mesh = rod_mesh
	rod.position = Vector3(0.0, -length * 0.5, 0.0)
	rod.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
	arm.add_child(rod)

	var ball := MeshInstance3D.new()
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = radius
	ball_mesh.height = radius * 2.0
	ball.mesh = ball_mesh
	ball.position = Vector3(0.0, -length, 0.0)
	ball.material_override = WoTextures.surface(role, true)
	arm.add_child(ball)

	return root


func _pusher(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	_not_collided(root)
	var ram := Node3D.new()
	ram.name = "Ram"
	root.add_child(ram)
	_add_box(ram, spec["size"], role, true, false)
	return root


## A curtain of water or slime across the way: a sluice on two posts, the sheet, the drips that warn and the splash.
## Meshes only: what counts is [method fall_on] and the volume [method _knock_fall] measures. The posts stand outside
## the curtain's width.
func _fall(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(spec.get("yaw", 0.0))), spec["at"])
	var size: Vector3 = spec["size"]
	var tint: Color = spec.get("tint", FALL_WATER)

	for side in [-1.0, 1.0]:
		_add_box(root, Vector3(0.35, size.y + 1.4, 0.35), WoTextures.Role.PILLAR, false, false,
			Vector3(side * (size.x * 0.5 + 0.45), size.y * 0.5 - 0.5, 0.0))
	var sluice := _add_box(root, Vector3(size.x + 1.2, 0.7, size.z + 0.9), WoTextures.Role.CANNON, false, false,
		Vector3(0.0, size.y + 0.35, 0.0))
	sluice.name = "Sluice"

	var curtain := MeshInstance3D.new()
	curtain.name = "Curtain"
	var sheet := BoxMesh.new()
	sheet.size = Vector3(size.x, size.y, maxf(size.z * 0.6, 0.2))
	curtain.mesh = sheet
	curtain.material_override = _liquid(tint, 0.82)
	curtain.position = Vector3(0.0, size.y * 0.5, 0.0)
	root.add_child(curtain)

	var drips := MeshInstance3D.new()
	drips.name = "Drips"
	var thin := BoxMesh.new()
	thin.size = Vector3(size.x * 0.9, size.y, 0.06)
	drips.mesh = thin
	drips.material_override = _liquid(tint, 0.35)
	drips.position = Vector3(0.0, size.y * 0.5, 0.0)
	drips.visible = false
	root.add_child(drips)

	var splash := MeshInstance3D.new()
	splash.name = "Splash"
	var pool := CylinderMesh.new()
	pool.top_radius = size.x * 0.55
	pool.bottom_radius = size.x * 0.55
	pool.height = 0.06
	splash.mesh = pool
	splash.scale = Vector3(1.0, 1.0, maxf(size.z + 1.2, 1.0) / maxf(size.x * 1.1, 0.1))
	splash.material_override = _liquid(tint.lightened(0.5), 0.5)
	splash.position = Vector3(0.0, 0.05, 0.0)
	root.add_child(splash)
	return root


## The default colour of a fall: water. A mapper's `tint` makes it slime, or paint.
const FALL_WATER := Color(0.55, 0.80, 0.98)

static var _streaks: ImageTexture = null


## A translucent, streaked, flowing surface; the streaks are scrolled by [method _pose_piece].
static func _liquid(tint: Color, alpha: float) -> StandardMaterial3D:
	if _streaks == null:
		var image := Image.create(16, 64, false, Image.FORMAT_RGBA8)
		var rng := RandomNumberGenerator.new()
		rng.seed = 41
		# Streaks down it, some bright and some nearly clear, rippling: what reads as falling
		# water rather than a sheet of tinted glass (the first render).
		for x in range(16):
			var streak := rng.randf_range(0.25, 1.0)
			var bright := 1.0 if rng.randf() < 0.3 else 0.8
			for y in range(64):
				var ripple := 0.7 + 0.3 * sin(float(y) * 0.45 + float(x) * 1.7)
				image.set_pixel(x, y, Color(bright, bright, bright, clampf(streak * ripple, 0.0, 1.0)))
		_streaks = ImageTexture.create_from_image(image)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	material.albedo_texture = _streaks
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.2
	material.emission_enabled = true
	material.emission = tint * 0.25
	material.uv1_scale = Vector3(2.0, 1.0, 1.0)
	return material


## The start pad, and the gate across its front that the countdown holds closed.
func _build_start() -> void:
	var start: Dictionary = doc["start"]
	var at: Vector3 = start["at"]
	var size: Vector2 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))

	# A one-life course has no start zone: its own floor (an imported map's room) is the start.
	# A hand-built one has no floor but the pad, so the pad stays and the pen goes.
	if instant and _has_world_piece():
		return

	var pad := StaticBody3D.new()
	pad.name = "Start"
	pad.transform = Transform3D(basis, at - Vector3(0.0, 0.5, 0.0))
	_add_box(pad, Vector3(size.x, 1.0, size.y), WoTextures.Role.SAFE, false, true)
	add_child(pad)
	# To the walls' outer faces for the shade only: the walls stand 5 cm off the pad's edge, so
	# the pad as built meets no wall and the pen, the view every countdown is spent in, had none.
	_pen_boxes.append({"transform": pad.transform.translated_local(Vector3(0.0, 0.0, 0.175)),
		"size": Vector3(size.x + 0.7, 1.0, size.y + 0.35)})
	_put_on_world_layer(pad)

	if instant:
		return

	# Across the front edge, which is -Z in the pad's own frame: yaw 0 faces -Z, and the
	# course runs the way the players are facing.
	_gate = _animatable()
	_gate.name = "Gate"
	_gate_rest = Transform3D(basis, at + basis * Vector3(0.0, 1.4, -size.y * 0.5 - 0.2))
	_add_box(_gate, Vector3(size.x + 0.4, 2.8, 0.3), WoTextures.Role.CANNON, false, true)
	add_child(_gate)
	_put_on_world_layer(_gate)

	# And walls down both sides and across the back, so the countdown cannot be spent
	# walking off the pad into the water.
	for side in [-1.0, 1.0]:
		var wall := StaticBody3D.new()
		wall.transform = Transform3D(basis, at + basis * Vector3(side * (size.x * 0.5 + 0.2), 0.7, 0.0))
		_add_box(wall, Vector3(0.3, 1.4, size.y), WoTextures.Role.PILLAR, false, true)
		add_child(wall)
		_pen_boxes.append({"transform": wall.transform, "size": Vector3(0.3, 1.4, size.y)})
		_put_on_world_layer(wall)

	var back := StaticBody3D.new()
	back.transform = Transform3D(basis, at + basis * Vector3(0.0, 0.7, size.y * 0.5 + 0.2))
	_add_box(back, Vector3(size.x + 0.7, 1.4, 0.3), WoTextures.Role.PILLAR, false, true)
	add_child(back)
	_pen_boxes.append({"transform": back.transform, "size": Vector3(size.x + 0.7, 1.4, 0.3)})
	_put_on_world_layer(back)

	_place_gate()


func _place_gate() -> void:
	if _gate == null:
		return

	var at := _gate_rest

	if not gate_closed:
		at.origin -= Vector3(0.0, GATE_DROP, 0.0)

	_place(_gate, at)


## Flags at every checkpoint and an arch over the finish. Meshes only: what counts is the
## volume, which [method checkpoint_at] and [method in_finish] measure.
func _build_markers() -> void:
	for index in range((doc["checkpoints"] as Array).size()):
		var checkpoint: Dictionary = doc["checkpoints"][index]
		_arch(checkpoint["at"], checkpoint["size"], float(checkpoint["yaw"]), WoTextures.Role.SAFE, 0.25)

	var finish: Dictionary = doc["finish"]
	_arch(finish["at"], finish["size"], float(finish["yaw"]), WoTextures.Role.CANNON, 0.5, "FinishArch")


## The arch drawn at the finish box, or null before the markers are built.
func finish_arch() -> Node3D:
	return get_node_or_null("FinishArch") as Node3D


## The ladders' boxes in world space, for [DotFpsLadderMode].
func ladder_boxes() -> Array[AABB]:
	if io != null and io.world != null:
		var all: Array[AABB] = _ladders.duplicate()
		all.append_array(io.world.ladder_boxes())
		return all

	return _ladders


func _read_ladders() -> void:
	var out: Array[AABB] = []

	for piece: Dictionary in pieces:
		if str(piece["kind"]) == "ladder":
			var spec: Dictionary = piece["spec"]
			var size: Vector3 = spec["size"]
			out.append(AABB((spec["at"] as Vector3) - size * 0.5, size))

	_ladders = out


func _has_world_piece() -> bool:
	for piece: Dictionary in doc["pieces"]:
		if str(piece.get("kind", "")) == "world":
			return true
	return false


## [param at] held inside the start pen while the gate is shut, else unchanged. Only a body
## already within a metre of the pen is held, so somebody watching from the lounge is not.
func confine_to_start(at: Vector3) -> Vector3:
	if instant or not gate_closed or not is_course():
		return at

	var start: Dictionary = doc["start"]
	var size: Vector2 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))
	var local := basis.inverse() * (at - (start["at"] as Vector3))
	var half := Vector2(size.x * 0.5, size.y * 0.5)

	if absf(local.x) > half.x + 1.0 or absf(local.z) > half.y + 1.0 or absf(local.y) > 6.0:
		return at

	local.x = clampf(local.x, -half.x + 0.3, half.x - 0.3)
	local.z = clampf(local.z, -half.y + 0.3, half.y - 0.3)
	return (start["at"] as Vector3) + basis * local


func _arch(at: Vector3, size: Vector3, yaw: float, role: WoTextures.Role, thickness: float,
		arch_name: String = "Arch") -> void:
	var basis := _yaw_basis(yaw)
	var arch := Node3D.new()
	arch.name = arch_name
	_not_collided(arch)
	arch.transform = Transform3D(basis, at)
	add_child(arch)

	var height := maxf(size.y, 2.5)

	for side in [-1.0, 1.0]:
		_add_box(arch, Vector3(thickness, height, thickness), WoTextures.Role.PILLAR, false, false,
			Vector3(side * size.x * 0.5, height * 0.5 - 0.0, 0.0))

	_add_box(arch, Vector3(size.x + thickness, thickness * 1.6, thickness), role, false, false,
		Vector3(0.0, height, 0.0))


## Where everybody who did not finish watches the final death from: a walled box they cannot
## leave and nobody can reach.
func _build_gallery() -> void:
	var gallery: Dictionary = doc["gallery"]
	var at: Vector3 = gallery["at"]
	var size: Vector2 = gallery["size"]

	var floor_body := StaticBody3D.new()
	floor_body.name = "Gallery"
	floor_body.position = at - Vector3(0.0, 0.5, 0.0)
	_add_box(floor_body, Vector3(size.x, 1.0, size.y), WoTextures.Role.SAFE, false, true)
	add_child(floor_body)
	_put_on_world_layer(floor_body)

	# Glass, in effect: walls tall enough that nobody jumps out, thin enough to watch over
	# from a step back. Drawn low so they do not block the view; the collider is the tall
	# part.
	var walls := [
		[Vector3(0.0, 2.0, -size.y * 0.5), Vector3(size.x, 4.0, 0.2)],
		[Vector3(0.0, 2.0, size.y * 0.5), Vector3(size.x, 4.0, 0.2)],
		[Vector3(-size.x * 0.5, 2.0, 0.0), Vector3(0.2, 4.0, size.y)],
		[Vector3(size.x * 0.5, 2.0, 0.0), Vector3(0.2, 4.0, size.y)],
	]

	for wall: Array in walls:
		var body := StaticBody3D.new()
		body.position = at + (wall[0] as Vector3)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = wall[1]
		shape.shape = box
		body.add_child(shape)
		_add_box(body, Vector3((wall[1] as Vector3).x, 0.9, (wall[1] as Vector3).z),
			WoTextures.Role.PILLAR, false, false, Vector3(0.0, -1.55, 0.0))
		add_child(body)
		_put_on_world_layer(body)


## The sky, the sun and the water. Client side. The light is a dot-lighting document made from the course's theme
## ([method light_document]). Contact shade (API 4, the Compatibility renderer has no AO) only on still boxes, bouncers
## and the start pen: moving pieces would leave it behind. By path, so an older shell draws without it.
func _add_contact_shade() -> void:
	if DotAddonApi.build_level("dot_lighting") < 4 or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var boxes: Array = _pen_boxes.duplicate()
	for piece: Dictionary in pieces:
		var kind := str(piece["kind"])
		if (kind != "box" and kind != "bouncer") or bool(piece["moving"]) or piece["node"] == null:
			continue
		boxes.append({"transform": (piece["node"] as Node3D).transform, "size": (piece["spec"] as Dictionary)["size"]})
	if boxes.is_empty():
		return
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		(shade as Node).name = "ContactShade"
		add_child(shade)
	elif shade is Node:
		(shade as Node).free()


func _build_world() -> void:
	var theme: Dictionary = doc.get("theme", {})

	var lighting := Node3D.new()
	lighting.name = "Lighting"
	add_child(lighting)
	var light := light_document(theme)
	var sun := DotLightRig.apply(lighting, DotLightDocument.from_dictionary(light), light_profile())
	if sun != null:
		sun.shadow_blur = 1.5

	for node in lighting.get_children():
		if node is WorldEnvironment and io != null and io.world != null:
			io.world.light_with((node as WorldEnvironment).environment, [], sun)

		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				# The theme's sky at the zenith (the rig draws it in the ambient colour), and
				# the water's colour under the horizon, where the water plane ends: the sky
				# under it must not be a second, brighter sea.
				material.sky_top_color = theme.get("sky", Color(0.52, 0.72, 0.92))
				material.ground_bottom_color = (theme.get("water", Color(0.16, 0.42, 0.62)) as Color).darkened(0.4)

	# The water: what everybody who falls lands in. A plane, drawn only; the fall is a height
	# comparison in [WoGame], for the reason mg-smash-copter gives — a trigger volume can be
	# stepped over between two ticks by something falling fast enough.
	var water := MeshInstance3D.new()
	water.name = "Water"
	_not_collided(water)
	var plane := PlaneMesh.new()
	# Big, and under the middle of the course: a course is three hundred metres long now, and
	# the overview camera above its far end saw the edge of a 1.6 km sheet as a grey band.
	plane.size = Vector2(4000.0, 4000.0)
	water.mesh = plane
	# Darker than the theme's colour and barely glossy: a glossy plane under a blue sky IS the sky, the horizon
	# vanished and the course read as floating in a blue void.
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = (theme.get("water", Color(0.16, 0.42, 0.62)) as Color).darkened(0.35)
	water_material.roughness = 0.55
	water_material.metallic = 0.0
	water.material_override = water_material
	var middle := bounds().get_center()
	water.position = Vector3(middle.x, water_height() - 0.4, middle.z)
	add_child(water)


# A document's `dressing` (see [WoCourseDoc]) puts stands, banners, light towers, screens and flags beside the course.
# Client side, meshes only. The crowd is three MultiMeshes and one shader that bobs them, jumping on [method cheer].

## How excited the crowd is, 0 (sitting) to 1 (on their feet). Decays to [constant CALM].
var excitement: float = 0.0

const CALM := 0.12

## How fast excitement falls back, per second.
const COOL_PER_SECOND := 0.32

static var _crowd_shader: Shader = null
var _crowd_materials: Array[ShaderMaterial] = []
var _screens: Array[Label3D] = []
var _flags: Array[Node3D] = []
var _confetti: Array[CPUParticles3D] = []

const SHIRTS := [
	Color(0.90, 0.25, 0.22), Color(0.98, 0.70, 0.18), Color(0.25, 0.55, 0.92), Color(0.30, 0.75, 0.42),
	Color(0.95, 0.95, 0.95), Color(0.62, 0.36, 0.82), Color(0.98, 0.45, 0.62), Color(0.18, 0.22, 0.32),
	Color(0.20, 0.78, 0.82), Color(0.96, 0.52, 0.20),
]
const SKINS := [
	Color(0.98, 0.84, 0.70), Color(0.92, 0.72, 0.56), Color(0.78, 0.56, 0.40), Color(0.58, 0.40, 0.28),
	Color(0.40, 0.27, 0.19),
]

const CROWD_SHADER := """
shader_type spatial;
render_mode cull_back, specular_disabled;

uniform float excite = 0.0;
uniform float arms = 0.0;

varying vec3 tint;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831;
	float rate = 5.0 + INSTANCE_CUSTOM.y * 5.0;
	float hop = max(0.0, sin(TIME * rate + phase));
	float bob = hop * (0.015 + 0.26 * excite * (0.5 + INSTANCE_CUSTOM.y));
	if (arms > 0.5) {
		float raise = clamp(excite * 1.7 - INSTANCE_CUSTOM.z, 0.0, 1.0);
		VERTEX.y = -0.25 + (VERTEX.y + 0.25) * raise;
		VERTEX.x *= mix(0.55, 1.0, raise);
	}
	VERTEX.y += bob;
	tint = COLOR.rgb;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.9;
}
"""


## Raises the crowd by [param amount] (0..1). The announcer calls it; it falls back by itself.
func cheer(amount: float) -> void:
	excitement = clampf(maxf(excitement, CALM) + amount, 0.0, 1.0)

	if amount >= 0.6:
		for burst in _confetti:
			if is_instance_valid(burst):
				burst.restart()


## Writes [param text] on every big screen this course has.
func show_on_screens(text: String) -> void:
	for screen in _screens:
		if is_instance_valid(screen):
			screen.text = text


func screen_count() -> int:
	return _screens.size()


func _process(delta: float) -> void:
	if not draw_world:
		return

	excitement = maxf(excitement - COOL_PER_SECOND * delta, CALM)

	for material in _crowd_materials:
		material.set_shader_parameter(&"excite", excitement)

	var t := float(Time.get_ticks_msec()) / 1000.0
	for index in range(_flags.size()):
		var flag := _flags[index]
		if is_instance_valid(flag):
			flag.rotation.y = 0.35 * sin(t * 2.3 + float(index) * 0.9)


func _build_dressing() -> void:
	set_process(true)
	excitement = CALM
	var dressing: Array = doc.get("dressing", [])
	var crowd := {"bodies": [], "seed": 1}

	for item: Dictionary in dressing:
		match str(item["kind"]):
			"stands":
				_stands(item, crowd["bodies"])
			"banner":
				_banner(item)
			"lights":
				_light_tower(item)
			"screen":
				_screen(item)
			"flags":
				_flag_row(item)

	if not (crowd["bodies"] as Array).is_empty():
		_crowd(crowd["bodies"])

	if is_course():
		_finish_confetti()


func _box_at(parent: Node3D, size: Vector3, at: Vector3, colour: Color, glow: float = 0.0) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.8
	if glow > 0.0:
		material.emission_enabled = true
		material.emission = colour
		material.emission_energy_multiplier = glow
	mesh.material_override = material
	parent.add_child(mesh)
	return mesh


## A grandstand: steps rising away from the course from `at` (the middle of its front edge, at
## the height of the first row), `size` = length, height, depth; a back wall with the show's
## colour along it. The people on the steps go into [param bodies] as transforms.
func _stands(item: Dictionary, bodies: Array) -> void:
	var root := Node3D.new()
	root.name = "Stands"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)

	var size: Vector3 = item["size"]
	var rows := clampi(int(size.z / 0.9), 3, 12)
	var depth := size.z / float(rows)
	var rise := size.y / float(rows)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	var tint: Color = item["tint"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(item["seed"]) * 7919 + 17

	for row in range(rows):
		var top := float(row) * rise
		var height := top - bottom
		var step := _box_at(root, Vector3(size.x, height, depth), Vector3(0.0, bottom + height * 0.5, (float(row) + 0.5) * depth),
			Color(0.80, 0.82, 0.88) if row % 2 == 0 else Color(0.70, 0.72, 0.80))
		step.name = "Row%d" % row

		var seat := -size.x * 0.5 + 0.4
		while seat < size.x * 0.5 - 0.3:
			if rng.randf() > 0.12:
				var at := Vector3(seat + rng.randf_range(-0.08, 0.08), top, (float(row) + 0.45) * depth)
				bodies.append({"at": root.transform * at, "basis": root.transform.basis, "rng": rng.randi()})
			seat += 0.62

	var wall_height := size.y + 3.0
	_box_at(root, Vector3(size.x + 0.4, wall_height - bottom, 0.4), Vector3(0.0, (wall_height + bottom) * 0.5, size.z + 0.2), Color(0.30, 0.32, 0.42))
	_box_at(root, Vector3(size.x + 0.5, 1.1, 0.5), Vector3(0.0, wall_height - 0.4, size.z + 0.1), tint, 0.6)
	# A rail along the front, so the first row does not read as standing on the water's edge.
	_box_at(root, Vector3(size.x, 0.9, 0.12), Vector3(0.0, 0.45 - rise * 0.5, 0.05), Color(0.95, 0.95, 0.98))

	if str(item["text"]) != "":
		var words := Label3D.new()
		words.text = str(item["text"])
		words.font_size = 160
		words.pixel_size = 0.006
		words.outline_size = 24
		words.modulate = Color(1.0, 1.0, 1.0)
		words.position = Vector3(0.0, wall_height - 0.4, size.z - 0.2)
		# A Label3D reads from its +Z side, and the crowd (and the course) is on the -Z side.
		words.rotation = Vector3(0.0, PI, 0.0)
		root.add_child(words)


## The people, as three MultiMeshes over every stand on the course.
func _crowd(bodies: Array) -> void:
	if _crowd_shader == null:
		_crowd_shader = Shader.new()
		_crowd_shader.code = CROWD_SHADER

	_crowd_materials.clear()
	var parts := [
		{"name": "Bodies", "mesh": _crowd_box(Vector3(0.44, 0.62, 0.3)), "lift": 0.31, "arms": 0.0, "palette": SHIRTS},
		{"name": "Heads", "mesh": _crowd_head(), "lift": 0.78, "arms": 0.0, "palette": SKINS},
		{"name": "Arms", "mesh": _crowd_box(Vector3(0.62, 0.5, 0.1)), "lift": 0.86, "arms": 1.0, "palette": SKINS},
	]

	for part: Dictionary in parts:
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = true
		multi.use_custom_data = true
		multi.mesh = part["mesh"]
		multi.instance_count = bodies.size()
		var palette: Array = part["palette"]

		for index in range(bodies.size()):
			var body: Dictionary = bodies[index]
			var seed := int(body["rng"])
			var basis: Basis = body["basis"]
			var at: Vector3 = (body["at"] as Vector3) + basis * Vector3(0.0, float(part["lift"]), 0.0)
			multi.set_instance_transform(index, Transform3D(basis, at))
			var shade: Color = palette[(seed >> (3 if palette == SKINS else 0)) % palette.size()]
			multi.set_instance_color(index, shade)
			multi.set_instance_custom_data(index, Color(float(seed % 997) / 997.0, float((seed >> 4) % 89) / 89.0,
				float((seed >> 9) % 71) / 71.0 * 0.9, 0.0))

		var material := ShaderMaterial.new()
		material.shader = _crowd_shader
		material.set_shader_parameter(&"arms", float(part["arms"]))
		material.set_shader_parameter(&"excite", excitement)
		_crowd_materials.append(material)

		var node := MultiMeshInstance3D.new()
		node.name = "Crowd" + str(part["name"])
		node.multimesh = multi
		node.material_override = material
		add_child(node)


static func _crowd_box(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


static func _crowd_head() -> SphereMesh:
	var head := SphereMesh.new()
	head.radius = 0.15
	head.height = 0.3
	head.radial_segments = 8
	head.rings = 4
	return head


## A banner on two poles: the show's colour and a word on both faces.
func _banner(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Banner"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var size: Vector3 = item["size"]
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y

	for side in [-1.0, 1.0]:
		_box_at(root, Vector3(0.3, size.y + 2.0 - bottom, 0.3), Vector3(side * size.x * 0.5, (size.y + 2.0 + bottom) * 0.5, 0.0), Color(0.85, 0.86, 0.9))
	_box_at(root, Vector3(size.x, size.y, 0.2), Vector3(0.0, 2.0 + size.y * 0.5 - 0.5, 0.0), item["tint"], 0.35)

	var text := str(item["text"]) if str(item["text"]) != "" else str(doc.get("name", ""))
	for face in [1.0, -1.0]:
		var words := Label3D.new()
		words.text = text
		words.font_size = 200
		words.pixel_size = clampf(size.y * 0.55 / 200.0, 0.002, 0.05)
		words.outline_size = 28
		words.position = Vector3(0.0, 2.0 + size.y * 0.5 - 0.5, 0.12 * face)
		words.rotation = Vector3(0.0, 0.0 if face > 0.0 else PI, 0.0)
		words.double_sided = false
		root.add_child(words)


## A light tower: a mast and a bank of lamps facing the course (the tower's -Z).
func _light_tower(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Lights"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var height := maxf((item["size"] as Vector3).y, 6.0)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	_box_at(root, Vector3(0.5, height - bottom, 0.5), Vector3(0.0, (height + bottom) * 0.5, 0.0), Color(0.55, 0.57, 0.62))
	_box_at(root, Vector3(3.4, 2.0, 0.5), Vector3(0.0, height + 0.6, 0.0), Color(0.22, 0.24, 0.30))

	for col in range(4):
		for row in range(2):
			_box_at(root, Vector3(0.62, 0.62, 0.1), Vector3(-1.2 + float(col) * 0.8, height + 0.2 + float(row) * 0.8, -0.3),
				Color(1.0, 0.97, 0.86), 3.0)


## A big screen on legs, facing the course: the course's name, and whatever the client puts
## up ([method show_on_screens]: the leaders).
func _screen(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Screen"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var size: Vector3 = item["size"]
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	var lift := 3.0

	for side in [-1.0, 1.0]:
		_box_at(root, Vector3(0.4, lift - bottom, 0.4), Vector3(side * size.x * 0.35, (lift + bottom) * 0.5, 0.3), Color(0.40, 0.42, 0.48))
	_box_at(root, Vector3(size.x + 0.6, size.y + 0.6, 0.5), Vector3(0.0, lift + size.y * 0.5, 0.0), Color(0.12, 0.13, 0.16))
	_box_at(root, Vector3(size.x, size.y, 0.1), Vector3(0.0, lift + size.y * 0.5, -0.27), Color(0.05, 0.10, 0.22), 0.6)
	_box_at(root, Vector3(size.x + 0.6, 0.5, 0.55), Vector3(0.0, lift + size.y + 0.45, 0.0), item["tint"], 0.8)

	var words := Label3D.new()
	words.name = "ScreenText"
	words.text = str(item["text"]) if str(item["text"]) != "" else str(doc.get("name", "")).to_upper()
	words.font_size = 160
	words.pixel_size = clampf(size.y * 0.16 / 160.0, 0.002, 0.05)
	words.outline_size = 12
	words.modulate = Color(1.0, 0.95, 0.70)
	words.position = Vector3(0.0, lift + size.y * 0.5, -0.34)
	words.rotation = Vector3(0.0, PI, 0.0)
	words.width = size.x / words.pixel_size * 0.95
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(words)
	_screens.append(words)


## A row of flags on poles along `size.x`, colours drawn from the seed.
func _flag_row(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Flags"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var length := (item["size"] as Vector3).x
	var count := maxi(int(length / 3.0), 1)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y

	for index in range(count + 1):
		var x := -length * 0.5 + float(index) * length / float(count)
		_box_at(root, Vector3(0.14, 5.0 - bottom, 0.14), Vector3(x, (5.0 + bottom) * 0.5, 0.0), Color(0.92, 0.92, 0.95))
		var flag := Node3D.new()
		flag.position = Vector3(x, 4.4, 0.0)
		root.add_child(flag)
		_box_at(flag, Vector3(0.04, 0.9, 1.4), Vector3(0.0, 0.0, 0.72),
			SHIRTS[(int(item["seed"]) + index) % SHIRTS.size()])
		_flags.append(flag)


## Confetti over the finish arch: one-shot bursts, restarted by a big [method cheer].
func _finish_confetti() -> void:
	var finish: Dictionary = doc["finish"]
	var basis := _yaw_basis(float(finish["yaw"]))
	var size: Vector3 = finish["size"]

	for side in [-1.0, 1.0]:
		var burst := CPUParticles3D.new()
		burst.name = "Confetti"
		burst.emitting = false
		burst.one_shot = true
		burst.amount = 140
		burst.lifetime = 3.2
		burst.explosiveness = 0.85
		burst.direction = Vector3(-side * 0.4, 1.0, 0.0)
		burst.spread = 35.0
		burst.initial_velocity_min = 7.0
		burst.initial_velocity_max = 12.0
		burst.gravity = Vector3(0.0, -4.0, 0.0)
		burst.damping_min = 1.0
		burst.damping_max = 2.5
		burst.angular_velocity_min = -360.0
		burst.angular_velocity_max = 360.0
		burst.scale_amount_min = 0.6
		burst.scale_amount_max = 1.2
		var quad := QuadMesh.new()
		quad.size = Vector2(0.14, 0.09)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		quad.material = material
		burst.mesh = quad
		var colours := Gradient.new()
		colours.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
		colours.colors = PackedColorArray([SHIRTS[0], SHIRTS[1], SHIRTS[2], SHIRTS[3], SHIRTS[6]])
		burst.color_initial_ramp = colours
		burst.transform = Transform3D(basis, (finish["at"] as Vector3) + basis * Vector3(side * size.x * 0.5, maxf(size.y, 2.5), 0.0))
		add_child(burst)
		_confetti.append(burst)


## The dot-lighting document a course's theme describes. The sun is high (a deck is not in its neighbour's shadow) and
## behind the start (the faces a runner runs toward are lit). The ambient is a pale cool grey whatever the theme, as a
## saturated fill turns shaded faces navy. Fog starts at 120 m so nothing a player must react to is hidden.
static func light_document(theme: Dictionary) -> Dictionary:
	var sun: Color = theme.get("sun", Color(1.0, 0.96, 0.88))
	var horizon: Color = theme.get("horizon", Color(0.82, 0.88, 0.94))
	return {
		"sun": {
			"pitch_src": -54.0,
			"yaw_src": 145.0,
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0,
			"spread_degrees": 1.0,
			"ambient_colour": [0.74, 0.78, 0.92],
		},
		"fog": {
			"enabled": true,
			"colour": [horizon.r, horizon.g, horizon.b],
			"start": 6300.0,
			"end": 40000.0,
			"max_density": 0.25,
		},
	}


## What this machine draws of a course's light: dot-lighting's `painted()` profile (API 3), matched to the
## Compatibility renderer, which has no headroom above white. Shadows stay on in the browser, unlike `web()`: a mover's
## shadow on the deck is how a player sees where it is.
static func light_profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	return p


## Reads the weather a server drew into the document. Called by [method build].
func _read_weather() -> void:
	gusts.clear()
	strikes.clear()
	var weather: Variant = doc.get("weather", {})
	if typeof(weather) != TYPE_DICTIONARY:
		return
	for gust in (weather as Dictionary).get("gusts", []):
		if typeof(gust) == TYPE_DICTIONARY:
			gusts.append({
				"from": int(gust.get("from", 0)), "to": int(gust.get("to", 0)),
				"dir": Vector2(float(gust.get("dx", 1.0)), float(gust.get("dz", 0.0))).normalized(),
				"strength": float(gust.get("strength", 0.0)),
			})
	for strike in (weather as Dictionary).get("strikes", []):
		if typeof(strike) == TYPE_DICTIONARY:
			strikes.append({
				"tick": int(strike.get("tick", 0)),
				"at": Vector3(float(strike.get("x", 0.0)), float(strike.get("y", 0.0)), float(strike.get("z", 0.0))),
				"radius": float(strike.get("radius", 3.0)),
			})


## Whether this course has a storm: what a client draws rain for.
func is_stormy() -> bool:
	return not strikes.is_empty()


## The wind at [param tick], as a horizontal acceleration in m/s². A pure function of the
## tick, like every obstacle, so a client predicts a gust exactly as the server pushes it.
## A gust eases in and out over its first and last second.
func wind(tick: int) -> Vector3:
	var out := Vector3.ZERO
	for gust in gusts:
		var from: int = gust["from"]
		var to: int = gust["to"]
		if tick < from or tick >= to:
			continue
		var ease := float(tick_rate)
		var envelope := minf(1.0, minf(float(tick - from) / ease, float(to - tick) / ease))
		var dir: Vector2 = gust["dir"]
		out += Vector3(dir.x, 0.0, dir.y) * float(gust["strength"]) * envelope
	return out


## A strike landing at [param tick] near [param feet]: the throw it gives (outward and up), or
## zero. Exact to the tick, so the knock is predicted like any other.
func strike(feet: Vector3, tick: int) -> Vector3:
	for bolt in strikes:
		if int(bolt["tick"]) != tick:
			continue
		var at: Vector3 = bolt["at"]
		var away := Vector3(feet.x - at.x, 0.0, feet.z - at.z)
		var radius: float = bolt["radius"]
		if away.length() > radius:
			continue
		var push := away.normalized() if away.length() > 0.05 else Vector3(1.0, 0.0, 0.0)
		return push * 9.0 + Vector3(0.0, 8.0, 0.0)
	return Vector3.ZERO


## The strike landing at exactly [param tick], or an empty Dictionary. For drawing it.
func strike_at(tick: int) -> Dictionary:
	for bolt in strikes:
		if int(bolt["tick"]) == tick:
			return bolt
	return {}


## Whether [param feet] are in a `kill` piece: a drowning as the water's, for a pit with a floor.
func in_kill(feet: Vector3) -> bool:
	for piece in pieces:
		if str(piece["kind"]) != "kill":
			continue

		var spec: Dictionary = piece["spec"]
		var size: Vector3 = spec["size"]
		var local := _yaw_basis(float(spec["yaw"])).inverse() * (feet - (spec["at"] as Vector3))

		if absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5 and absf(local.z) <= size.z * 0.5:
			return true

	return false


func water_height() -> float:
	if is_arena():
		return float(doc.get("kill_height", -10.0))

	return float(doc.get("water_height", -8.0))


func checkpoint_count() -> int:
	return (doc.get("checkpoints", []) as Array).size()


## Which checkpoint volume [param feet] is inside, or -1.
func checkpoint_at(feet: Vector3) -> int:
	var probe := feet + Vector3(0.0, 0.9, 0.0)
	var checkpoints: Array = doc.get("checkpoints", [])

	for index in range(checkpoints.size()):
		var checkpoint: Dictionary = checkpoints[index]

		if _inside(probe, checkpoint["at"], checkpoint["size"], float(checkpoint["yaw"])):
			return index

	return -1


func in_finish(feet: Vector3) -> bool:
	if not is_course():
		return false

	var finish: Dictionary = doc["finish"]
	return _inside(feet + Vector3(0.0, 0.9, 0.0), finish["at"], finish["size"], float(finish["yaw"]))


## The finish as a world box, from half a metre below its floor to the top of its volume.
func finish_box() -> AABB:
	var finish: Dictionary = doc["finish"]
	var at: Vector3 = finish["at"]
	var size: Vector3 = finish["size"]
	var turned := int(roundf(float(finish["yaw"]) / 90.0)) % 2 != 0
	var half := Vector3(size.z, size.y, size.x) * 0.5 if turned else size * 0.5
	return AABB(Vector3(at.x - half.x, at.y - 0.5, at.z - half.z), Vector3(half.x * 2.0, size.y + 0.5, half.z * 2.0))


## Whether [param point] is inside a box whose BOTTOM-centre is [param at]. Bottom-centre for a gate, because a mapper
## places a checkpoint on the floor a player crosses it on.
static func _inside(point: Vector3, at: Vector3, size: Vector3, yaw: float) -> bool:
	var local := _yaw_basis(yaw).inverse() * (point - at)
	return absf(local.x) <= size.x * 0.5 and local.y >= -0.5 and local.y <= size.y \
		and absf(local.z) <= size.z * 0.5


## Where somebody restarts from after falling: the checkpoint they last crossed, or the start.
## Returns `[position, yaw]`.
func respawn_point(checkpoint: int, seat: int = 0) -> Array:
	var checkpoints: Array = doc.get("checkpoints", [])

	if checkpoint >= 0 and checkpoint < checkpoints.size():
		var entry: Dictionary = checkpoints[checkpoint]
		var basis := _yaw_basis(float(entry["yaw"]))
		var spread := _spread(seat, (entry["size"] as Vector3).x * 0.6)
		return [(entry["at"] as Vector3) + basis * spread + Vector3(0.0, 0.2, 0.0), float(entry["yaw"])]

	# Full rows, as a joiner gets: a restart that centred its seat on a row of ONE put the
	# fifth faller six metres to the side, off the pad's edge where the run-out is narrower.
	return start_spot(seat, 1000)


## Where seat [param seat] of [param of] stands on the start pad: rows from the front a metre and a half apart, so
## twenty-four is four rows of six on a ten metre pad and nobody is inside anybody.
func start_spot(seat: int, of: int) -> Array:
	var spawns := io_spawns()

	if not spawns.is_empty():
		var spawn: Dictionary = spawns[seat % spawns.size()]
		return [spawn["origin"] + Vector3(0.0, 0.1, 0.0), _yaw_of_spawn(float(spawn["yaw"]))]

	var start: Dictionary = doc.get("start", {})

	if start.is_empty():
		return [Vector3.ZERO, 0.0]

	var size: Vector2 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))
	var per_row := maxi(int((size.x - 1.0) / 1.5), 1)
	var row := seat / per_row
	var column := seat % per_row
	var in_row := mini(per_row, of - row * per_row)
	var x := (float(column) - float(maxi(in_row, 1) - 1) * 0.5) * 1.5
	# Two and a half metres back from the gate for the front row: closer, and the gate is the
	# whole of a first-person view for the countdown.
	var z := -size.y * 0.5 + 2.5 + float(row) * 1.5
	z = minf(z, size.y * 0.5 - 0.8)
	return [(start["at"] as Vector3) + basis * Vector3(x, 0.2, z), float(start["yaw"])]


## The map's own start points (`info_player_*`) when an io world is here, the team's first when
## it has them: dot-map's spawn_points, in metres.
func io_spawns() -> Array:
	if io == null or io.world == null:
		return []

	var all := io.world.spawn_points()
	var out: Array = []

	for spawn: Dictionary in all:
		if str(spawn["classname"]) == "info_player_terrorist":
			out.append(spawn)

	return out if not out.is_empty() else all


## A source yaw (degrees, counter-clockwise from +X) as this game's heading (0 faces -Z, to the left).
static func _yaw_of_spawn(source_yaw: float) -> float:
	return fposmod(source_yaw - 90.0, 360.0)


## Where a finisher waits: the lounge, spread so two people are not put inside each other.
func lounge_spot(seat: int) -> Array:
	var finish: Dictionary = doc.get("finish", {})

	if finish.is_empty():
		return [Vector3.ZERO, 0.0]

	return [(finish["lounge"] as Vector3) + _spread(seat, 3.0) + Vector3(0.0, 0.3, 0.0),
		float(finish["yaw"])]


static func _spread(seat: int, width: float) -> Vector3:
	if seat <= 0:
		return Vector3.ZERO

	# A small spiral, in a fixed order: seat 1 to the right, 2 to the left, then a ring.
	var angle := float(seat) * 2.39996
	var reach := minf(0.9 * sqrt(float(seat)), width * 0.5)
	return Vector3(cos(angle) * reach, 0.0, sin(angle) * reach)


## The route a stand-in follows, as the document gives it.
func route() -> Array:
	return doc.get("route", [])


## The route point after [param index] for somebody on [param branch] of a fork. A fork's branches are laid out one
## after the other, so walking on skips every branch but your own: its own on a branch point, else [param branch].
func route_next(index: int, branch: int = 0) -> int:
	var points := route()
	if index >= 0 and index < points.size() and int((points[index] as Dictionary).get("branch", 0)) != 0:
		branch = int((points[index] as Dictionary)["branch"])
	var next := index + 1
	while next < points.size():
		var on := int((points[next] as Dictionary).get("branch", 0))
		if on == 0 or on == branch:
			return next
		if branch == 0:
			branch = on
			return next
		next += 1
	return next


## The route point before [param index] on the same way through (see [method route_next]).
func route_prev(index: int, branch: int = 0) -> int:
	var points := route()
	if index >= 0 and index < points.size() and int((points[index] as Dictionary).get("branch", 0)) != 0:
		branch = int((points[index] as Dictionary)["branch"])
	var before := index - 1
	while before >= 0:
		var on := int((points[before] as Dictionary).get("branch", 0))
		if on == 0 or on == branch or branch == 0:
			return before
		before -= 1
	return before


## The branches of the fork that starts after route point [param index], as
## `[{branch, risky}]` in the order they are laid out; empty where no fork starts.
func route_branches(index: int) -> Array:
	var points := route()
	var out: Array = []
	if index < 0 or index + 1 >= points.size() or int((points[index] as Dictionary).get("branch", 0)) != 0:
		return out
	var seen := {}
	var next := index + 1
	while next < points.size():
		var point: Dictionary = points[next]
		var on := int(point.get("branch", 0))
		if on == 0:
			break
		if not seen.has(on):
			seen[on] = true
			out.append({"branch": on, "risky": bool(point.get("risky", false))})
		next += 1
	return out


var _progress: PackedFloat32Array = PackedFloat32Array()
var _progress_of: Array = []


## How far along the course each route point is, in metres, a fork counted as long as its shortest branch. What the
## race order reads, so a runner on the long way round is not counted ahead of one who took the short cut.
func route_progress() -> PackedFloat32Array:
	var points := route()
	if is_same(_progress_of, points) and _progress.size() == points.size():
		return _progress
	var out := PackedFloat32Array()
	out.resize(points.size())
	var fork_from := 0
	var index := 0
	while index < points.size():
		var point: Dictionary = points[index]
		if index == 0:
			out[0] = 0.0
			index += 1
			continue
		if int(point.get("branch", 0)) == 0:
			var before: Dictionary = points[index - 1]
			out[index] = out[index - 1] + (before["at"] as Vector3).distance_to(point["at"])
			fork_from = index
			index += 1
			continue
		# A fork from `fork_from` to the next point on branch 0.
		var join := index
		while join < points.size() and int((points[join] as Dictionary).get("branch", 0)) != 0:
			join += 1
		var lengths := {}
		var walked := {}
		for b: Dictionary in route_branches(fork_from):
			var on := int(b["branch"])
			var last: Vector3 = (points[fork_from] as Dictionary)["at"]
			var total := 0.0
			for k in range(index, join):
				if int((points[k] as Dictionary)["branch"]) == on:
					total += last.distance_to((points[k] as Dictionary)["at"])
					walked[k] = total
					last = (points[k] as Dictionary)["at"]
			if join < points.size():
				total += last.distance_to((points[join] as Dictionary)["at"])
			lengths[on] = maxf(total, 0.01)
		var shortest := INF
		for on: int in lengths:
			shortest = minf(shortest, float(lengths[on]))
		for k in range(index, join):
			var on := int((points[k] as Dictionary)["branch"])
			out[k] = out[fork_from] + float(walked.get(k, 0.0)) * shortest / float(lengths.get(on, 1.0))
		if join < points.size():
			out[join] = out[fork_from] + shortest
			fork_from = join
		index = join + 1
	_progress = out
	_progress_of = points
	return out


func spawn_areas() -> Array:
	return doc.get("spawns", [])


func drop_areas() -> Array:
	return doc.get("drops", [])


## A point in the gallery for seat [param seat].
func gallery_spot(seat: int) -> Array:
	var gallery: Dictionary = doc.get("gallery", {})

	if gallery.is_empty():
		return [Vector3(0.0, 50.0, 0.0), 0.0]

	var size: Vector2 = gallery["size"]
	var per_row := maxi(int((size.x - 1.0) / 1.2), 1)
	var x := (float(seat % per_row) - float(per_row - 1) * 0.5) * 1.2
	var z := (float(seat / per_row) - 0.5) * 1.2
	z = clampf(z, -size.y * 0.5 + 0.6, size.y * 0.5 - 0.6)
	return [(gallery["at"] as Vector3) + Vector3(x, 0.2, z), 0.0]


## Roughly where the middle of everything is, and how far it reaches. For an overview camera.
func bounds() -> AABB:
	var box := AABB()
	var first := true

	for piece in pieces:
		var spec: Dictionary = piece["spec"]
		var at: Vector3 = spec.get("at", spec.get("pivot", spec.get("from", Vector3.ZERO)))

		if first:
			box = AABB(at, Vector3.ZERO)
			first = false
		else:
			box = box.expand(at)

		if spec.has("to"):
			box = box.expand(spec["to"])

	return box


func describe() -> Dictionary:
	var hazards := 0
	var carriers := 0

	for piece in pieces:
		if bool(piece["hazard"]):
			hazards += 1
		if bool(piece["carrier"]):
			carriers += 1

	return {
		"id": String(id()),
		"kind": str(doc.get("kind", "-")),
		"name": str(doc.get("name", "-")),
		"pieces": pieces.size(),
		"hazards": hazards,
		"carriers": carriers,
		"checkpoints": checkpoint_count(),
		"gate": "closed" if gate_closed else "open",
		"posed": "%.2f s" % _posed_time,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["course"])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	return lines
