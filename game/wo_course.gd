extends Node3D

const WoCourseDoc := preload("wo_course_doc.gd")
const WoTextures := preload("wo_textures.gd")
const WoWorld := preload("wo_world.gd")

## A course, or an arena, built from its document: the pieces, where each one is at a given
## tick, and the four questions a player's movement asks of them.
##
## [b]An obstacle is a pure function of the tick, and that is the decision this file
## exists for.[/b] mg-smash-copter's platforms are a spring the server integrates and tells
## every client about, because what they do depends on who is standing on them. Nothing here
## does: an arm turns at a speed, a mover slides with a period, a tile drops on a schedule —
## so where any of it is on tick N is a formula both ends evaluate and nobody has to send.
## No obstacle is a replicated entity, no snapshot carries one, and a client predicting its
## own player on tick N poses every obstacle at tick N first, so a jump over a sweeping arm
## lands or fails identically on the client and the server.
##
## [b]Three kinds of piece, by what they do to a player:[/b]
##
## - [b]still[/b] (box, ramp, ball, cylinder): a static collider and nothing else;
## - [b]carriers[/b] (mover, turntable, roller, seesaw, conveyor) and the two specials (tiles,
##   bouncer): solid, and whoever stands on one is moved with it by [method carry] — after
##   the motor has run, because the motor writes an absolute position and anything applied
##   before it is overwritten. That ordering is mg-smash-copter's platform carry, unchanged;
## - [b]hazards[/b] (spinner, pendulum, pusher): NOT solid to a player. They are measured
##   instead ([method knock]), against the player's capsule, every tick. A swept capsule
##   meeting a body that moved into it between two ticks is resolved by depenetration, which
##   is order-dependent and different on two machines; an analytic overlap of two shapes is
##   the same arithmetic everywhere, and it is what lets the knock be predicted.
##
## [b]Built the same on a server and a client.[/b] The meshes cost a server nothing it
## renders; [member draw_world] adds the sky, the sun and the water, which only a client sees.

const CHANNEL := "wo.course"

## dot-lighting's contact shade, loaded by path (API 4): see [method _add_contact_shade].
const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## The capsule a player is measured as, in metres. Matches [WoPlayer]'s tunables.
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 1.8
const PLAYER_CROUCHED := 0.9

## How far a dropped tile goes, in metres. Out of the way, and back on the same schedule.
const TILE_DROP := 60.0

## Seconds before a tile drops that it shakes and changes colour. See [method tile_warning].
const TILE_WARN_SECONDS := 0.6

## Seconds either side of a stand-in's time on a tile that the tile must be up too
## ([method tile_crossing_clear]): a run is not quite the model's.
const TILE_MARGIN_SECONDS := 0.08

## The slowest share of the given speeds a stand-in crossing tiles is reckoned to go at.
const TILE_SLOW := 0.9

## How far below a start gate goes when it opens.
const GATE_DROP := 80.0

## Emitted when the course has been built and posed once.
signal built()

## Whether to draw the sky, the sun and the water. A client sets this; a server need not.
@export var draw_world: bool = false

## The start pen's still boxes (pad, side walls, back; never the gate, which drops), for the
## contact shade: `{transform, size}` each, in this node's frame.
var _pen_boxes: Array = []

## The collision layout everything is put on. Set by [WoGame] before [method build].
var physics: DotPhysicsLayout = null

## The normalised document this was built from. See [WoCourseDoc].
var doc: Dictionary = {}

## Ticks a second, for turning a tick into the time every formula is written in.
var tick_rate: int = 64

## Whether the start gate stands. [WoGame] closes it for the countdown.
var gate_closed: bool = false:
	set(value):
		gate_closed = value
		_place_gate()

## One per piece, in document order. See [method _make_piece].
var pieces: Array[Dictionary] = []

## The round's weather, from `doc["weather"]` (drawn by the server and sent with the course,
## so every machine reads the same gusts and strikes): gusts as {from, to, dir, strength}
## and strikes as {tick, at, radius}, in game ticks. Empty is a calm course.
var gusts: Array[Dictionary] = []
var strikes: Array[Dictionary] = []

## Collider instance id -> [code][piece index, sub-index][/code], for the carry and the bounce.
var _by_collider: Dictionary = {}

## "piece/col" to whether that column of tiles can be crossed at all. See [method tile_column_crossable].
var _crossable: Dictionary = {}

## The tick the moving pieces were last posed at, so a second call for the same tick is free.
var _posed_tick: int = -2147483648
var _posed_time: float = -1.0

var _gate: StaticBody3D = null
var _gate_rest: Transform3D = Transform3D.IDENTITY

## The stage's toys (dot-props' [DotPropToyBox]): loose ones only, beach balls in the start pen
## and balls in a finale's arena, simulated where [member authoritative] and posed from snapshots
## elsewhere, under the game's `sv_toys*` [member toy_rules]. A runner walks through one and
## pushes it (`WoGame._advance_toys`), so it never holds anybody up or covers anybody; a fixed toy
## (a pad, a trampoline) would be a way past an obstacle, and is left out. Set by the game
## before it builds.
var toys: DotPropToyBox = null
var authoritative: bool = true
var toy_rules: DotPropToyRules = null
var gravity: float = 20.0

## The kinds a stage here may place: the rigid ones a person pushes and walks through.
const TOY_KINDS: Array[StringName] = [&"ball", &"pin", &"barrel", &"tyre"]


# --- Building ---------------------------------------------------------------

## Builds everything [param p_doc] describes, replacing whatever was here.
##
## [b]The old pieces are taken out of the tree now and freed at the end of the frame.[/b]
## A round can change course inside the netcode's own tick, and freeing a body there frees
## something [DotNetManager.server_tick] may still be walking — mg-smash-copter's
## `ScPlatforms.clear` is the same two lines for the same reason.
func build(p_doc: Dictionary) -> DotResult:
	clear()

	var checked := WoCourseDoc.validate(p_doc)

	if not checked.ok:
		return checked

	doc = checked.value
	_pen_boxes = []

	_read_weather()

	for index in range((doc["pieces"] as Array).size()):
		_make_piece(index, doc["pieces"][index])

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
		"box":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role)
		"ramp":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], float(spec["pitch"]), role)
		"ball":
			piece["node"] = _static_round(spec, role, true)
		"cylinder":
			piece["node"] = _static_round(spec, role, false)
		"mover":
			piece["node"] = _moving_box(spec["size"], role)
			piece["moving"] = true
			piece["carrier"] = true
		"turntable":
			piece["node"] = _moving_disc(float(spec["radius"]), float(spec.get("thickness", 0.6)), role)
			piece["moving"] = true
			piece["carrier"] = true
		"roller":
			piece["node"] = _moving_log(float(spec["length"]), float(spec["radius"]), role)
			piece["moving"] = true
			piece["carrier"] = true
		"seesaw":
			piece["node"] = _moving_box(spec["size"], role)
			piece["moving"] = true
			piece["carrier"] = true
		"conveyor":
			piece["node"] = _conveyor(spec, role)
			piece["moving"] = true
			piece["carrier"] = true
		"world":
			piece["node"] = WoWorld.build(spec, physics)
		"kill":
			var volume := Node3D.new()
			_not_collided(volume)
			volume.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])
			piece["node"] = volume
		"bouncer", "teleport":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role)
		"tiles":
			piece["node"] = _tiles(spec, role)
			piece["moving"] = true
		"spinner":
			piece["node"] = _spinner(spec, role)
			piece["moving"] = true
			piece["hazard"] = true
		"pendulum":
			piece["node"] = _pendulum(spec, role)
			piece["moving"] = true
			piece["hazard"] = true
		"pusher":
			piece["node"] = _pusher(spec, role)
			piece["moving"] = true
			piece["hazard"] = true
		"fall":
			piece["node"] = _fall(spec)
			piece["moving"] = true
			piece["hazard"] = true

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


