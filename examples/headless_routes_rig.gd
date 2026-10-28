extends DotGameCheckSuite

## The floor-flood walker and the io model of headless_routes.

const CELL := 1.0
const MAX_CELLS := 70000
const DIRS := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
	Vector2(0.7071, 0.7071), Vector2(-0.7071, 0.7071), Vector2(0.7071, -0.7071), Vector2(-0.7071, -0.7071)]


class _Walker:
	var space: PhysicsDirectSpaceState3D
	var water: float
	var ladders: Array[AABB]
	var _probe := SphereShape3D.new()
	var max_gap := 5
	var max_up := 1.2
	var max_drop := 8.0
	## Landings per hole, dropped whenever the machinery changes the world.
	var falls := {}
	const FALL_DRIFT := 0.4
	const FALL_STEP := 1.5
	const FALL_MAX := 30.0

	func _init(s: PhysicsDirectSpaceState3D, w: float, l: Array[AABB]) -> void:
		space = s
		water = w
		ladders = l
		_probe.radius = 0.35

	func _free(c: Vector3) -> bool:
		var sq := PhysicsShapeQueryParameters3D.new()
		sq.shape = _probe
		sq.transform = Transform3D(Basis.IDENTITY, c)
		return space.intersect_shape(sq, 1).is_empty()

	## Where a body that steps into the open air at [param at] (feet) can land: free air below it on a coarse grid, drifting
	## sideways up to [constant FALL_DRIFT] of the depth fallen, so floors under an overhang count.
	func _fall(at: Vector3, from_y: float) -> Array[Vector3]:
		var lands: Array[Vector3] = []
		var start := Vector3(at.x, at.y + 0.75, at.z)
		if not _free(start) or not _free(start + Vector3(0, -0.5, 0)):
			return lands
		var seen := {Vector3i.ZERO: true}
		var queue: Array[Vector3] = [start]
		var head := 0
		while head < queue.size() and queue.size() < 1500:
			var c := queue[head]
			head += 1
			var depth := start.y - c.y
			if depth > 1.0:
				var f: Variant = _floor(c.x, c.z, c.y, 2.25)
				if f != null and (f as Vector3).y < from_y - 1.0:
					lands.append(f)
					continue
			if c.y - 0.75 <= water or depth > FALL_MAX:
				continue
			var budget := minf(FALL_DRIFT * depth + 1.5, 8.0)
			var nexts: Array[Vector3] = [c + Vector3(0, -FALL_STEP, 0)]
			for d: Vector2 in DIRS:
				nexts.append(c + Vector3(d.x, 0, d.y) * FALL_STEP)
			for n in nexts:
				var k := Vector3i(roundi((n.x - start.x) / FALL_STEP), roundi((n.y - start.y) / FALL_STEP), roundi((n.z - start.z) / FALL_STEP))
				if seen.has(k) or Vector2(n.x - start.x, n.z - start.z).length() > budget:
					continue
				seen[k] = true
				if _free(n):
					queue.append(n)
		return lands

	func _key(p: Vector3) -> Vector3i:
		return Vector3i(roundi(p.x / CELL), roundi(p.y * 2.0), roundi(p.z / CELL))

	func _floor(x: float, z: float, from_y: float, drop: float) -> Variant:
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - drop, z))
		var hit := space.intersect_ray(q)
		if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7 or (hit["position"] as Vector3).y <= water:
			return null
		var p: Vector3 = hit["position"]
		# room for a body: a sphere at chest height touches nothing
		var sq := PhysicsShapeQueryParameters3D.new()
		sq.shape = _probe
		sq.transform = Transform3D(Basis.IDENTITY, p + Vector3(0, 0.75, 0))
		if not space.intersect_shape(sq, 1).is_empty():
			return null
		return p

	func why(p: Vector3, toward: Vector3) -> String:
		var out := PackedStringArray()
		var dir := Vector3(toward.x - p.x, 0, toward.z - p.z).normalized()
		for d in [1, 2, 3, 4]:
			var x: float = p.x + dir.x * d
			var z: float = p.z + dir.z * d
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, p.y + 1.1, z), Vector3(x, p.y - 7.0, z))
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				out.append("d%d none" % d)
				continue
			var hp: Vector3 = hit["position"]
			var sq := PhysicsShapeQueryParameters3D.new()
			sq.shape = _probe
			sq.transform = Transform3D(Basis.IDENTITY, hp + Vector3(0, 0.75, 0))
			out.append("d%d y%+.2f n%.2f water%s room%s blocked%s %s" % [d, hp.y - p.y, (hit["normal"] as Vector3).y, hp.y <= water, space.intersect_shape(sq, 1).is_empty(), _blocked(p, hp), (hit["collider"] as Node).get_parent().name])
		return " | ".join(out)

	func _blocked(a: Vector3, b: Vector3) -> bool:
		# Both ends at the higher floor's chest height: a block taller than 0.6 m is a jump up, not a wall.
		var h := maxf(a.y, b.y) + 0.6
		var q := PhysicsRayQueryParameters3D.create(Vector3(a.x, h, a.z), Vector3(b.x, h, b.z))
		return not space.intersect_ray(q).is_empty()

	## The cells one step from `p`: walks, jumps, falls, ladders and open teleports (setting `tp_hit`).
	func _neighbours(p: Vector3, body: AABB, tps: Array, tp_hit: Array) -> Array[Vector3]:
		var found: Array[Vector3] = []
		for dir: Vector2 in DIRS:
			for d: int in range(1, max_gap + 1):
				var x: float = p.x + dir.x * d * CELL
				var z: float = p.z + dir.y * d * CELL
				var up := max_up
				var f: Variant = _floor(x, z, p.y + up + 0.1, up + max_drop)
				if f == null:
					continue
				var n: Vector3 = f
				if n.y - p.y > up + 0.05 or _blocked(p, n):
					continue
				found.append(n)
				if d == 1:
					break

		# A hole beside the cell: step off and fall, steering in the air under whatever overhangs the shaft.
		for dir: Vector2 in DIRS.slice(0, 4):
			var fx: float = p.x + dir.x * CELL
			var fz: float = p.z + dir.y * CELL
			if _floor(fx, fz, p.y + max_up + 0.1, max_up + max_drop) != null:
				continue
			var hole := Vector3i(roundi(fx / 2.0), roundi(p.y / 2.0), roundi(fz / 2.0))
			if not falls.has(hole):
				falls[hole] = _fall(Vector3(fx, p.y, fz), p.y)
			found.append_array(falls[hole])

		for ladder in ladders:
			if ladder.grow(0.9).intersects(body):
				for off in [Vector2(1.2, 0), Vector2(-1.2, 0), Vector2(0, 1.2), Vector2(0, -1.2)]:
					var c := ladder.get_center()
					var f: Variant = _floor(c.x + off.x, c.z + off.y, ladder.end.y + 1.2, 3.0)
					if f != null and (f as Vector3).y > p.y:
						found.append(f)

		for i in tps.size():
			var t: Dictionary = tps[i]
			if not (t["open_fn"] as Callable).call():
				continue
			for box: AABB in t["boxes"]:
				# a 0.25 m trigger plane falls between 1 m cells, so pad each axis to a cell
				var pad := Vector3(maxf(box.size.x, CELL), maxf(box.size.y, CELL), maxf(box.size.z, CELL))
				if AABB(box.get_center() - pad * 0.5, pad).grow(0.2).intersects(body):
					tp_hit[i] = true
					found.append(t["to"])
					break
		return found


	func flood(start: Vector3, finish: AABB, tps: Array, hurts: Array, seeds: Array = []) -> Dictionary:
		var seen := {}
		var queue: Array[Vector3] = [start]
		var tp_hit: Array = []
		for _t in tps:
			tp_hit.append(false)
		seen[_key(start)] = true
		for sd: Vector3 in seeds:
			if not seen.has(_key(sd)):
				seen[_key(sd)] = true
				queue.append(sd)
		var reached := false
		var nearest := INF
		var near_at := start
		var head := 0
		var capped := false
		var fin := finish.grow(0.6)

		while head < queue.size():
			var p := queue[head]
			head += 1
			if queue.size() >= MAX_CELLS:
				capped = true
				break
			var body := AABB(p + Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 1.8, 0.6))
			if fin.intersects(body):
				reached = true
			var dist := finish.get_center().distance_to(p)
			if dist < nearest:
				nearest = dist
				near_at = p

			var found := _neighbours(p, body, tps, tp_hit)

			for n in found:
				var k := _key(n)
				if seen.has(k):
					continue
				var hurt := false
				for hb: AABB in hurts:
					if hb.intersects(AABB(n + Vector3(-0.2, 0.2, -0.2), Vector3(0.4, 1.4, 0.4))):
						hurt = true
						break
				if hurt:
					continue
				seen[k] = true
				queue.append(n)

		return {"finish": reached, "cells": queue.size(), "capped": capped, "tp_hit": tp_hit, "nearest": nearest, "queue": queue,
			"near_at": near_at}


