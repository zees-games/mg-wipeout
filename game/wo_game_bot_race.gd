extends "wo_game_bot_fight.gd"
## How a stand-in reads a course: landings, hops, tiles and the route.

## How early or late a runner may be against the timing of [method _span_clear], in seconds.
const SPAN_SLACK := 0.25


## Whether the run from [param from] through the next [param span] route points meets no hazard,
## timed at a run to a jump point and at a hop's pace from one, early and late by [constant SPAN_SLACK].
func _span_clear(from: Vector3, index: int, span: int) -> bool:
	var route := stage.route()

	if span <= 1 and index + 1 < route.size():
		return stage.path_clear(from, (route[index + 1] as Dictionary)["at"], _tick, _cfg().run_speed)

	for slack in [-SPAN_SLACK, 0.0, SPAN_SLACK]:
		var offset: float = slack
		var here := from

		for i in range(index + 1, mini(index + 1 + span, route.size())):
			var there: Vector3 = (route[i] as Dictionary)["at"]
			var from_jump := i - 1 >= 0 and bool((route[i - 1] as Dictionary)["jump"])
			var speed := _cfg().bot_hop_speed if from_jump else _cfg().run_speed
			var length := Vector2(there.x - here.x, there.z - here.z).length()

			if not stage.path_clear(here, there, _tick + int(maxf(offset, 0.0) * float(_rate())), speed / 0.8, 0.0):
				return false

			offset += length / speed
			here = there

	return true


## What this stand-in will get wrong at route point [param index]: decided once per point and
## attempt. A jump not taken, a take-off early or late, a window not waited for.
func _bot_plan(player: WoPlayer, racing: Dictionary, index: int) -> void:
	if int(racing["plan_index"]) == index and int(racing["plan_falls"]) == player.falls:
		return

	var factor := float(racing["factor"])
	var salt := index * 64 + player.falls
	racing["plan_index"] = index
	racing["plan_falls"] = player.falls
	racing["fumble"] = _bot_roll(&"bot_fumble", player, salt) * 100.0 < racer.value("fumble") * factor
	racing["rash"] = _bot_roll(&"bot_rash", player, salt) * 100.0 < racer.value("rash") * factor
	# Early or late by up to `timing` seconds, evenly: early is a jump taken that much further
	# back (shorter, still made over most gaps), late is that much more run before it — and
	# past an edge point half a metre from the edge, a late take-off is a step into the water.
	var off := (_bot_roll(&"bot_timing", player, salt) * 2.0 - 1.0) * racer.value("timing") * factor
	# A third of it off a TOP (a ball, a log, a pad), where a person jumps the moment they land.
	# At the full error medium stand-ins fell off First Splash's balls on six attempts in ten:
	# a ball is under a metre of top.
	var route := stage.route()
	if index < route.size() and float((route[index] as Dictionary)["reach"]) > 0.6:
		off *= 0.35
	racing["late"] = int(maxf(off, 0.0) * float(_rate()))
	racing["late_going"] = false
	racing["queued"] = 0
	racing["early"] = maxf(-off, 0.0) * _cfg().run_speed
	racing["window"] = -1


## A stand-in on a course that is a map's own world: along the navigation mesh to the finish ([WoIoBot]).
func _bot_run_io(player: WoPlayer, command: DotFpsCommand) -> void:
	if stage.io == null or stage.io.world == null:
		return

	if _io_bot == null or _io_bot.source != stage.io:
		if _io_bot != null:
			_io_bot.clear()
		var tunables := player.controller.tunables
		_io_bot = WoIoBot.new()
		stage.io.touch_doors = true
		_io_bot.setup(stage.io, stage.io.world, stage.finish_box(), {
			"radius": tunables.radius if tunables != null else 0.35, "height": 0.9, "climb": 0.42}, stage.io.links(),
			stage.doc.get("io_route", []))

	_io_bot.steer(player.controller.state.position, player.controller.state.mode == DotFpsState.Mode.GROUND,
		_tick, player.player_id, command)