static func _yaw_basis(yaw_degrees: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_degrees))


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


## Marks a drawing as meant to be walked through, for dot-core's [DotCollisionAudit]. Used for
## the hazards (a spinner's arms, a pendulum, a pusher's ram, a curtain of water: measured by
## [method _knock_pusher] and its kin, never collided, so a runner is knocked rather than
## stopped), the water plane (a fall is a height comparison) and the markers (an arch is a
## volume [method checkpoint_at] measures). A SOLID piece is never marked: it has a shape.
static func _not_collided(node: Node) -> void:
	node.set_meta(&"dot_no_collision", true)


## A body the course moves by setting its transform each tick.
##
## [b]A STATIC body, teleported, and a kinematic one is wrong here in a way only a test with
## no physics frames between ticks shows.[/b] Godot's physics server applies a new transform
## to a KINEMATIC body (which is what an `AnimatableBody3D` is) only at its next step — the
## first one lands at once, every later one waits. So a client replaying six predicted ticks
## inside one frame swept all six against the obstacle where it was a frame ago, and the
## course suite, which drives ticks without frames, found the turntables and the rollers
## still standing at the origin where they were built, eighty metres from where their
## documents put them. A static body's transform is applied the moment it is set. Nothing is
## lost: nothing here is pushed by the solver (props excepted, and a prop knocked by a moving
## floor is cosmetic), and riding is [method carry]'s arithmetic, not a body velocity.
static func _animatable() -> StaticBody3D:
	return StaticBody3D.new()