## The machinery of a world run on the map's own io graph: what a runner on the cells found so far can set off, the
## doors that then stand open (latched), and the rides, whose top cells join the walk in every pose. The io clock
## advances, the runner never moves, and teleports are the walker's own edges (never fired).
class _Model:
	const SAMPLE_TICKS := 16
	const BATCH_SECONDS := 10.0
	const DOOR_CLASSES := ["func_door", "func_door_rotating", "prop_door_rotating", "func_button", "func_rot_button"]
	const USE_REACH := 2.2
	const SHOOT_REACH := 30.0

	var io: DotMapIO
	var world: DotMapWorld
	var info: Dictionary
	var fired := {}
	var latched := {}
	var ride_cells: Array[Vector3] = []
	var ride_seen := {}
	var log: Array[String] = []
	var rides_met := {}
	var space: PhysicsDirectSpaceState3D
	var reached: Array[Vector3] = []
	var _movers: Array = []

	func _init(w: DotMapWorld, body_info: Dictionary, s: PhysicsDirectSpaceState3D) -> void:
		world = w
		io = w.io
		info = body_info
		space = s
		for e: DotMapEntity in io.entities:
			if e is DotMapMoverNode and (e as DotMapMoverNode).mover != null and e.node != null:
				_movers.append(e)

	func _info_at(p: Vector3) -> Dictionary:
		var i := info.duplicate()
		i["position"] = p
		return i

	func _label(e: DotMapEntity) -> String:
		return "%s%s" % [e.classname, "(" + e.targetname + ")" if e.targetname != "" else "#%d" % e.index]

	## The mover's hit box in the world, now.
	func _box(m: DotMapMoverNode) -> Transform3D:
		return m.pose_delta(io.now, io.rate) * m.hit_frame

	func _door_like(m: DotMapMoverNode) -> bool:
		return m.mover.kind != DotMapMover.KIND_PATH and m.mover.kind != DotMapMover.KIND_SPIN and m.classname.to_lower() in DOOR_CLASSES

	## Sets off what a body standing on any of [param cells] can; returns how many things went.
	func fire(cells: Array[Vector3]) -> int:
		var n := 0
		var bodies: Array[AABB] = []
		for p in cells:
			bodies.append(AABB(p + Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 1.8, 0.6)))
		for vn: DotMapVolumeNode in world.volumes.nodes:
			if fired.has(vn) or not vn.active() or vn.volume.kind not in ["multiple", "once"]:
				continue
			var boxes := vn.volume.brush_boxes()
			var at := -1
			for i in cells.size():
				var cb := bodies[i]
				var hit := false
				for box: AABB in boxes:
					if box.size.is_finite() and box.grow(0.1).intersects(cb):
						hit = true
						break
				if hit:
					var inf := _info_at(cells[i])
					if vn._admits(io, inf) and vn._touches(inf):
						at = i
						break
			if at < 0:
				continue
			fired[vn] = true
			n += 1
			log.append("walk into %s at (%.0f,%.0f,%.0f)" % [_label(vn.entity) if vn.entity != null else vn.volume.targetname, cells[at].x, cells[at].y, cells[at].z])
			vn._enter(io, _info_at(cells[at]))
			io._settle()
		for m: DotMapMoverNode in _movers:
			if fired.has(m) or not (m.mover.use or m.mover.touch) or m.hit_half == Vector3.ZERO or not m.alive:
				continue
			var inv := _box(m).affine_inverse()
			var at := -1
			for i in cells.size():
				var d := _dist_to_box(inv * (cells[i] + Vector3(0, 1.4, 0)), m.hit_half)
				if d <= (USE_REACH if m.mover.use else 0.6):
					at = i
					break
			if at < 0:
				continue
			var inf := _info_at(cells[at])
			if m.locked:
				continue
			if m.touched(io, inf, m.mover.use):
				fired[m] = true
				n += 1
				log.append("%s %s from (%.0f,%.0f,%.0f)" % ["use" if m.mover.use else "touch", _label(m), cells[at].x, cells[at].y, cells[at].z])
				io._settle()
		# a shot: a button that fires OnDamaged or is flagged damage-activated, a breakable that has outputs; from any cell that sees it
		for e: DotMapEntity in io.entities:
			if fired.has(e) or not e.alive or e.node == null:
				continue
			var shootable := false
			if e is DotMapMoverNode and (e as DotMapMoverNode).mover != null and (e as DotMapMoverNode).mover.kind.ends_with("button"):
				shootable = e.has_spawnflag(512) or e.links.any(func(l: Dictionary) -> bool: return str(l["output"]) == "ondamaged")
			elif e is DotMapBreakable:
				shootable = not e.links.is_empty() and (e as DotMapBreakable).health > 0.0 and not (e as DotMapBreakable).broken
			if not shootable:
				continue
			var target := _centre(e)
			for p in cells:
				var eye := p + Vector3(0, 1.6, 0)
				if eye.distance_to(target) > SHOOT_REACH:
					continue
				var q := PhysicsRayQueryParameters3D.create(eye, target)
				var hit := space.intersect_ray(q)
				if hit.is_empty() or e.node.is_ancestor_of(hit["collider"] as Node) or (hit["position"] as Vector3).distance_to(target) < 0.7:
					fired[e] = true
					n += 1
					log.append("shoot %s from (%.0f,%.0f,%.0f)" % [_label(e), p.x, p.y, p.z])
					io.hurt(e.index, 100.0, target, info)
					break
		return n

	func _centre(e: DotMapEntity) -> Vector3:
		if e is DotMapMoverNode and (e as DotMapMoverNode).hit_half != Vector3.ZERO:
			return _box(e as DotMapMoverNode).origin
		return e.node.global_position

	## The few things nobody reached that lie closest to [param p]: a trigger or a button the walk never got to.
	func nearest_unfired(p: Vector3) -> Array[String]:
		var found: Array = []
		for vn: DotMapVolumeNode in world.volumes.nodes:
			if not fired.has(vn) and vn.volume.kind in ["multiple", "once"]:
				var bs := vn.volume.brush_boxes()
				if not bs.is_empty() and (bs[0] as AABB).size.is_finite():
					found.append([(bs[0] as AABB).get_center().distance_to(p), "trigger %s" % (_label(vn.entity) if vn.entity != null else vn.volume.targetname)])
		for mv: DotMapMoverNode in _movers:
			if not fired.has(mv) and (mv.mover.use or mv.mover.touch) and mv.hit_half != Vector3.ZERO:
				found.append([_box(mv).origin.distance_to(p), "%s %s" % ["use" if mv.mover.use else "touch", _label(mv)]])
		found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
		var out: Array[String] = []
		for i in mini(4, found.size()):
			out.append("%s %.0f m" % [found[i][1], found[i][0]])
		return out

	static func _dist_to_box(q: Vector3, half: Vector3) -> float:
		var out := Vector3(maxf(absf(q.x) - half.x, 0.0), maxf(absf(q.y) - half.y, 0.0), maxf(absf(q.z) - half.z, 0.0))
		return out.length()

	## Runs the io clock; samples the rides and holds opened doors open.
	func advance(seconds: float) -> void:
		sample()
		var ticks := int(seconds * io.rate)
		for t in ticks:
			io.advance(1)
			_hold()
			if t % SAMPLE_TICKS == SAMPLE_TICKS - 1:
				sample()

	func _hold() -> void:
		for m: DotMapMoverNode in latched:
			m.node.transform = latched[m]

	func sample() -> void:
		for m: DotMapMoverNode in _movers:
			if m.node == null or not m.alive:
				continue
			if _door_like(m):
				if not latched.has(m) and m._to >= 1.0 and not m.mover.kind.ends_with("button"):
					var t := m.mover.transform_at(1.0, m._side)
					latched[m] = Transform3D(t.basis * m._base.basis, m._base.origin + t.origin)
					log.append("%s opens" % _label(m))
				continue
			if m.hit_half == Vector3.ZERO:
				continue
			var xf := _box(m)
			var box := xf * AABB(-m.hit_half, m.hit_half * 2.0)
			var around := AABB(box.position - Vector3(1.5, 1.8, 1.5), box.size + Vector3(3.0, 1.8 + 0.8 + 1.8, 3.0))
			var boarded := rides_met.has(m)
			if not boarded:
				for p in reached:
					if around.has_point(p + Vector3(0, 0.5, 0)):
						boarded = true
						rides_met[m] = true
						log.append("meets %s at (%.0f,%.0f,%.0f)" % [_label(m), p.x, p.y, p.z])
						break
			if not boarded:
				continue
			var x := box.position.x + 0.5
			while x < box.end.x:
				var z := box.position.z + 0.5
				while z < box.end.z:
					var p := Vector3(x, box.end.y, z)
					var k := Vector3i(roundi(p.x), roundi(p.y * 2.0), roundi(p.z))
					if not ride_seen.has(k):
						ride_seen[k] = true
						ride_cells.append(p)
					z += 1.0
				x += 1.0
