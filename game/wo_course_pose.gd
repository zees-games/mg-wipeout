extends Node3D
## Where each piece is at a tick, as a pure function of it, and the state those functions read.

const WoCourseIo := preload("wo_course_io.gd")

const WoTextures := preload("wo_textures.gd")

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

## The margin in force; [member WoConfig.bot_tile_margin_seconds] on the server.
var tile_margin_seconds: float = TILE_MARGIN_SECONDS

## The slowest share of the given speeds a stand-in crossing tiles is reckoned to go at.
const TILE_SLOW := 0.9

## The map's own entity logic when a `world` piece says `"io": true`; else null.
var io: WoCourseIo = null

## Ticks a second, for turning a tick into the time every formula is written in.
var tick_rate: int = 64

## One per piece, in document order. See [method _make_piece].
var pieces: Array[Dictionary] = []

## Collider instance id -> [code][piece index, sub-index][/code], for the carry and the bounce.
var _by_collider: Dictionary = {}

## "piece/col" to whether that column of tiles can be crossed at all. See [method tile_column_crossable].
var _crossable: Dictionary = {}

## The tick the moving pieces were last posed at, so a second call for the same tick is free.
var _posed_tick: int = -2147483648

var _posed_time: float = -1.0

## Seconds a curtain takes to reach the deck once it starts, and to clear once it stops.
## Drawing only: the knock is on for exactly `duty` of the period.
const FALL_SHEET_SECONDS := 0.3

## Seconds of drips before a curtain comes down: its tell, like a tile's red.
const FALL_WARN_SECONDS := 0.7


static func _yaw_basis(yaw_degrees: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_degrees))


## Puts [param body] at [param at] in the node AND in the physics server, now. The node alone
## is a tick late (transforms flush at the next frame), so a client replaying past ticks would
## sweep them against obstacles where they were a frame ago.
static func _place(body: Node3D, at: Transform3D) -> void:
	body.transform = at

	if body is CollisionObject3D and body.is_inside_tree():
		PhysicsServer3D.body_set_state(
			(body as CollisionObject3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			body.global_transform
		)


static func _conveyor_basis(spec: Dictionary) -> Basis:
	return _yaw_basis(float(spec.get("yaw", 0.0))) * Basis(Vector3.RIGHT, deg_to_rad(float(spec.get("pitch", 0.0))))


## Poses every moving piece at [param tick]. Idempotent per tick.
func pose_at(tick: int) -> void:
	if io != null:
		io.pose_at(tick)

	if tick == _posed_tick:
		return

	pose_at_time(float(tick) / float(maxi(tick_rate, 1)))
	_posed_tick = tick


## Poses every moving piece at [param seconds]. What a client draws between two ticks. Forgets
## the tick it was posed at: colliders have moved off it, so the next [method pose_at] must not
## take the shortcut.
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


## How far out a pusher's ram is, 0 at rest and 1 at full reach. Fast out, a hold, slower back,
## then home for the rest of the period: a sine would leave no gap to time, and the rest is the
## window a player runs through.
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


## Whether tile [param index] of a tiles piece is gone at [param t]. Each tile's offset into the
## cycle is a hash of the piece's seed, not a random stream, so every machine agrees whatever
## else has drawn.
static func tile_down(piece: Dictionary, index: int, t: float) -> bool:
	return tile_cycle(piece["spec"], index, t) < float((piece["spec"] as Dictionary)["down"])


## Where tile [param index] is in its cycle, 0..1. It drops at 0 and comes back at `down`.
static func tile_cycle(spec: Dictionary, index: int, t: float) -> float:
	var seed := int(spec.get("seed", 1))
	var offset := float(_mix(seed * 7919 + index * 104729) % 1000) / 1000.0
	return fposmod(t / float(spec["period"]) + offset, 1.0)


## How close tile [param index] is to dropping, 0 (not soon) to 1 (now). A tile that drops with no
## tell is a coin toss, so it shakes and turns the hazard colour for the last
## [constant TILE_WARN_SECONDS]; a function of the tick, so every client shows it together.
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
