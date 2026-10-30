extends DotNetBehaviour

## What a prop replicates: where it is and how it is turned. Server-authoritative and never predicted: Godot's rigid-
## body solver is not reproducible across machines, so a predicted sky of crates would disagree within a second. A
## crate drawn about a snapshot behind is the right trade against a wrong one that snaps back.

var prop: Node3D = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	# Smallest-three, nine bits an element. A tumbling crate's orientation does not need
	# more: the error is under a degree, and nobody aligns a falling crate to a degree.
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(9).interpolated()


## Authority only. The body is moved by the physics server; this copies where it ended up
## into the replicated properties.
func pull() -> void:
	if not _drawable():
		return

	net_position = prop.global_position
	net_rotation = prop.global_basis.get_rotation_quaternion()


## Whether this body can still be asked where it is. `is_inside_tree` as well as `is_instance_valid`: a round re-lays
## the field inside the netcode's loop, and `global_position` on a queued-for-free body logs an error with a backtrace
## per body per tick.
func _drawable() -> bool:
	return prop != null and is_instance_valid(prop) and prop.is_inside_tree()


## Where this body is, for anything that does not care what kind of body it is. A method, not a read of [member
## net_position], because [WoCopterNet] replicates through [DotVehicleNetSync] (three separate floats): reading it off
## a mirrored chopper gave zero, and a late joiner was told every machine was at the origin.
func replicated_position() -> Vector3:
	return net_position


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


## A mirrored prop, on a snapshot. Written straight to the node: nothing here is predicted,
## so there is no reconciliation to spoil by moving it.
func _net_state_applied(_tick: int) -> void:
	_draw()


## Every frame between snapshots. Without this a crate steps at the snapshot rate however
## smoothly the interpolator did its work — the family's own "produced correctly and
## consumed by nothing", which has cost dot-net two bugs.
func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if not _drawable():
		return

	if identity != null and identity.is_authoritative:
		return

	prop.global_position = net_position
	prop.global_basis = Basis(net_rotation)

	# A mirrored body must not be simulated locally too. Freezing is not cosmetic: an unfrozen [RigidBody3D] fights
	# every position written into it and judders against gravity.
	var body := prop as RigidBody3D

	if body != null and not body.freeze:
		body.freeze = true