## Puts [param body] at [param at] in the node AND in the physics server, now.
##
## [b]Both, and the node alone is a tick late.[/b] A node's new transform reaches the physics
## server through the scene tree's transform notifications, which are flushed at the next
## frame boundary — so a client replaying past ticks would sweep every one of them against
## obstacles where they were a frame ago. With [method _animatable]'s static bodies the
## server applies it at once.
static func _place(body: Node3D, at: Transform3D) -> void:
	body.transform = at

	if body is CollisionObject3D and body.is_inside_tree():
		PhysicsServer3D.body_set_state(
			(body as CollisionObject3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			body.global_transform
		)


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


static func _conveyor_basis(spec: Dictionary) -> Basis:
	return _yaw_basis(float(spec.get("yaw", 0.0))) * Basis(Vector3.RIGHT, deg_to_rad(float(spec.get("pitch", 0.0))))


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


## A curtain of water or slime across the way: a sluice on two posts, the sheet that falls
## from it, the drips that warn it is coming, and the splash where it lands. Meshes only: what
## counts is [method fall_on] and the volume [method _knock_fall] measures. The posts stand
## outside the curtain's width, so they are never in a runner's way.
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

## Seconds a curtain takes to reach the deck once it starts, and to clear once it stops.
## Drawing only: the knock is on for exactly `duty` of the period.
const FALL_SHEET_SECONDS := 0.3

## Seconds of drips before a curtain comes down: its tell, like a tile's red.
const FALL_WARN_SECONDS := 0.7

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
	_arch(finish["at"], finish["size"], float(finish["yaw"]), WoTextures.Role.CANNON, 0.5)


func _arch(at: Vector3, size: Vector3, yaw: float, role: WoTextures.Role, thickness: float) -> void:
	var basis := _yaw_basis(yaw)
	var arch := Node3D.new()
	arch.name = "Arch"
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


## The sky, the sun and the water. Client side.
##
## [b]The light is a dot-lighting document made from the course's theme[/b]
## ([method light_document]), so the family's look (game-arena's built-in maps: a warm sun
## with soft shadows, a pale cool fill, filmic tone map, glow) and each course's own sky,
## horizon, sun colour and water are one thing rather than two that can disagree.
## dot-lighting's contact shade (API 4) where the course's still boxes meet: a wall on a deck, a
## block on a platform, a bouncer on the floor. The Compatibility renderer the client draws has
## no ambient occlusion, and every wall stood on its deck with no shade at its foot. Only the
## still `box` and `bouncer` pieces and the start pen's pad and walls: everything else either moves (movers, seesaws, rollers,
## conveyors, tiles, spinners, pendulums, pushers, a falling floor) and the shade is one mesh
## built here, so it would stay where they were; or is tilted (a ramp), whose creases the helper
## does not follow; or is round; the pen's gate drops. By path, behind the level, so a shell older than the helper
## draws the course without it.
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
	# Darker than the theme's colour and barely glossy. The first render had it at 0.18
	# roughness, and a glossy plane under a blue sky IS the sky: the horizon vanished and a
	# course read as floating in a blue void, which is the one thing the water is there to
	# say otherwise.
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = (theme.get("water", Color(0.16, 0.42, 0.62)) as Color).darkened(0.35)
	water_material.roughness = 0.55
	water_material.metallic = 0.0
	water.material_override = water_material
	var middle := bounds().get_center()
	water.position = Vector3(middle.x, water_height() - 0.4, middle.z)
	add_child(water)


# --- The show ----------------------------------------------------------------
#
# [b]A course is a televised event, and the first play test had nothing round it but sea.[/b]
# A document's `dressing` (see [WoCourseDoc]) puts stands full of people beside it, banners,
# light towers, big screens and flags; every finish arch gets confetti. Client side and
# meshes only: nothing collides, nothing is simulated, a server never builds it. The crowd is
# three MultiMeshes (bodies, heads, arms) and one shader that makes them bob, and jump with
# their arms up when [method cheer] raises [member excitement]; thousands of people are three
# draw calls.

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


## The dot-lighting document a course's theme describes.
##
## The angles are dot-lighting's source convention (a negative pitch is a sun in the sky),
## high so a deck is not in its neighbour's shadow, and behind the start, so the faces a
## runner runs toward are the lit ones: from the other side the start gate's orange and
## every obstacle's front came out a shaded brown. The brightness is divided by the
## profile's reference and square-rooted. The ambient is the light in the shade, a pale
## cool grey whatever the theme: a saturated blue fill turns every shaded face navy. The
## fog is the theme's horizon from 120 m out (source units, metres / 0.01905), so nothing a
## player has to react to is hidden in it.
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


## What this machine draws of a course's light: dot-lighting's `painted()`.
##
## [b]Shadows stay on in the browser[/b], unlike dot-lighting's `web()`: a course is a few
## hundred boxes, and a mover's shadow on the deck is how a player sees where it is.
## `painted()` is the family's profile for flat-painted worlds (dot-lighting API 3), matched
## to the renderer: the Compatibility renderer, which this game and the client shell use,
## has no headroom above white, and at Forward+'s numbers every deck clipped to white and the
## grid, which is how far a jump is, was gone (mg-smash-copter found it first). Over the
## hand-set numbers it replaced (the sun divided by 700, a fill of 0.62) it lowers the
## exposure, grades, and adds a shadowless fill so an obstacle's shaded faces keep edges.
static func light_profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	return p


# --- Where everything is ------------------------------------------------------

## Poses every moving piece at [param tick]. Idempotent per tick.
func pose_at(tick: int) -> void:
	if tick == _posed_tick:
		return

	pose_at_time(float(tick) / float(maxi(tick_rate, 1)))
	_posed_tick = tick


## Poses every moving piece at [param seconds]. What a client draws between two ticks.
##
## [b]Forgets which tick it was posed at.[/b] A frame posed between ticks N and N+1 has moved
## every collider off tick N, so the next [method pose_at] for N must not take the shortcut —
## or a client's prediction sweeps tick N against tick N-and-a-half.
func pose_at_time(seconds: float) -> void:
	_posed_time = seconds
	_posed_tick = -2147483648

	for piece in pieces:
		if bool(piece["moving"]):
			_pose_piece(piece, seconds)


func _pose_piece(piece: Dictionary, t: float) -> void:
	var node: Node3D = piece["node"]
	var spec: Dictionary = piece["spec"]

	if node == null or not is_instance_valid(node):
		return

	match str(piece["kind"]):
		"mover", "turntable", "roller", "seesaw":
			# Local, and that is world: a course is built at the origin of its world and never
			# moved, which [WoGame] keeps true.
			_place(node, transform_of(piece, t))
		"conveyor":
			var slats := node.get_node_or_null(^"Slats") as Node3D

			if slats != null:
				var size: Vector3 = spec["size"]
				var count := slats.get_child_count()
				var spacing := size.z / float(maxi(count, 1))
				var run := fposmod(float(spec["speed"]) * t, spacing)

				for i in range(count):
					var slat := slats.get_child(i) as Node3D
					var z := fposmod(-size.z * 0.5 + float(i) * spacing - run + size.z * 0.5, size.z) \
						- size.z * 0.5
					slat.position = Vector3(0.0, size.y * 0.5 + 0.03, z)
		"tiles":
			var index := 0

			for child in node.get_children():
				var tile := child as Node3D

				if tile == null:
					continue

				var rest: Vector3 = tile.get_meta(&"rest", Vector3.ZERO)
				_place(tile, Transform3D(tile.transform.basis,
					rest - Vector3(0.0, TILE_DROP if tile_down(piece, index, t) else 0.0, 0.0)))
				_warn_tile(tile, tile_warning(spec, index, t), t)
				index += 1
		"spinner":
			var arms := node.get_node_or_null(^"Arms") as Node3D

			if arms != null:
				arms.rotation = Vector3(0.0, spinner_angle(spec, t), 0.0)
		"pendulum":
			var arm := node.get_node_or_null(^"Arm") as Node3D

			if arm != null:
				arm.rotation = Vector3(0.0, 0.0, pendulum_angle(spec, t))
		"pusher":
			var ram := node.get_node_or_null(^"Ram") as Node3D

			if ram != null:
				ram.transform = pusher_transform(spec, t)
		"fall":
			_pose_fall(node, spec, t)


## Whether a fall is coming down at [param t]: for `duty` of every `period`, from `phase`.
static func fall_on(spec: Dictionary, t: float) -> bool:
	return fall_cycle(spec, t) < clampf(float(spec.get("duty", 0.4)), 0.05, 0.95)


static func fall_cycle(spec: Dictionary, t: float) -> float:
	return fposmod(t / float(spec["period"]) + float(spec.get("phase", 0.0)), 1.0)


## How close a fall is to coming down, 0 (not soon) to 1 (now). See [constant FALL_WARN_SECONDS].
static func fall_warning(spec: Dictionary, t: float) -> float:
	if fall_on(spec, t):
		return 0.0
	var period := float(spec["period"])
	var left := (1.0 - fall_cycle(spec, t)) * period
	return clampf(1.0 - left / FALL_WARN_SECONDS, 0.0, 1.0) if left < FALL_WARN_SECONDS else 0.0


## The part of the curtain drawn at [param t], as [code][bottom, top][/code] fractions of its
## height: falling from the sluice as it starts, the top clearing first as it stops.
static func fall_sheet(spec: Dictionary, t: float) -> Vector2:
	var period := float(spec["period"])
	var duty := clampf(float(spec.get("duty", 0.4)), 0.05, 0.95)
	var u := fall_cycle(spec, t)

	if u < duty:
		return Vector2(1.0 - clampf(u * period / FALL_SHEET_SECONDS, 0.0, 1.0), 1.0)

	var gone := clampf((u - duty) * period / FALL_SHEET_SECONDS, 0.0, 1.0)
	return Vector2(0.0, 1.0 - gone) if gone < 1.0 else Vector2(0.0, 0.0)


func _pose_fall(node: Node3D, spec: Dictionary, t: float) -> void:
	var size: Vector3 = spec["size"]
	var sheet := fall_sheet(spec, t)
	var curtain := node.get_node_or_null(^"Curtain") as MeshInstance3D
	var drips := node.get_node_or_null(^"Drips") as MeshInstance3D
	var splash := node.get_node_or_null(^"Splash") as MeshInstance3D
	var shown := sheet.y - sheet.x

	if curtain != null:
		curtain.visible = shown > 0.01
		if curtain.visible:
			curtain.scale = Vector3(1.0, shown, 1.0)
			curtain.position = Vector3(0.0, size.y * (sheet.x + sheet.y) * 0.5, 0.0)
			var material := curtain.material_override as StandardMaterial3D
			if material != null:
				material.uv1_offset = Vector3(0.0, fposmod(-t * 2.4, 1.0), 0.0)

	if drips != null:
		var warning := fall_warning(spec, t)
		drips.visible = warning > 0.0
		if drips.visible:
			var material := drips.material_override as StandardMaterial3D
			if material != null:
				material.uv1_offset = Vector3(0.0, fposmod(-t * 1.6, 1.0), 0.0)
				material.albedo_color.a = 0.15 + 0.35 * warning

	if splash != null:
		splash.visible = sheet.x < 0.05 and shown > 0.01


## Where a carrier is at [param t], as a world transform. The one formula per kind.
func transform_of(piece: Dictionary, t: float) -> Transform3D:
	var spec: Dictionary = piece["spec"]
	var yaw := _yaw_basis(float(spec.get("yaw", 0.0)))

	match str(piece["kind"]):
		"mover":
			var from: Vector3 = spec["from"]
			var to: Vector3 = spec["to"]
			return Transform3D(yaw, from.lerp(to, mover_fraction(spec, t)))
		"turntable":
			var angle := deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)
			return Transform3D(yaw * Basis(Vector3.UP, angle), spec["at"])
		"roller":
			var angle := deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)
			return Transform3D(yaw * Basis(Vector3.RIGHT, angle), spec["at"])
		"seesaw":
			return Transform3D(yaw * Basis(Vector3.RIGHT, seesaw_angle(spec, t)), spec["at"])
		_:
			return (piece["node"] as Node3D).transform