## Whether somebody else is on, or coming down on, the top at route point [param point]: a
## point a jump lands on (`jump` or `bounce` with a reach of a top), with a body within 1.5 m of
## it across and not far above or below.
func _top_taken(player: WoPlayer, point: Dictionary) -> bool:
	if not (bool(point["jump"]) or bool(point.get("bounce", false))) or float(point["reach"]) <= 0.6:
		return false

	if not body_rules.solid:
		return false

	var at: Vector3 = point["at"]

	for id: StringName in players:
		var other: WoPlayer = players[id]

		# Stand-ins pass through each other (see [method _apply_body_mask]): only a person in
		# the way is in the way.
		if other == player or other.is_bot or not other.is_alive() or other.watching or other.finished:
			continue

		var there := other.controller.state.position
		var across := Vector2(there.x - at.x, there.z - at.z).length()

		if across < 1.5 and absf(there.y - at.y) < 2.5:
			return true

		# Coming down on it: in the air within a jump of it and moving toward it.
		var velocity := other.controller.state.velocity
		var toward_top := Vector2(at.x - there.x, at.z - there.z)
		if other.controller.state.mode != DotFpsState.Mode.GROUND and across < 5.0 \
				and Vector2(velocity.x, velocity.z).dot(toward_top) > 0.0:
			return true

	return false


## The flat speed a jump from [param from] needs to come down on [param to] (a little short of
## it is enough: a top has a reach). From the configuration's jump height and gravity.
func _jump_speed_needed(from: Vector3, to: Vector3) -> float:
	var g := _cfg().gravity
	var up := sqrt(2.0 * g * _cfg().jump_height)
	var rise := to.y - from.y
	var root := up * up - 2.0 * g * rise
	if root <= 0.0:
		return INF
	var airtime := (up + sqrt(root)) / g
	var distance := maxf(Vector2(to.x - from.x, to.z - from.z).length() - 0.2, 0.0)
	return distance / maxf(airtime, 0.05)


## How far past a top's point a stand-in aims to land, metres. See [method _bot_land_on].
const LAND_PAST := 0.3


## Ticks a stand-in may spend getting up to speed on a top before it jumps off it anyway.
const RUNUP_TICKS := 9


## A stand-in on a top going faster than this many times the next jump's need brakes the
## excess on the take-off tick (see [method _bot_run]). At 1.15 a mistake-free field fell on
## Log Roll's logs.
const TAKEOFF_SPARE := 1.3


## How much of the crossing's slow speed and margin a stand-in already on the tiles allows
## for. With all of it, a runner who set off on a clear crossing found it not clear any more
## from the first row (it lands at a walk, off the model) and stood there until the tile went.
const TILE_ON_SLACK := 0.4


## Metres off its column's middle a stand-in on a deck counts as lined up on it.
const TILE_LINED_UP := 0.3


## Seconds a stand-in waits on the deck for its own column of tiles before it takes another
## whose crossing is clear and no more of the field has claimed; after twice this, any.
const TILE_PATIENCE := 1.5


