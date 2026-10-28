extends "wo_course_pose.gd"
## What a player's movement asks of the course: the ground carried, bounced on or teleported, and what knocks.

## How far whatever [param ground_id] is moves a point at [param at] between [param tick] and the
## next one; zero for a non-carrier. The exact displacement, not velocity times a step: a velocity
## moves a point along the tangent of a turntable and a player standing still spirals off it.
func carry(ground_id: int, at: Vector3, tick: int) -> Vector3:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return Vector3.ZERO

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if not bool(piece["carrier"]):
		return Vector3.ZERO

	if io != null and str(piece["kind"]) == "world":
		return io.carry(ground_id, at, tick)

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
	return found != null and bool(pieces[int((found as Array)[0])]["carrier"]) \
		and (io == null or str(pieces[int((found as Array)[0])]["kind"]) != "world" or io.carries(ground_id))


## The kind of piece [param ground_id] belongs to (`turntable`, `seesaw`, `box`…), or "".
func ground_kind(ground_id: int) -> String:
	var found: Variant = _by_collider.get(ground_id)
	return str(pieces[int((found as Array)[0])]["kind"]) if found != null else ""


## Where a teleport pad under [param feet] sends whoever stands on it, as `[position, heading]`,
## or an empty array. Feet within the footprint and from a little under its top to a metre over
## it: a runner jumping across a corner is sent, one falling past far below is not.
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


## The velocity an obstacle throws a player standing at [param feet] with, on [param tick], or
## zero. [param crouched] shortens the capsule (ducking a high arm); [param limits] is
## `[minimum speed, maximum speed, lift]`, from the configuration.
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


## The closest points between two segments, and the distance: `[point on the first, point on the
## second, distance]`. Written out rather than taken from `Geometry3D` so the arithmetic is the
## same on every build.
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