## How far along its track a mover is, 0 at `from` and 1 at `to`. Eased at both ends, so a
## player riding one is not thrown off by a reversal at full speed.
static func mover_fraction(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return 0.5 - 0.5 * cos(TAU * cycle)


static func seesaw_angle(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return deg_to_rad(float(spec["amplitude"])) * sin(TAU * cycle)


static func spinner_angle(spec: Dictionary, t: float) -> float:
	return deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)


static func pendulum_angle(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return deg_to_rad(float(spec["swing"])) * sin(TAU * cycle)


## How far out a pusher's ram is, 0 at rest and 1 at full reach.
##
## [b]Fast out, a hold, slower back, and a rest — and the rest is the part a player uses.[/b]
## A ram that went in and out on a sine would be a hazard with no gap to time; this one is
## home for the part of its period after `duty` plus its return, which is the window a player
## runs through.
static func pusher_extension(spec: Dictionary, t: float) -> float:
	var u := fposmod(t / float(spec["period"]) + float(spec.get("phase", 0.0)), 1.0)
	var duty := clampf(float(spec.get("duty", 0.35)), 0.1, 0.8)
	var out_time := 0.08

	if u < out_time:
		return smoothstep(0.0, 1.0, u / out_time)

	if u < duty:
		return 1.0

	var back := minf(0.2, 1.0 - duty)

	if u < duty + back:
		return 1.0 - smoothstep(0.0, 1.0, (u - duty) / back)

	return 0.0


## The ram's transform at [param t], in the course's frame. The ram travels along its own
## -Z, which is the way `yaw` faces.
static func pusher_transform(spec: Dictionary, t: float) -> Transform3D:
	var basis := _yaw_basis(float(spec.get("yaw", 0.0)))
	var out := pusher_extension(spec, t) * float(spec["reach"])
	return Transform3D(basis, (spec["at"] as Vector3) + basis * Vector3(0.0, 0.0, -out))


## Whether tile [param index] of a tiles piece is gone at [param t].
##
## Each tile has its own offset into the cycle, drawn from the piece's seed by a hash rather
## than a random stream, so it is the same on every machine and does not depend on how many
## times anything else has drawn.
static func tile_down(piece: Dictionary, index: int, t: float) -> bool:
	return tile_cycle(piece["spec"], index, t) < float((piece["spec"] as Dictionary)["down"])


## Where tile [param index] is in its cycle, 0..1. It drops at 0 and comes back at `down`.
static func tile_cycle(spec: Dictionary, index: int, t: float) -> float:
	var seed := int(spec.get("seed", 1))
	var offset := float(_mix(seed * 7919 + index * 104729) % 1000) / 1000.0
	return fposmod(t / float(spec["period"]) + offset, 1.0)


## How close tile [param index] is to dropping, 0 (not soon) to 1 (now).
##
## [b]A tile that drops with no tell is a coin toss, not an obstacle.[/b] The schedule is a
## hash of the tile's index, which nobody can read off a floor; what a player CAN read is a
## tile shaking and turning the hazard colour for the last [constant TILE_WARN_SECONDS]
## before it goes. A function of the tick like everything else here, so every client shows
## the same warning at the same moment without being told.
static func tile_warning(spec: Dictionary, index: int, t: float) -> float:
	var period := float(spec["period"])
	var warn := clampf(TILE_WARN_SECONDS / period, 0.0, 0.5)
	var cycle := tile_cycle(spec, index, t)

	if cycle < float(spec["down"]) or cycle < 1.0 - warn:
		return 0.0

	return (cycle - (1.0 - warn)) / maxf(warn, 0.0001)


## The tell, on the MESH only: the collider stays put, so a warned tile is still exactly as
## solid as it was and nobody is shaken off it by the warning itself.
func _warn_tile(tile: Node3D, warning: float, t: float) -> void:
	var mesh: MeshInstance3D = null

	for child in tile.get_children():
		if child is MeshInstance3D:
			mesh = child
			break

	if mesh == null:
		return

	if warning <= 0.0:
		mesh.position = Vector3.ZERO
		if mesh.get_meta(&"warned", false):
			mesh.material_override = mesh.get_meta(&"rest_material")
			mesh.set_meta(&"warned", false)
		return

	var shake := 0.04 + 0.06 * warning
	mesh.position = Vector3(sin(t * 61.0) * shake, 0.0, cos(t * 53.0) * shake)

	if not mesh.get_meta(&"warned", false):
		mesh.set_meta(&"rest_material", mesh.material_override)
		mesh.material_override = WoTextures.surface(WoTextures.Role.HAZARD, true)
		mesh.set_meta(&"warned", true)


static func _mix(value: int) -> int:
	# A small integer hash, the same on every platform: no `hash()`, whose output on a
	# built-in is not promised to be stable across engine versions.
	var x := (value ^ 0x5bd1e995) & 0x7fffffff
	x = ((x >> 15) ^ x) * 0x2c1b3c6d & 0x7fffffff
	x = ((x >> 12) ^ x) * 0x297a2d39 & 0x7fffffff
	return ((x >> 15) ^ x) & 0x7fffffff


# --- What a player's movement asks ----------------------------------------------

## How far whatever [param ground_id] is moves a point at [param at] between [param tick]
## and the next one. Zero for anything that is not a carrier.
##
## [b]The exact displacement, not a velocity times a step.[/b] A point on a turntable moves
## along an arc; a velocity taken at the start of the tick moves it along the tangent, which
## is outward by a little every tick, and a player standing still on a turntable spirals off
## it. `pose(t + dt) * pose(t)⁻¹` applied to the point is the arc.
func carry(ground_id: int, at: Vector3, tick: int) -> Vector3:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return Vector3.ZERO

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if not bool(piece["carrier"]):
		return Vector3.ZERO

	var dt := 1.0 / float(maxi(tick_rate, 1))
	var t := float(tick) * dt

	if str(piece["kind"]) == "conveyor":
		var spec: Dictionary = piece["spec"]
		return _conveyor_basis(spec) * Vector3(0.0, 0.0, -float(spec["speed"]) * dt)

	var now := transform_of(piece, t)
	var next := transform_of(piece, t + dt)
	return (next * now.affine_inverse()) * at - at


## Whether whatever [param ground_id] is moves whoever stands on it.
func carries(ground_id: int) -> bool:
	var found: Variant = _by_collider.get(ground_id)
	return found != null and bool(pieces[int((found as Array)[0])]["carrier"])


## The kind of piece [param ground_id] belongs to (`turntable`, `seesaw`, `box`…), or "".
func ground_kind(ground_id: int) -> String:
	var found: Variant = _by_collider.get(ground_id)
	return str(pieces[int((found as Array)[0])]["kind"]) if found != null else ""


## Where a teleport pad under [param feet] sends whoever stands on it, as `[position, heading]`,
## or an empty array when they are on none. Feet within the pad's footprint and between a
## little under its top and a metre over it: a runner jumping across the pad's corner is
## still sent, one a long way under it (falling past) is not.
func teleport_at(feet: Vector3) -> Array:
	for piece in pieces:
		if str(piece["kind"]) != "teleport":
			continue

		var spec: Dictionary = piece["spec"]
		var size: Vector3 = spec["size"]
		var local := _yaw_basis(float(spec["yaw"])).inverse() * (feet - (spec["at"] as Vector3))

		if absf(local.x) <= size.x * 0.5 and absf(local.z) <= size.z * 0.5 \
				and local.y >= size.y * 0.5 - 0.3 and local.y <= size.y * 0.5 + 1.0:
			return [spec["to"], float(spec.get("heading", 0.0))]

	return []


## The upward speed a bouncer under [param ground_id] gives, or 0.
func bounce(ground_id: int) -> float:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return 0.0

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if str(piece["kind"]) != "bouncer":
		return 0.0

	return float((piece["spec"] as Dictionary)["power"])


## The velocity an obstacle throws a player standing at [param feet] with, on [param tick],
## or zero if nothing is touching them.
##
## [param crouched] shortens the capsule, which is what lets a player duck under a high arm.
## [param limits] is `[minimum speed, maximum speed, lift]`, from the configuration.
func knock(feet: Vector3, crouched: bool, tick: int, limits: Vector3) -> Vector3:
	var t := float(tick) / float(maxi(tick_rate, 1))
	var top := feet + Vector3(0.0, (PLAYER_CROUCHED if crouched else PLAYER_HEIGHT) - PLAYER_RADIUS, 0.0)
	var bottom := feet + Vector3(0.0, PLAYER_RADIUS, 0.0)

	for piece in pieces:
		if not bool(piece["hazard"]):
			continue

		if cull_hazards and feet.distance_to(_hazard_centre(piece)) > _hazard_reach(piece) + PLAYER_HEIGHT + 1.0:
			continue

		var thrown := Vector3.ZERO

		match str(piece["kind"]):
			"spinner":
				thrown = _knock_spinner(piece, bottom, top, t)
			"pendulum":
				thrown = _knock_pendulum(piece, bottom, top, t)
			"pusher":
				thrown = _knock_pusher(piece, bottom, top, t)
			"fall":
				thrown = _knock_fall(piece, bottom, top, t)

		if thrown != Vector3.ZERO:
			var flat := Vector3(thrown.x, 0.0, thrown.z)
			var speed := clampf(flat.length(), limits.x, limits.y)
			flat = flat.normalized() * speed if flat.length() > 0.001 else Vector3.ZERO
			return Vector3(flat.x, maxf(thrown.y, limits.z), flat.z)

	return Vector3.ZERO


## Whether [method knock] skips a hazard too far from the feet to touch them; off only for the check
## that the shortcut answers the same.
var cull_hazards := true


## The middle of the sphere that holds everything [param piece] can reach, for [method knock]'s cull.
func _hazard_centre(piece: Dictionary) -> Vector3:
	var spec: Dictionary = piece["spec"]

	if str(piece["kind"]) == "pendulum":
		return spec["pivot"]

	var root: Node3D = piece["node"]

	if str(piece["kind"]) == "pusher":
		return root.transform * (spec["at"] as Vector3)

	return root.transform.origin


## The radius of that sphere, worked out once per piece: a bound with a margin, never the exact reach.
func _hazard_reach(piece: Dictionary) -> float:
	if piece.has("cull_reach"):
		return piece["cull_reach"]

	var spec: Dictionary = piece["spec"]
	var reach := 0.0

	match str(piece["kind"]):
		"spinner":
			reach = float(spec.get("arm_height", 1.0)) + float(spec["arm_length"]) + float(spec.get("arm_thickness", 0.35))
		"pendulum":
			reach = float(spec["length"]) + float(spec["radius"])
		"pusher":
			reach = (spec["size"] as Vector3).length() + absf(float(spec["reach"]))
		"fall":
			reach = (spec["size"] as Vector3).length()

	piece["cull_reach"] = reach * 1.25 + 1.0
	return piece["cull_reach"]


func _knock_spinner(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var root: Node3D = piece["node"]
	var arm_height := float(spec.get("arm_height", 1.0))
	var length := float(spec["arm_length"])
	var hub_radius := float(spec.get("hub_radius", 0.6))
	var thickness := float(spec.get("arm_thickness", 0.35))
	var count := maxi(int(spec.get("arms", 1)), 1)
	var angle := spinner_angle(spec, t)
	var omega := deg_to_rad(float(spec["speed"]))
	var frame := root.transform
	var hub := frame * Vector3(0.0, arm_height, 0.0)

	for arm in range(count):
		var heading := Basis(Vector3.UP, angle + TAU * float(arm) / float(count))
		var tip := frame * (Vector3(0.0, arm_height, 0.0) + heading * Vector3(length, 0.0, 0.0))
		var start := hub + (tip - hub).normalized() * hub_radius
		var closest := _segments(start, tip, bottom, top)

		if closest[2] > thickness * 0.5 + PLAYER_RADIUS:
			continue

		# The arm's own speed where it touched them: tangent to the circle at that radius,
		# in the direction it turns.
		var on_arm: Vector3 = closest[0]
		var radial := on_arm - hub
		radial.y = 0.0
		var tangent := Vector3.UP.cross(radial).normalized() * signf(omega)
		var push := tangent * absf(omega) * radial.length() * 1.25
		# And a little outward, so the knock carries somebody off the side of the platform
		# rather than along the arm's own path, where the next arm meets them.
		push += radial.normalized() * 2.0
		return push

	return Vector3.ZERO


func _knock_pendulum(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var frame := Transform3D(_yaw_basis(float(spec.get("yaw", 0.0))), spec["pivot"])
	var length := float(spec["length"])
	var radius := float(spec["radius"])
	var angle := pendulum_angle(spec, t)
	var centre := frame * (Basis(Vector3.BACK, angle) * Vector3(0.0, -length, 0.0))
	var distance := _point_segment(centre, bottom, top)

	if distance > radius + PLAYER_RADIUS:
		return Vector3.ZERO

	# The ball's velocity, from the derivative of the swing: the speed of a point at the end
	# of the rod is the angular rate times the length, along the tangent of the arc.
	var dt := 0.001
	var ahead := frame * (Basis(Vector3.BACK, pendulum_angle(spec, t + dt)) * Vector3(0.0, -length, 0.0))
	var velocity := (ahead - centre) / dt
	velocity.y = 0.0

	if velocity.length() < 0.5:
		# At the top of its swing it is barely moving; it still shoves somebody out of the
		# way it came, which is the direction from the ball to them.
		var away := ((bottom + top) * 0.5) - centre
		away.y = 0.0
		return away.normalized() * 3.0

	return velocity * 1.3


func _knock_pusher(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var root: Node3D = piece["node"]
	var frame := root.transform * pusher_transform(spec, t)
	var half := (spec["size"] as Vector3) * 0.5
	var inverse := frame.affine_inverse()

	var hit := false

	for step in range(5):
		var point := bottom.lerp(top, float(step) / 4.0)
		var local := inverse * point
		var clamped := Vector3(
			clampf(local.x, -half.x, half.x),
			clampf(local.y, -half.y, half.y),
			clampf(local.z, -half.z, half.z)
		)

		if local.distance_to(clamped) <= PLAYER_RADIUS:
			hit = true
			break

	if not hit:
		return Vector3.ZERO

	var forward := frame.basis * Vector3(0.0, 0.0, -1.0)
	var dt := 0.02
	var moving := (pusher_extension(spec, t + dt) - pusher_extension(spec, t)) / dt * float(spec["reach"])

	if moving > 0.5:
		return forward * maxf(moving * 1.2, 14.0)

	# Out and holding, or going home: it still will not let anybody stand inside it.
	return forward * 4.0


## A falling curtain pushes whoever is in it off the side it pours toward (`push` m/s along
## the piece's +X), whatever way they were going: a person cannot run through falling water
## and stay on a six-metre deck. Only while it is on; its drips are a warning, never a push.
func _knock_fall(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]

	if not fall_on(spec, t):
		return Vector3.ZERO

	var root: Node3D = piece["node"]
	var inverse := root.transform.affine_inverse()
	var half := (spec["size"] as Vector3) * 0.5
	var height := (spec["size"] as Vector3).y

	for step in range(3):
		var local := inverse * bottom.lerp(top, float(step) / 2.0)

		if absf(local.x) <= half.x + PLAYER_RADIUS * 0.5 and absf(local.z) <= half.z + PLAYER_RADIUS \
				and local.y > -1.0 and local.y < height:
			return root.transform.basis * Vector3(float(spec.get("push", 9.0)), -1.0, 0.0)

	return Vector3.ZERO


## The closest points between two segments, and the distance between them.
##
## Returns `[point on the first, point on the second, distance]`. The standard clamped
## solution; written out rather than taken from `Geometry3D` so the arithmetic is the same
## on every build this runs on.
static func _segments(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var u := 0.0

	if a <= 0.000001 and e <= 0.000001:
		return [p1, p2, p1.distance_to(p2)]

	if a <= 0.000001:
		u = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)

		if e <= 0.000001:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			s = clampf((b * f - c * e) / denom, 0.0, 1.0) if denom > 0.000001 else 0.0
			u = (b * s + f) / e

			if u < 0.0:
				u = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif u > 1.0:
				u = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)

	var c1 := p1 + d1 * s
	var c2 := p2 + d2 * u
	return [c1, c2, c1.distance_to(c2)]


static func _point_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var length := ab.length_squared()

	if length <= 0.000001:
		return point.distance_to(a)

	var s := clampf((point - a).dot(ab) / length, 0.0, 1.0)
	return point.distance_to(a + ab * s)


# --- What a stand-in asks -------------------------------------------------------

## Whether an arm at head height — one to duck, not jump — turns within [param radius] of
## [param at]. Only a spinner is ducked: a pendulum's ball sweeps up through crouching height
## at the ends of its swing, so a duck under one is a slow crawl into it.
func high_arm_near(at: Vector3, radius: float) -> bool:
	for piece in pieces:
		if str(piece["kind"]) != "spinner":
			continue

		var spec: Dictionary = piece["spec"]

		if float(spec.get("arm_height", 1.0)) < 1.1:
			continue

		var hub: Vector3 = spec["at"]

		if Vector2(at.x - hub.x, at.z - hub.z).length() <= float(spec["arm_length"]) + radius:
			return true

	return false


## Whether running straight from [param from] to [param to] at [param speed], starting on
## [param tick], meets no hazard on the way.
##
## [b]The answer is exact, and that is what an obstacle being a function of the tick buys.[/b]
## A bot does not guess when an arm will come round: it asks [method knock] about every point
## of the run at the tick it will be there, the same question its own movement will be asked
## when it gets there. A course a stand-in cannot cross is therefore a course whose timing
## really has no window, which is a finding about the course.
func path_clear(from: Vector3, to: Vector3, tick: int, speed: float, margin_seconds: float = 0.5) -> bool:
	# Four fifths of the run speed: whoever asks is standing still, and the first few metres
	# are spent getting up to speed.
	speed *= 0.8
	var distance := Vector2(to.x - from.x, to.z - from.z).length()
	var seconds := distance / maxf(speed, 0.5) + margin_seconds
	var steps := maxi(int(seconds * 16.0), 1)
	var ticks_per_step := float(tick_rate) / 16.0
	var limits := Vector3(1.0, 1.0, 1.0)

	for step in range(steps + 1):
		var along := clampf(float(step) / 16.0 * speed / maxf(distance, 0.01), 0.0, 1.0)
		var at := from.lerp(to, along)

		if knock(at, false, tick + int(float(step) * ticks_per_step), limits) != Vector3.ZERO:
			return false

	return true


## Whether something solid is under [param point] on [param tick]: what a stand-in asks
## before jumping for a mover or a tile.
func supported(point: Vector3, tick: int) -> bool:
	var t := float(tick) / float(maxi(tick_rate, 1))

	for piece in pieces:
		var spec: Dictionary = piece["spec"]

		match str(piece["kind"]):
			"box", "ramp", "bouncer", "teleport", "conveyor", "mover", "seesaw":
				var frame: Transform3D = transform_of(piece, t) if bool(piece["moving"]) else (piece["node"] as Node3D).transform
				var local := frame.affine_inverse() * point
				var half := (spec["size"] as Vector3) * 0.5

				if absf(local.x) <= half.x - 0.3 and absf(local.z) <= half.z - 0.3 and local.y > -1.0 and local.y < 3.0:
					return true
			"turntable", "cylinder":
				var at: Vector3 = spec["at"]

				if Vector2(point.x - at.x, point.z - at.z).length() <= float(spec["radius"]) - 0.4 \
						and point.y > at.y - 1.0 and point.y < at.y + 3.0:
					return true
			"ball":
				var at: Vector3 = spec["at"]

				if Vector2(point.x - at.x, point.z - at.z).length() <= float(spec["radius"]) * 0.45:
					return true
			"tiles":
				var root: Node3D = piece["node"]
				var local := root.transform.affine_inverse() * point
				var cols := int(spec["cols"])
				var rows := int(spec["rows"])
				var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
				var col := int(roundf(local.x / pitch + float(cols - 1) * 0.5))
				var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))

				if col >= 0 and col < cols and row >= 0 and row < rows and absf(local.y) < 3.0:
					if not tile_down(piece, row * cols + col, t):
						return true

	return false


## The offsets, across the course, from [param point] to the middle of every column of the
## tiles under it (nearest first), or empty when no tiles are under it. What a stand-in asks
## to step to a column whose tile is up, rather than only ever running down the middle.
func tile_columns(point: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []

	for piece in pieces:
		if str(piece["kind"]) != "tiles":
			continue

		var spec: Dictionary = piece["spec"]
		var root: Node3D = piece["node"]
		var local := root.transform.affine_inverse() * point
		var cols := int(spec["cols"])
		var rows := int(spec["rows"])
		var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
		var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))

		if row < 0 or row >= rows or absf(local.y) > 3.0 \
				or absf(local.x) > float(cols) * pitch * 0.5 + 0.5:
			continue

		for col in range(cols):
			var x := (float(col) - float(cols - 1) * 0.5) * pitch
			out.append(root.transform.basis * Vector3(x - local.x, 0.0, 0.0))

		out.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.length() < b.length())
		return out

	return out