## The offset that moves [param point], a route point on a grid of tiles, onto the column this
## stand-in crosses it in; zero for a point on no tiles. Stand-ins pass through each other, so a
## field spreads: on the deck it claims the least-claimed crossable column, on the tiles the one under it.
func _bot_tile_column(player: WoPlayer, racing: Dictionary, point: Dictionary, on_tile: bool) -> Vector3:
	var at: Vector3 = point["at"]
	var cell := stage.tile_cell(at)

	if cell.is_empty():
		return Vector3.ZERO

	var piece := int(cell["piece"])

	if on_tile:
		var under := stage.tile_under(player.controller.state.ground_id)
		if int(under["piece"]) == piece:
			racing["tile_piece"] = piece
			racing["tile_col"] = int(under["col"])
			racing["tile_falls"] = player.falls
	elif int(racing.get("tile_piece", -1)) != piece or int(racing.get("tile_falls", -1)) != player.falls:
		var cols := int((stage.pieces[piece]["spec"] as Dictionary)["cols"])
		var claims := _tile_claims(player, piece)

		# Among the columns that can be crossed at all (see `WoCourse.tile_column_crossable`).
		var here := player.controller.state.position
		var walk := _cfg().run_speed * _cfg().walk_speed_scale
		var line := _tile_line(at)
		var best := -1
		for col in range(cols):
			if not stage.tile_column_crossable(piece, col, here, at, walk, _cfg().run_speed, _cfg().bot_tile_start_seconds, line):
				continue
			if best < 0 or claims[col] < claims[best] or (claims[col] == claims[best] \
					and stage.tile_column_shift(piece, here, col).length() < stage.tile_column_shift(piece, here, best).length()):
				best = col
		if best < 0:
			best = int(cell["col"])

		racing["tile_piece"] = piece
		racing["tile_col"] = best
		racing["tile_falls"] = player.falls

	return stage.tile_column_shift(piece, at, int(racing["tile_col"]))


## How many other stand-ins have claimed each column of the grid of tiles [param piece] and
## are still on their way over it.
func _tile_claims(player: WoPlayer, piece: int) -> Array[int]:
	var claims: Array[int] = []
	claims.resize(int((stage.pieces[piece]["spec"] as Dictionary)["cols"]))
	claims.fill(0)
	var route := stage.route()

	for id: StringName in _bot_racer:
		var other: Dictionary = _bot_racer[id]
		var them: WoPlayer = players.get(id)
		if them == null or them == player or int(other.get("tile_piece", -1)) != piece \
				or int(other.get("tile_falls", -1)) != them.falls:
			continue
		var their_index := mini(int(_bot_route.get(id, 0)), route.size() - 1)
		var their_cell := stage.tile_cell((route[their_index] as Dictionary)["at"])
		if not their_cell.is_empty() and int(their_cell["piece"]) == piece:
			claims[int(other.get("tile_col", 0))] += 1

	return claims


## The way the route runs at the route point nearest [param at] (from the point before it).
func _tile_line(at: Vector3) -> Vector3:
	var route := stage.route()
	var nearest := 0
	for i in range(route.size()):
		if ((route[i] as Dictionary)["at"] as Vector3).distance_to(at) < ((route[nearest] as Dictionary)["at"] as Vector3).distance_to(at):
			nearest = i
	var before := stage.route_prev(nearest, 0)
	return ((route[nearest] as Dictionary)["at"] as Vector3) - ((route[before] as Dictionary)["at"] as Vector3) if before >= 0 else Vector3.ZERO


## Stops behind somebody standing (or nearly) right in front, as people queue at an edge; true
## when it stopped. Without it eight stand-ins at one edge pushed each other into the water, and a
## walk is no run-up. Only near a jump point and behind somebody nearer it, so a queue is never a ring.
func _bot_queue(player: WoPlayer, command: DotFpsCommand, jump_at: Vector3) -> bool:
	if player.controller.state.mode != DotFpsState.Mode.GROUND or command.move == Vector2.ZERO \
			or not body_rules.solid:
		return false

	var at := player.controller.state.position
	var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))
	var mine := Vector2(jump_at.x - at.x, jump_at.z - at.z).length()

	for id: StringName in players:
		var other: WoPlayer = players[id]

		if other == player or other.is_bot or not other.is_alive() or other.watching or other.finished:
			continue

		var gap := other.controller.state.position - at

		if absf(gap.y) > 0.8:
			continue

		gap.y = 0.0
		var ahead := gap.dot(heading)
		var going := other.controller.state.velocity.dot(heading)

		var theirs := Vector2(jump_at.x - other.controller.state.position.x, jump_at.z - other.controller.state.position.z).length()

		if ahead > 0.0 and ahead < 1.5 and (gap - heading * ahead).length() < 0.9 and going < 3.0 and going > -0.5 and theirs < mine:
			command.move = Vector2.ZERO
			return true

	return false


