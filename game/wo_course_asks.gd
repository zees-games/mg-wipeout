extends "wo_course_move.gd"
## What a stand-in asks of the course: hazards on a path, what is supported, the tile grids.

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
## [param tick], meets no hazard. Exact: it asks [method knock] about every point at the tick it
## will be there, so a course no stand-in can cross has really no timing window.
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


## Whether a runner at [param from], setting off on [param tick] for [param to] (a tile), can cross every
## row to the far side without standing on a tile that is down, waiting mid-tile where it must.
## The whole crossing, not the next tile (Trapdoor Run); [param slack] (0..1) scales slow speed and margin.
func tile_crossing_clear(from: Vector3, to: Vector3, tick: int, approach_speed: float,
		tile_speed: float, start_delay: float, line: Vector3 = Vector3.ZERO, slack: float = 1.0) -> bool:
	# All of the slow speed and margin before setting off, less once on a crossing that was clear.
	var slow := lerpf(1.0, TILE_SLOW, slack)
	var margin := tile_margin_seconds * slack
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

	# Rows are crossed along [param line], else from the runner toward the target row; distances
	# below are along that way, `along` the runner's own.
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
	for row in range(target_row, rows if step > 0 else -1, step):
		order.append(row * cols + col)
		middles.append((float(row) - float(rows - 1) * 0.5) * pitch * float(step))

	var now := float(tick) / float(maxi(tick_rate, 1))
	var slots := TILE_PLAN_SLOTS
	var dt := 1.0 / float(TILE_PLAN_RATE)
	var half := tile * 0.5

	# The first leg is the question asked: setting off NOW for the middle of the target row, at
	# the approach speed off a deck (maybe slantwise, to a column beside) or off the tile underfoot.
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

	# Where the runner can be standing mid-row, by slot from now: 1 where it can be, 2 where it
	# gets there (and runs on without stopping).
	var standing := PackedByteArray()
	standing.resize(slots)
	_tile_stand(piece, order[0], standing, slow_mid - now, now, dt)

	return _tile_cross_rows(piece, order, standing, now, pitch, half, tile_speed, slow, start_delay, margin)

## Walks the rows of a crossing from the first, carrying the slots a runner can be standing in.
## Leaving a middle: onto the next row once its edge can be over it at full speed, off this one
## once past at the slow speed. Getting going counts only after a stop (Trapdoor Run).
func _tile_cross_rows(piece: Dictionary, order: Array[int], standing: PackedByteArray, now: float,
		pitch: float, half: float, tile_speed: float, slow: float, start_delay: float, margin: float) -> bool:
	var slots := standing.size()
	var dt := 1.0 / float(TILE_PLAN_RATE)
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


## Whether column [param col] of the grid of tiles [param piece_index] can be crossed at all, from a
## deck at [param from] to [param to], at any moment of the cycle: [method tile_crossing_clear] at
## every sixteenth of a second of a period, kept. Some columns never are (Trapdoor Run's last grid).
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