## The grid of tiles under [param point] and the cell there, as `{piece, row, col}` (`piece` an
## index into [member pieces]), or empty off every grid. A point in the gap between two rows
## counts as the nearer one, as [method supported] counts it.
func tile_cell(point: Vector3) -> Dictionary:
	for index in range(pieces.size()):
		var piece: Dictionary = pieces[index]

		if str(piece["kind"]) != "tiles":
			continue

		var spec: Dictionary = piece["spec"]
		var local := (piece["node"] as Node3D).transform.affine_inverse() * point
		var cols := int(spec["cols"])
		var rows := int(spec["rows"])
		var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
		var col := int(roundf(local.x / pitch + float(cols - 1) * 0.5))
		var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))

		if col >= 0 and col < cols and row >= 0 and row < rows and absf(local.y) < 3.0:
			return {"piece": index, "row": row, "col": col}

	return {}


## The cell of the tile [param ground_id] is, as [method tile_cell] gives it, or empty when it
## is not a tile. Where a runner actually landed, which is not always the column it aimed at.
func tile_under(ground_id: int) -> Dictionary:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return {}

	var index := int((found as Array)[0])
	var piece: Dictionary = pieces[index]

	if str(piece["kind"]) != "tiles":
		return {}

	var cols := int((piece["spec"] as Dictionary)["cols"])
	var sub := int((found as Array)[1])
	return {"piece": index, "row": sub / cols, "col": sub % cols}