## Steers a bot in the air so it comes down on [param target] rather than past it. A running jump
## is long and a top small, so this predicts where the jump comes down at the target's height and
## holds BACK (the motor's air control brakes hard against the motion) while that is past it.
func _bot_land_on(player: WoPlayer, command: DotFpsCommand, target: Vector3, line: Vector3, top: bool = false) -> void:
	var state := player.controller.state
	var flat := Vector3(target.x - state.position.x, 0.0, target.z - state.position.z)

	if flat.length() > 7.0:
		return

	var g := _cfg().gravity
	var rise := target.y - state.position.y
	var root := state.velocity.y * state.velocity.y - 2.0 * g * rise

	if root < 0.0:
		return

	var falls_in := (state.velocity.y + sqrt(root)) / g
	command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
	var current := Vector3(state.velocity.x, 0.0, state.velocity.z)
	# How far past the target the landing is, along the JUMP'S LINE (point before to this one).
	# Along the runner-to-target line a jump level with a pad counted nothing as over, and along
	# the velocity a sideways drift counted as over: either braked short or too late (Spin Cycle).
	var along := Vector3(line.x, 0.0, line.z)
	if along.length() < 0.5:
		along = current
	var over := 0.0
	if along.length() > 0.01:
		var lands := state.position + current * falls_in
		over = Vector3(lands.x - target.x, 0.0, lands.z - target.z).dot(along.normalized())

	# Aiming a little PAST the top, never at it: a runner who comes down on a ball's top at a
	# stroll cannot jump on to the next one. Braking all the way to the point left stand-ins a
	# metre short of every third ball.
	over -= LAND_PAST

	# A quarter of a metre is near enough for an edge or a pad; a ball's top slopes, so a landing
	# half a metre past it comes down lower and later (Big Balls). A top is braked to five centimetres.
	if over <= (0.05 if top else 0.25) or falls_in <= 0.02 or current.length() < 0.5:
		# Nothing in: no wish adds nothing to a jump already at speed, and the jump lands
		# where it was always going to.
		command.move = Vector2.ZERO
		return

	# Braked against the velocity, never back along the line to the target: off the line that
	# wish pushes AWAY from it and drifted a runner four metres sideways past the ball (Big Balls).
	# A wish against the velocity only slows; it never turns.
	command.yaw = rad_to_deg(atan2(-current.x, -current.z))

	# Proportional, and full back is far too much: the motor takes over three metres a second
	# off a jump in ONE tick when the wish is fully against it, and the first version stopped
	# every jump dead a metre off the deck. The slowdown needed, spread over the ticks left.
	var ticks_left := maxf(falls_in * float(_rate()), 1.0)
	var per_tick := over / falls_in / ticks_left
	var full := _cfg().run_speed * 30.0 / float(_rate())
	# A stand-in steers a landing as well as `wo_bot_landing` says: below 1 it brakes too
	# little and comes down past a small top, which is how a person slides off a ball.
	var skill := racer.value("landing") if racer != null else 1.0
	command.move = Vector2(0.0, -clampf(per_tick / full * skill, 0.02, 1.0))


## Brakes a jump that is going to come down off the side of the deck it was taken over: true
## when it braked. Only while ground is under the bot and the jump will land on nothing. A hop is
## taken the way the bot ran, mostly sideways round a spinner, and carried fields off Spin Cycle.
func _bot_save_landing(player: WoPlayer, command: DotFpsCommand, target: Vector3, line: Vector3) -> bool:
	var state := player.controller.state
	var current := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if current.length() < 0.5:
		return false

	var height := target.y
	var root := state.velocity.y * state.velocity.y - 2.0 * _cfg().gravity * (height - state.position.y)

	if root < 0.0:
		return false

	var falls_in := (state.velocity.y + sqrt(root)) / _cfg().gravity
	var below := Vector3(state.position.x, height + 0.1, state.position.z)
	var lands := below + current * falls_in

	var lands_tick := _tick + int(falls_in * float(_rate()))

	if stage.supported(lands, lands_tick) or not stage.supported(below, _tick):
		return false

	# And only a jump going off the SIDE: the same jump straight down the route's line would
	# have come down on something. A hop taken toward the front edge is a hop over an arm or a
	# hammer, and braking it under the arm (Big Balls' wrecking balls) is worse than the edge.
	var ahead := Vector3(line.x, 0.0, line.z)

	if ahead.length() < 0.5 or not stage.supported(below + ahead.normalized() * current.length() * falls_in, lands_tick):
		return false

	command.yaw = rad_to_deg(atan2(-current.x, -current.z))
	command.move = Vector2(0.0, -1.0)
	return true