## The offset, across the grid of tiles [param piece_index], from [param point] to the middle
## of column [param col]: what moves a route point down the middle onto that column.
func tile_column_shift(piece_index: int, point: Vector3, col: int) -> Vector3:
	var piece: Dictionary = pieces[piece_index]
	var spec: Dictionary = piece["spec"]
	var root: Node3D = piece["node"]
	var local := root.transform.affine_inverse() * point
	var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
	var x := (float(col) - float(int(spec["cols"]) - 1) * 0.5) * pitch
	return root.transform.basis * Vector3(x - local.x, 0.0, 0.0)


## Whether a runner at [param from] that sets off on [param tick] toward [param to] (a tile, in
## the column it crosses in) can get over every row from there to the grid's far side without
## standing on, or coming down on, a tile that is down — stopping in the middle of a tile to
## wait for the next row where it has to, for as long as the tile under it stays up.
## [param approach_speed] until it is on the first row (a walk off a deck, which is what the
## jump onto the first row is taken at), then [param tile_speed] across them, with
## [param start_delay] seconds of getting going reckoned onto every set-off from a stand.
## [param line] is the way the route crosses the grid; [param slack] (0..1) how much of the
## slow speed and margin to allow for.
##
## [b]The whole crossing, not the next tile.[/b] A runner who asked only whether the tile it
## jumped for would be there a quarter of a second after landing then stood on it waiting for
## the next row, and went down with it: a mistake-free nightmare field fell 1.2 times a run on
## Trapdoor Run's tiles that way. And not a straight run either: at honest margins a column
## of four was clear end to end too seldom to wait for. Every tile is a function of the tick,
## so the crossing is searched forward (where the runner can be standing, when) before it sets
## off, the way a person watches the column and goes.
func tile_crossing_clear(from: Vector3, to: Vector3, tick: int, approach_speed: float,
		tile_speed: float, start_delay: float, line: Vector3 = Vector3.ZERO, slack: float = 1.0) -> bool:
	# How much of the slow speed and the margin to reckon with: all of it before setting off,
	# less once on the tiles, where the runner is already on a crossing that was clear.
	var slow := lerpf(1.0, TILE_SLOW, slack)
	var margin := TILE_MARGIN_SECONDS * slack
	var target := tile_cell(to)

	if target.is_empty():
		return supported(to, tick)

	var piece: Dictionary = pieces[int(target["piece"])]
	var spec: Dictionary = piece["spec"]
	var local_from := (piece["node"] as Node3D).transform.affine_inverse() * from
	var cols := int(spec["cols"])
	var rows := int(spec["rows"])
	var tile := float(spec["tile"])
	var pitch := tile + float(spec.get("gap", 0.25))
	var col := int(target["col"])
	var target_row := int(target["row"])
	var target_z := (float(target_row) - float(rows - 1) * 0.5) * pitch

	# Which way the rows are crossed: [param line], the way the route runs, or else away from
	# the runner toward the target row (which on the target row past its middle is backwards).
	# Distances below are along that way, `along` the runner's own.
	var local_line := (piece["node"] as Node3D).transform.basis.inverse() * line
	var step := 1 if target_z > local_from.z else -1
	if absf(local_line.z) > 0.01:
		step = 1 if local_line.z > 0.0 else -1
	var along := local_from.z * float(step)
	var here := int(roundf(local_from.z / pitch + float(rows - 1) * 0.5))
	var on_tile := here >= 0 and here < rows \
		and absf(along - (float(here) - float(rows - 1) * 0.5) * pitch * float(step)) <= pitch * 0.5

	# The rows still to cross from the target row on, nearest first, and where each one's
	# middle is along the way.
	var order: Array[int] = []
	var middles: Array[float] = []
	var row := target_row
	while row >= 0 and row < rows:
		order.append(row * cols + col)
		middles.append((float(row) - float(rows - 1) * 0.5) * pitch * float(step))
		row += step

	var now := float(tick) / float(maxi(tick_rate, 1))
	var slots := TILE_PLAN_SLOTS
	var dt := 1.0 / float(TILE_PLAN_RATE)
	var half := tile * 0.5

	# The first leg is the question asked: setting off NOW, from where the runner is, for the
	# middle of the target row. Off a deck at the approach speed until over the row; off the
	# tile underfoot, which has to stay up until the runner is off it.
	# Off a deck the way there may be slantwise, to a column beside the runner.
	var near := middles[0] - half
	var across := absf(local_from.x - (float(col) - float(cols - 1) * 0.5) * pitch) if not on_tile else 0.0
	var walked := Vector2(maxf(near - along, 0.0), across).length() if not on_tile else 0.0
	var speed_on := approach_speed if not on_tile else tile_speed
	var fast_on := now + Vector2(maxf(near - PLAYER_RADIUS - along, 0.0), across).length() / speed_on
	var slow_mid := now + start_delay + walked / (approach_speed * slow) \
		+ maxf(middles[0] - maxf(near, along), 0.0) / (tile_speed * slow)

	if on_tile and here != target_row:
		var here_index := here * cols + col
		var leaves := (float(here) - float(rows - 1) * 0.5) * pitch * float(step) + half + PLAYER_RADIUS
		var off := now + start_delay + maxf(leaves - along, 0.0) / (tile_speed * slow)
		if not _tile_up_over(piece, here_index, now, off + margin):
			return false
	elif on_tile:
		fast_on = now

	if not _tile_up_over(piece, order[0], fast_on - margin, slow_mid + margin):
		return false

	# Where the runner can be standing in the middle of each row, by slot from now: from the
	# moment it gets there for as long as the tile stays up.
	# 1 where it can be, 2 where it gets there (and runs on without stopping).
	var standing := PackedByteArray()
	standing.resize(slots)
	_tile_stand(piece, order[0], standing, slow_mid - now, now, dt)

	# Leaving a middle: on the next row from the moment the body's edge can be over it at
	# full speed (from a little short of the middle, where the route lets it go), off this one
	# once the body's edge is past it at the slow speed. The getting going only after a stop:
	# reckoned onto a runner going straight through, four rows of it added up to more than
	# the time some columns are clear for (Trapdoor Run's last grid was never crossable).
	var to_next_fast := maxf(pitch - half - PLAYER_RADIUS - 0.6, 0.0) / tile_speed

	for i in range(order.size()):
		var last := i == order.size() - 1
		var next_standing := PackedByteArray()
		next_standing.resize(slots)
		var any := false

		for k in range(slots):
			if standing[k] == 0:
				continue
			var t := now + float(k) * dt
			var delay := 0.0 if standing[k] == 2 else start_delay
			var off_slow := delay + (half + PLAYER_RADIUS) / (tile_speed * slow)
			var to_mid_slow := delay + pitch / (tile_speed * slow)

			if not _tile_up_over(piece, order[i], t, t + off_slow + margin):
				continue

			if last:
				return true

			if not _tile_up_over(piece, order[i + 1], t + to_next_fast - margin,
					t + to_mid_slow + margin):
				continue

			any = true
			_tile_stand(piece, order[i + 1], next_standing, float(k) * dt + to_mid_slow, now, dt)

		if not any:
			return false
		standing = next_standing

	return false


## Whether column [param col] of the grid of tiles [param piece_index] can be crossed at all,
## setting off from a deck at [param from] for [param to] (a point on the grid), at any
## moment of the tiles' cycle: [method tile_crossing_clear] asked at every sixteenth of a
## second of one period. Worked out once per column and kept.
##
## [b]Some columns never are.[/b] Where one row comes back up just as the row before it
## drops, no runner who keeps to the column gets over: Trapdoor Run's last grid has two
## such columns. A stand-in that claimed one waited its six seconds and went anyway.
func tile_column_crossable(piece_index: int, col: int, from: Vector3, to: Vector3, approach_speed: float,
		tile_speed: float, start_delay: float, line: Vector3) -> bool:
	var key := "%d/%d" % [piece_index, col]

	if _crossable.has(key):
		return bool(_crossable[key])

	var piece: Dictionary = pieces[piece_index]
	var lined := from + tile_column_shift(piece_index, from, col)
	var there := to + tile_column_shift(piece_index, to, col)
	var steps := maxi(int(float((piece["spec"] as Dictionary)["period"]) * float(TILE_PLAN_RATE)), 1)
	var found := false

	for step in range(steps):
		var tick := int(float(step) / float(TILE_PLAN_RATE) * float(tick_rate))
		if tile_crossing_clear(lined, there, tick, approach_speed, tile_speed, start_delay, line):
			found = true
			break

	_crossable[key] = found
	return found