## Jumps when the bot has been running for a second and got nowhere. A turning log's steep side
## is a treadmill: a bot at exactly the log's speed stayed on the same spot for half a minute.
func _bot_unstick(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var mark: Array = _bot_stuck.get(player.player_id, [])

	# Letting go, for half a second after being stuck on something too steep to jump from.
	if mark.size() > 2 and _tick < int(mark[2]):
		command.move = Vector2.ZERO
		return

	if mark.is_empty() or _tick - int(mark[1]) >= _rate():
		# Only against a mark from the last second and a half: a bot held still (waiting for a
		# mover or a tile column) has an old mark and jumped from a standstill (Trapdoor Run).
		var stuck := not mark.is_empty() and command.move != Vector2.ZERO \
			and _tick - int(mark[1]) < _rate() * 3 / 2 \
			and Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4
		var release := -1

		if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		elif stuck:
			# On a face too steep to stand on, the motor has the bot sliding, and a slide is not
			# ground to jump from. Stop pushing and drop: a restart costs seconds, the treadmill
			# cost minutes.
			release = _tick + _rate() / 2

		_bot_stuck[player.player_id] = [at, _tick, release]


## Jumps whatever low thing is about to sweep through where the bot is running, and ducks whatever
## high thing is. Waiting for a gap a sweeper never leaves waits for ever, so this asks the course
## about the next half second and jumps when an arm is due a fifth to a half second from now.
func _bot_hop(player: WoPlayer, command: DotFpsCommand, yaw: float = NAN) -> void:
	if player.controller.state.mode != DotFpsState.Mode.GROUND or command.move == Vector2.ZERO:
		return

	var heading_yaw := command.yaw if is_nan(yaw) else yaw
	var heading := Vector3(-sin(deg_to_rad(heading_yaw)), 0.0, -cos(deg_to_rad(heading_yaw)))
	var at := player.controller.state.position
	var limits := Vector3(1.0, 1.0, 1.0)
	var duck := false
	var jump := false
	var high_arm := stage.high_arm_near(at, 3.0)

	# The same three moments the hop always asked about (a fifth to two fifths of a second:
	# when a jump's feet are over a low arm), plus the two either side for the duck, which
	# has to start earlier and last longer.
	for step in [0.0, 0.2, 0.3, 0.4, 0.6]:
		var ahead: float = step
		# Crouched, a bot runs at the crouch speed; standing, at the run.
		var where_standing := at + heading * _cfg().run_speed * ahead
		var tick := _tick + int(ahead * _rate())

		if stage.knock(where_standing, false, tick, limits) == Vector3.ZERO:
			continue

		# [b]A high arm is ducked, never jumped.[/b] If crouching clears what standing does
		# not, the arm is high; jumping into it is the one wrong answer, and the hop below
		# would give it, because all it knows is that something is coming.
		var where_crouched := at + heading * _cfg().run_speed * 0.4 * ahead

		if high_arm and stage.knock(where_crouched, true, tick, limits) == Vector3.ZERO:
			duck = true
		elif ahead >= 0.2 and ahead <= 0.4 \
				and stage.knock(where_standing + Vector3(0.0, 1.0, 0.0), false, tick, limits) == Vector3.ZERO:
			# Only what a jump clears: a metre up a low arm has passed under, a ram or a hammer has not.
			# Hopping a ram put the runner in it in the air (Punch Alley).
			jump = true

	# Missed now and then (`wo_bot_hop_miss`), decided per half second so one arm is one
	# decision: a stand-in that never misses an arm is the one thing on a sweeper nobody believes.
	if (duck or jump) and racer != null and player.is_bot:
		var racing := _racer_of(player)
		var bucket := _tick / maxi(_rate() / 2, 1)
		if _bot_roll(&"bot_hop", player, bucket) * 100.0 < racer.value("hop_miss") * float(racing["factor"]):
			return

	# A hop that lands in an arm's way is worse than none: see [method _bot_hold_for_landing].
	if jump and not duck and _bot_hold_for_landing(command, at, heading, limits):
		return

	if duck:
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	elif jump:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## Whether [param point] — something to land on — will be under a jump that sets off now: near
## enough to reach at a run, and there when the bot comes down and a moment after. Onto tiles it
## asks the whole crossing (`WoCourse.tile_crossing_clear`): a walk to the first row, a run after.
func _bot_may_board(player: WoPlayer, point: Dictionary, line: Vector3 = Vector3.ZERO) -> bool:
	var from := player.controller.state.position
	var to: Vector3 = point["at"]
	var distance := Vector2(to.x - from.x, to.z - from.z).length()

	var tiles := not stage.tile_cell(to).is_empty()

	# A ride that has not brought the bot this close yet is a ride to stay on. Tiles are not
	# a ride: a column two over is further than that from a deck, and the crossing is timed
	# from wherever the runner is.
	if distance > 5.0 and not tiles:
		return false

	if tiles:
		var velocity := player.controller.state.velocity
		var moving := Vector2(velocity.x, velocity.z).length() > 1.0
		return stage.tile_crossing_clear(from, to, _tick, _cfg().run_speed * _cfg().walk_speed_scale,
			_cfg().run_speed, 0.0 if moving else _cfg().bot_tile_start_seconds, line,
			TILE_ON_SLACK if not stage.tile_under(player.controller.state.ground_id).is_empty() else 1.0)

	var lands := _tick + int(distance / maxf(_cfg().run_speed, 0.5) * float(_rate())) + _rate() / 8
	return stage.supported(to, lands) and stage.supported(to, lands + _rate() / 4)


## Everybody still racing or home, in race order: the finished by place, then by checkpoint,
## then by how far along the route they are. What the HUD's place and the announcer's leader
## read; on a client from the positions it draws. Watchers and an arena give an empty list.
func race_order() -> Array[StringName]:
	var order: Array[StringName] = []

	if stage == null or not stage.is_course():
		return order

	var route := stage.route()
	var keys := {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching:
			continue

		var key := 0.0

		if player.finished:
			key = 1.0e9 - float(player.place)
		else:
			var at := player.controller.state.position
			var index := _route_after(at) if not route.is_empty() else 0
			# How far along in metres (a fork counted at its shortest branch), and between the nearest
			# point and the next, so two runners at one point are told apart.
			var progress := stage.route_progress()
			var along := float(progress[index]) if index < progress.size() else 0.0
			var after := stage.route_next(index)
			if after < route.size():
				var here: Vector3 = (route[index] as Dictionary)["at"]
				var next: Vector3 = (route[after] as Dictionary)["at"]
				var leg := here.distance_to(next)
				var toward := clampf(1.0 - at.distance_to(next) / maxf(leg, 0.01), -1.0, 1.0)
				along += toward * (float(progress[after]) - float(progress[index]))
			key = float(player.checkpoint + 1) * 1.0e5 + along

		keys[id] = key
		order.append(id)

	order.sort_custom(func(a: StringName, b: StringName) -> bool:
		return float(keys[a]) > float(keys[b]) or (float(keys[a]) == float(keys[b]) and String(a) < String(b)))
	return order


## The route point a bot should head for from [param at]: the nearest one, then onward
## ([param branch] is the way it is going at a fork, when the nearest point is where one starts).
func _route_after(at: Vector3, branch: int = 0) -> int:
	var route := stage.route()
	var best := 0
	var best_distance := INF

	for index in range(route.size()):
		var distance := at.distance_to((route[index] as Dictionary)["at"])

		if distance < best_distance:
			best_distance = distance
			best = index

	# [b]Past the nearest point, the next one.[/b] A checkpoint just across a gap is nearer the
	# jump point behind it than the point ahead, and a stand-in put back there turned round and
	# jumped back across the gap, every time (Spin Cycle's second checkpoint).
	var after := stage.route_next(best, branch)
	if after < route.size():
		var here: Vector3 = (route[best] as Dictionary)["at"]
		var next: Vector3 = (route[after] as Dictionary)["at"]
		var ahead := Vector3(next.x - here.x, 0.0, next.z - here.z)
		if ahead.dot(Vector3(at.x - here.x, 0.0, at.z - here.z)) > 0.0:
			best = after

	return best


## The route point after [param index] for this stand-in, choosing a branch where a fork starts.
## `wo_bot_risk` takes the faster way: a chance in a hundred per fork and ATTEMPT, so a stand-in
## that went in off the risky branch may take the safe one from the checkpoint.
func _bot_next(player: WoPlayer, racing: Dictionary, index: int) -> int:
	var route := stage.route()

	if index < route.size() and int((route[index] as Dictionary).get("branch", 0)) != 0:
		racing["branch"] = int((route[index] as Dictionary)["branch"])
		return stage.route_next(index, int(racing["branch"]))

	var branches := stage.route_branches(index)

	if branches.is_empty():
		return stage.route_next(index, 0)

	if int(racing.get("fork_at", -1)) != index or int(racing.get("fork_falls", -1)) != player.falls:
		var risky := _bot_roll(&"bot_risk", player, index * 64 + player.falls) * 100.0 < racer.value("risk")
		var chosen := int((branches[0] as Dictionary)["branch"])
		for b: Dictionary in branches:
			if bool(b["risky"]) == risky:
				chosen = int(b["branch"])
				break
		racing["fork_at"] = index
		racing["fork_falls"] = player.falls
		racing["branch"] = chosen

	return stage.route_next(index, int(racing["branch"]))


## Whether the runner should stop and let an arm go by: a jump's landing (about 0.7 s on) is in
## its way and standing still for half a second is not. Hopping a sweeper's arm landed on it
## again, and a stand-in that did so fell on most attempts (First Splash).
func _bot_hold_for_landing(command: DotFpsCommand, at: Vector3, heading: Vector3, limits: Vector3) -> bool:
	var lands := false
	for ahead in [0.72, 0.85]:
		var where: Vector3 = at + heading * _cfg().run_speed * ahead
		if stage.knock(where, false, _tick + int(ahead * _rate()), limits) != Vector3.ZERO:
			lands = true
			break
	if not lands:
		return false
	for ahead in [0.0, 0.15, 0.3, 0.45]:
		if stage.knock(at, false, _tick + int(ahead * _rate()), limits) != Vector3.ZERO:
			return false
	command.move = Vector2.ZERO
	command.set_button(DotFpsCommand.BUTTON_WALK, false)
	return true


## Fallen onto an earlier leg of the course: the point being run for is overhead, so start
## again from the nearest one. Only well back and well below, as a climb's next point is above too.
func _bot_fell_back(player: WoPlayer, racing: Dictionary, index: int, point: Dictionary) -> bool:
	if int(_tick + player.entity_id) % 32 != 0 or player.controller.state.mode != DotFpsState.Mode.GROUND:
		return false
	if (point["at"] as Vector3).y - player.controller.state.position.y <= 2.0:
		return false
	var nearest := _route_after(player.controller.state.position, int(racing.get("branch", 0)))
	if nearest >= index - 1:
		return false
	_bot_route[player.player_id] = nearest
	return true