## How many slots ahead, and how many a second, [method tile_crossing_clear] looks.
const TILE_PLAN_RATE := 16
const TILE_PLAN_SLOTS := 128


## Whether tile [param index] of [param piece] is up for the whole of [param from]..[param until].
func _tile_up_over(piece: Dictionary, index: int, from: float, until: float) -> bool:
	var spec: Dictionary = piece["spec"]
	var cycle := tile_cycle(spec, index, from)

	if cycle < float(spec["down"]):
		return false

	return (1.0 - cycle) * float(spec["period"]) > until - from


## Marks in [param standing] every slot from [param arrive] seconds after [param now] for as
## long as tile [param index] stays up after it.
func _tile_stand(piece: Dictionary, index: int, standing: PackedByteArray, arrive: float, now: float, dt: float) -> void:
	var spec: Dictionary = piece["spec"]
	var from := maxi(int(ceilf(arrive / dt)), 0)

	if from >= standing.size():
		return

	var at := now + float(from) * dt
	var cycle := tile_cycle(spec, index, at)

	if cycle < float(spec["down"]):
		return

	var up_for := (1.0 - cycle) * float(spec["period"])
	var until := mini(from + int(up_for / dt), standing.size())

	for k in range(from, until):
		standing[k] = maxi(standing[k], 1)

	if until > from:
		standing[from] = 2


## Whether the tile [param ground_id] is, if it is one, is about to drop (its warning is on).
func tile_dropping(ground_id: int, at: Vector3, tick: int) -> bool:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return false

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if str(piece["kind"]) != "tiles":
		return false

	var t := float(tick) / float(maxi(tick_rate, 1))
	return tile_warning(piece["spec"], int((found as Array)[1]), t) > 0.0 \
		or tile_down(piece, int((found as Array)[1]), t + 0.3)


# --- Weather -------------------------------------------------------------------

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


# --- The course's own facts -----------------------------------------------------

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


## Whether [param point] is inside a box whose BOTTOM-centre is [param at].
##
## Bottom-centre for a gate, because a mapper places a checkpoint on the floor a player
## crosses it on, and the volume rises from there.
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


## Where seat [param seat] of [param of] stands on the start pad.
##
## Rows across the pad from the front, a metre and a half apart, so a full server of
## twenty-four is four rows of six on a ten metre pad and nobody is placed inside anybody.
func start_spot(seat: int, of: int) -> Array:
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


## The route point after [param index] for somebody on [param branch] of a fork.
##
## [b]A fork is laid out in the route as one branch's points and then the other's[/b], between
## the point everybody leaves from and the one everybody meets at. Walking on means skipping
## the points of every branch but your own: on a branch point, its own branch; on the way
## everybody goes, [param branch] (what a stand-in chose), else the first branch it meets.
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


## How far along the course each route point is, metres, a fork counted as long as its
## shortest branch (each branch's points spread over that length). What the race order reads,
## so a runner on the long way round is not counted ahead of one who took the short cut just
## because the long way's points come later in the list.
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
