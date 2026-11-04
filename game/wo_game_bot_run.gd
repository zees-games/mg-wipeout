extends "wo_game_bot_race.gd"
## How a stand-in runs a course: the route walk, tile waits, windows and take-offs.


func _bot_run(player: WoPlayer, command: DotFpsCommand) -> void:
	var route := stage.route()

	if route.is_empty():
		_bot_run_io(player, command)
		return

	var racing := _racer_of(player)

	# Back on the deck after a fall, and not running yet.
	if _tick < int(racing["pause_until"]):
		command.move = Vector2.ZERO
		return

	var index := mini(int(_bot_route.get(player.player_id, 0)), route.size() - 1)
	var point: Dictionary = route[index]
	var next_index := _bot_next(player, racing, index)
	var next: Dictionary = route[next_index] if next_index < route.size() else {}
	var before_index := stage.route_prev(index, int(racing.get("branch", 0)))
	var before: Vector3 = (route[before_index] as Dictionary)["at"] if before_index >= 0 else player.controller.state.position

	if _bot_fell_back(player, racing, index, point):
		return

	var at := player.controller.state.position
	var grounded := player.controller.state.mode == DotFpsState.Mode.GROUND
	var ground_id := player.controller.state.ground_id
	# On a tile of a grid of trapdoors (not merely near one): see [method _bot_tile_column].
	var on_tile := grounded and not stage.tile_under(ground_id).is_empty()

	# A column of tiles claimed for this grid, not the middle one (see [method _bot_tile_column]).
	if bool(point["board"]) and not bool(point["ride"]):
		var shift := _bot_tile_column(player, racing, point, on_tile)
		if shift != Vector3.ZERO:
			point = point.duplicate()
			point["at"] = (point["at"] as Vector3) + shift

	var toward: Vector3 = (point["at"] as Vector3) - at
	toward.y = 0.0
	_bot_plan(player, racing, index)

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	if _bot_run_air(player, command, point, next_index, before, before_index, toward, grounded):
		return

	# Something to land on: nothing is started until it will be there, asked every tick so a bot riding a mover
	# stays on it until the far side is in reach.
	if bool(point["board"]) and grounded:
		point = _bot_tile_wait(player, command, racing, point, route[index]["at"], before, on_tile)
		if point.is_empty():
			return

	if _bot_run_stops(player, command, racing, point, next, toward, on_tile):
		return

	var running := command.move != Vector2.ZERO
	# Landed on a top, the yaw is still at its point, behind the runner: the hop looks the way the run will go.
	var hop_yaw := NAN
	if bool(point["jump"]) and float(point["reach"]) > 0.6 and grounded and not next.is_empty() and toward.length() < 1.5:
		var onward := (next["at"] as Vector3) - at
		hop_yaw = rad_to_deg(atan2(-onward.x, -onward.z))
	_bot_hop(player, command, hop_yaw)

	# Stopped to let an arm go by, it does not take off (a braking tick with no wish jumped into the gap).
	if running and command.move == Vector2.ZERO and bool(point["jump"]):
		return

	if _bot_hop_is_jump(player, point, next, next_index, toward, at, grounded, command):
		return

	_bot_run_reach(player, command, racing, point, next, next_index, index, toward, at, grounded, ground_id, on_tile)


## The second half of [method _bot_run]: unstick, board the edge, back up, take off, then move on along the route.
func _bot_run_reach(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, point: Dictionary, next: Dictionary,
		next_index: int, index: int, toward: Vector3, at: Vector3, grounded: bool, ground_id: int, on_tile: bool) -> void:
	_bot_unstick(player, command)

	if bool(point["board"]) and grounded:
		_bot_board_edge(player, command, point, at, ground_id, on_tile)

	# Backing up for a run-up (see the jump below), straight back along the line the jump will take.
	if _tick < int(racing.get("backup_until", 0)) and grounded:
		if not next.is_empty():
			var line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
			line.y = 0.0
			if line.length() > 0.01:
				command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.move = Vector2(0.0, -1.0)
		return

	if bool(racing.get("late_going", false)):
		_bot_late_takeoff(player, command, racing, next_index, grounded)
		return

	# An early take-off is a jump point reached further back than it is.
	var reach := float(point["reach"]) + (float(racing["early"]) if bool(point["jump"]) else 0.0)

	# A top landed on past its point is reached: landing a little past is the aim (see [method _bot_land_on]).
	if bool(point["jump"]) and float(point["reach"]) > 0.6 and grounded and not next.is_empty():
		var line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
		line.y = 0.0
		if line.length() > 0.01 and -toward.dot(line.normalized()) > 0.0 and toward.length() < 2.2:
			reach = maxf(reach, toward.length() + 0.01)

	# Somebody is on the top the jump lands on: wait a couple of metres back (two seconds at most), so there is a run.
	if bool(point["jump"]) and float(point["reach"]) <= 0.6 and grounded and toward.length() < 3.0 \
			and not next.is_empty() and _top_taken(player, next):
		var held := int(racing.get("held", 0))
		if held < _rate() * 2:
			racing["held"] = held + 1
			command.move = Vector2(0.0, -0.7) if toward.length() < 2.0 else Vector2.ZERO
			return
	elif bool(point["jump"]):
		racing["held"] = 0

	if toward.length() > reach:
		return

	if bool(point["wait"]) and not next.is_empty() and not bool(racing["rash"]) \
			and _bot_window_holds(player, command, racing, point, at, index):
		return

	_bot_wait.erase(player.player_id)

	# Nor is something to board passed in the air: the second row would become the target.
	if bool(point["board"]) and not grounded:
		return

	# A jump point passed in the air is not passed: it is where the NEXT jump starts. Held until on its feet.
	if bool(point["jump"]) and not _bot_takeoff(player, command, racing, point, next, toward, index):
		return

	_bot_route[player.player_id] = next_index



## Heading for something to land on, the jump is at whatever edge the bot reaches first, which on a moving floor
## no route point names. A gap a stride crosses is stepped, not jumped.
func _bot_board_edge(player: WoPlayer, command: DotFpsCommand, point: Dictionary, at: Vector3, ground_id: int,
		on_tile: bool) -> void:
	var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))
	# From a deck onto tiles, the jump is put off until the runner is nearly at the edge (a walk's jump is two metres).
	var lead := 0.35 if not on_tile and not stage.tile_cell(point["at"]).is_empty() else 0.7
	var ahead := at + heading * lead + Vector3(0.0, 0.1, 0.0)

	# Tile to tile is a step, never a jump. A tile ahead that is down is waited for, unless the one underfoot is going.
	if on_tile and not stage.tile_cell(ahead).is_empty():
		if not stage.supported(ahead, _tick) and not stage.tile_dropping(ground_id, at, _tick):
			command.move = Vector2.ZERO
	elif not stage.supported(ahead, _tick) \
			and not stage.supported(at + heading * 1.6 + Vector3(0.0, 0.1, 0.0), _tick):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## Waiting on a deck or a tile for the thing to board. Returns the point to go on with (another column's, perhaps),
## or an empty one when the tick is spent.
func _bot_tile_wait(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, point: Dictionary, original: Vector3,
		before: Vector3, on_tile: bool) -> Dictionary:
	var at := player.controller.state.position
	var ground_id := player.controller.state.ground_id
	var waited := int(_bot_wait.get(player.player_id, 0))

	# Six seconds at the most: a window that never comes is a course to fix, not to hide.
	var cell := stage.tile_cell(point["at"])
	var line: Vector3 = (point["at"] as Vector3) - before
	var from_deck := not cell.is_empty() and not on_tile
	# Lined up on its column before it goes, from a deck: slantwise, the jump came down short of the first row.
	var across := stage.tile_column_shift(int(cell["piece"]), at, int(racing.get("tile_col", int(cell["col"])))) \
		if from_deck else Vector3.ZERO
	var may := across.length() <= TILE_LINED_UP and _bot_may_board(player, point, line)

	# Rash (`wo_bot_rash`): off the deck onto the tiles without waiting for the column to be clear.
	if from_deck and not may and across.length() <= TILE_LINED_UP and bool(racing["rash"]) \
			and stage.supported(point["at"], _tick):
		may = true

	if waited < _rate() * (6 if int(point["span"]) <= 1 else 24) and not may:
		# Another column, from the deck only, once its own has kept it waiting: a person watches the column in
		# front and takes the next if it opens first, timed from where they will be after stepping across; never
		# across a row once on the tiles (walking over tiles as they drop made a field fall half as often again).
		if from_deck and waited >= int(TILE_PATIENCE * float(_rate())):
			var piece := int(cell["piece"])
			var walk := _cfg().run_speed * _cfg().walk_speed_scale
			var claims := _tile_claims(player, piece)
			var own := int(racing.get("tile_col", -1))
			var crowded := waited >= int(TILE_PATIENCE * 2.0 * float(_rate()))
			for col in range(claims.size()):
				# Not into a column more of the field has claimed, until it has waited twice as long.
				if col == own or (not crowded and own >= 0 and claims[col] > claims[own]):
					continue
				var step_across := stage.tile_column_shift(piece, at, col)
				var later := _tick + int((step_across.length() / walk + _cfg().bot_tile_start_seconds) * float(_rate()))
				var there := original + stage.tile_column_shift(piece, original, col)
				if stage.tile_crossing_clear(at + step_across, there, later, walk, _cfg().run_speed,
						_cfg().bot_tile_start_seconds, line):
					racing["tile_col"] = col
					point = point.duplicate()
					point["at"] = there
					across = step_across
					break

		# Standing on a tile that is going, anywhere is better than down with it, but only if the next one is there.
		if not (stage.tile_dropping(ground_id, at, _tick) and stage.supported(point["at"], _tick)):
			_bot_wait[player.player_id] = waited + 1
			command.move = Vector2.ZERO
			# Waiting on the deck, far enough back from the edge to be walking when it jumps (a standstill jump
			# lands in the gap before the first row), and lined up on its column.
			if from_deck:
				var forward := line.normalized() if line.length() > 0.05 else Vector3.ZERO
				forward.y = 0.0
				if not stage.supported(at + forward * 1.3 + Vector3(0.0, 0.1, 0.0), _tick):
					command.yaw = rad_to_deg(atan2(-forward.x, -forward.z))
					command.move = Vector2(0.0, -1.0)
					command.set_button(DotFpsCommand.BUTTON_WALK, true)
				elif across.length() > TILE_LINED_UP * 0.5:
					command.yaw = rad_to_deg(atan2(-across.x, -across.z))
					command.move = Vector2(0.0, 1.0)
					command.set_button(DotFpsCommand.BUTTON_WALK, true)
			return {}
	return point


## A late take-off under way: running on the way it was going (past the point, which would otherwise turn it
## round), then the jump, whether or not there is still ground under it.
func _bot_late_takeoff(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, next_index: int, grounded: bool) -> void:
	command.yaw = float(racing["late_yaw"])
	command.move = Vector2(0.0, 1.0)
	if int(racing["late"]) > 0:
		racing["late"] = int(racing["late"]) - 1
		racing["late_going"] = true
		racing["late_yaw"] = command.yaw
		return
	racing["late_going"] = false
	if grounded and not bool(racing["fumble"]):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
	_bot_route[player.player_id] = next_index


## Waiting at a point for a window. The window is SEEN, then gone for a reaction later (dot-bot's `bot_reaction`):
## a person does not set off on the tick a ram starts home. True while the bot still holds.
func _bot_window_holds(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, point: Dictionary, at: Vector3,
		index: int) -> bool:
	var waited := int(_bot_wait.get(player.player_id, 0))

	# Committed once seen, so a slow reaction is a late start, never a second wait.
	if int(racing["window"]) < 0 and waited < _rate() * (6 if int(point["span"]) <= 1 else 24) \
			and not _span_clear(at, index, int(point["span"])):
		_bot_wait[player.player_id] = waited + 1
		command.move = Vector2.ZERO
		command.set_button(DotFpsCommand.BUTTON_JUMP, false)
		return true

	if int(racing["window"]) < 0:
		racing["window"] = _tick

	var react := int(racer.reaction() * float(racing["factor"]) * float(_rate()))
	if _tick - int(racing["window"]) < react:
		command.move = Vector2.ZERO
		command.set_button(DotFpsCommand.BUTTON_JUMP, false)
		return true
	return false


## The take-off at a jump point: face, run up, back up, late or fumbled. False when the tick is spent, true when
## the bot has jumped (or is done) and the route moves on.
func _bot_takeoff(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, point: Dictionary, next: Dictionary,
		toward: Vector3, index: int) -> bool:
	var at := player.controller.state.position
	var grounded := player.controller.state.mode == DotFpsState.Mode.GROUND
	if not grounded:
		racing["grounded_for"] = 0
		return false

	# Not on the tick of landing: until the world has stepped once with the feet down the velocity is still the
	# jump's, so the run-up let the next jump go at once, short.
	racing["grounded_for"] = int(racing.get("grounded_for", 0)) + 1
	if int(racing["grounded_for"]) < 2 and float(point["reach"]) > 0.6:
		return false

	_bot_takeoff_aim(player, command, point, next, toward, at)

	if _bot_takeoff_runup(player, command, point, next, toward, at):
		return false

	var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	# Too slow at an edge, back up for a run at it; a person takes three steps back. Only at an edge (a narrow
	# reach), never on a top, where stepping back is stepping off. Also when going the wrong way: a runner that
	# hopped an arm and landed beside an edge ran back along it and jumped sideways off it.
	var squint := 0.0
	if not next.is_empty() and flat_speed > 0.5:
		var jump_line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
		jump_line.y = 0.0
		if jump_line.length() > 0.01:
			squint = rad_to_deg(Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).angle_to(jump_line))
	# Never on a turntable: the disc carries the runner sideways, which reads as a squint, and backing up under a
	# spinner's arms is standing in their way. A seesaw still wants the run-up, or the next plank is jumped
	# short.
	if (flat_speed < _cfg().run_speed * 0.6 or squint > 30.0) and float(point["reach"]) <= 0.6 \
			and int(racing.get("backed_up", -1)) != index \
			and stage.ground_kind(player.controller.state.ground_id) != "turntable":
		racing["backed_up"] = index
		racing["backup_until"] = _tick + int(0.4 * float(_rate()))

	if _tick < int(racing.get("backup_until", 0)):
		command.move = Vector2(0.0, -1.0)
		return false

	# Late: still running, for as many ticks as this take-off is late by. Off an edge
	# point that is a step past the edge, and the water.
	if int(racing["late"]) > 0:
		racing["late"] = int(racing["late"]) - 1
		return false

	# A fumble is a jump not taken, decided once per bot, point and attempt.
	if not bool(racing["fumble"]):
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
	return true


## Where a take-off faces: the next top, or onward past an edge, braking off any excess speed.
func _bot_takeoff_aim(player: WoPlayer, command: DotFpsCommand, point: Dictionary, next: Dictionary, toward: Vector3,
		at: Vector3) -> void:
	# On a top, face the next one, never the point: a landing is aimed a little past the point (see [method
	# _bot_land_on]), so turning to it is running backwards and the take-off slows to two metres a second. Past
	# the point and too slow for the jump, the yaw is left to the run-up below.
	if float(point["reach"]) > 0.6 and not next.is_empty():
		var facing: Vector3 = (next["at"] as Vector3) - at
		facing.y = 0.0
		var beyond := -toward.dot(facing.normalized()) if facing.length() > 0.1 else 0.0
		var flat_now := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
		var going := flat_now.dot(facing.normalized()) if facing.length() > 0.1 else 0.0
		var need := _jump_speed_needed(at, next["at"])
		if facing.length() > 0.1 and (beyond < 0.2 or going >= need):
			command.yaw = rad_to_deg(atan2(-facing.x, -facing.z))
		# Faster than the jump needs: the excess braked off on the take-off, never a wish on to full speed, or
		# the jump is braked to a standstill just past the next top and the run-up goes down its far side, where
		# the motor refuses a jump. Never on a log turning toward the runner, which takes the speed a jump needs.
		if going >= need * TAKEOFF_SPARE and facing.length() > 0.1 \
				and stage.carry(player.controller.state.ground_id, at, _tick).dot(facing) >= 0.0:
			command.move = Vector2(0.0, -clampf((going - need * TAKEOFF_SPARE) / _cfg().bot_ground_brake, 0.0, 1.0))
	elif not next.is_empty():
		# An edge's jump point already behind: the jump goes on, not back. Only once past it and still going on;
		# before the point the run-up is left straight, and turning for a runner going back made easy finish
		# behind medium.
		var jump_line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
		jump_line.y = 0.0
		var onward := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).dot(jump_line)
		if jump_line.length() > 0.1 and toward.dot(jump_line) < 0.0 and onward > 0.0:
			command.yaw = rad_to_deg(atan2(-jump_line.x, -jump_line.z))

	# Toward where the jump is GOING, on a point marked `onward`: a bot that landed past a pad's centre hopped
	# backwards and wide into the water. Opt-in per point, because a gap's edge point is routinely passed before
	# the take-off and turning there spoils a straight run-up. Before the run-up below.
	if bool(point.get("onward", false)) and not next.is_empty():
		var onward: Vector3 = (next["at"] as Vector3) - at
		onward.y = 0.0
		if onward.length() > 0.1:
			command.yaw = rad_to_deg(atan2(-onward.x, -onward.z))


## Up to speed before the jump. True while the bot is still running up (the tick is spent).
func _bot_takeoff_runup(player: WoPlayer, command: DotFpsCommand, point: Dictionary, next: Dictionary, toward: Vector3,
		at: Vector3) -> bool:
	# Up to speed first, for a few ticks: a landing on a ball or a turning log costs speed,
	# and a jump taken at four metres a second off a log falls short of the next one — a
	# jump is cut short in the air, never stretched.
	var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
	var spent := int(_bot_runup.get(player.player_id, 0))

	# Longer on a top that fights back: a log rolling toward the runner took the landing down to one and a half
	# metres a second, a metre short at the jump. Never once past the point, where the top is going away under
	# the feet.
	var onward_line := (next["at"] as Vector3) - (point["at"] as Vector3) if not next.is_empty() else Vector3.ZERO
	onward_line.y = 0.0
	var past := -toward.dot(onward_line.normalized()) if onward_line.length() > 0.01 else 0.0
	var top := float(point["reach"]) > 0.6

	if top and not next.is_empty():
		# On a top, run until the jump will make the next one, or the top runs out. What the next jump needs is
		# arithmetic (distance over air time, to the next top's height); what the top allows is its reach past
		# the point. A fixed three ticks jumped at whatever the landing left.
		var needed := _jump_speed_needed(at, next["at"])
		# The speed TOWARD the next top: a runner going sideways at six metres a second
		# is not going to make it.
		var to_next: Vector3 = (next["at"] as Vector3) - at
		to_next.y = 0.0
		var closing := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).dot(to_next.normalized()) \
			if to_next.length() > 0.01 else flat_speed
		# And not much sideways: a pad landed on a metre and a half off its middle had the
		# runner going across it, and the jump went across too (Spin Cycle's second pad).
		var across := 0.0
		if to_next.length() > 0.01:
			var flat_velocity := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
			across = (flat_velocity - to_next.normalized() * closing).length()
		if (closing < needed * 1.05 or across > 1.5) and past < float(point["reach"]) + 0.6 and spent < RUNUP_TICKS * 3:
			_bot_runup[player.player_id] = spent + 1
			var ahead: Vector3 = (next["at"] as Vector3) - at
			ahead.y = 0.0
			if ahead.length() > 0.1:
				command.yaw = rad_to_deg(atan2(-ahead.x, -ahead.z))
			return true
	elif flat_speed < _cfg().run_speed * 0.85 and spent < 3:
		_bot_runup[player.player_id] = spent + 1
		return true
	_bot_runup.erase(player.player_id)
	return false


## The air and mover cases of [method _bot_run]. True when the tick is done.
func _bot_run_air(player: WoPlayer, command: DotFpsCommand, point: Dictionary, next_index: int, before: Vector3,
		before_index: int, toward: Vector3, grounded: bool) -> bool:
	# In the air, aimed at a top (or something to board) to land on: brake if the jump would carry past it.
	if not grounded and (bool(point["jump"]) or bool(point.get("bounce", false)) or bool(point["board"])):
		_bot_land_on(player, command, point["at"], (point["at"] as Vector3) - before, float(point["reach"]) > 0.6)
	elif not grounded and before_index >= 0 and _bot_save_landing(player, command, point["at"],
			(point["at"] as Vector3) - before):
		return true

	# A bouncer is ground for one tick: its point is reached by coming down over it, or past it on the way up.
	var over_it := toward.length() < 2.5 and toward.dot((point["at"] as Vector3) - before) < 0.0
	if bool(point.get("bounce", false)) and (toward.length() < float(point["reach"]) or over_it) \
			and player.controller.state.velocity.y > 0.0 and not grounded:
		_bot_route[player.player_id] = next_index
		return true

	# A point ON a mover is reached by standing on it, wherever it has got to, not by chasing its start.
	if bool(point["ride"]) and grounded and stage.carries(player.controller.state.ground_id):
		_bot_wait.erase(player.player_id)
		_bot_route[player.player_id] = next_index
		command.move = Vector2.ZERO
		return true
	return false


## Walk, queue and window rules of [method _bot_run]. True when the tick is done.
func _bot_run_stops(player: WoPlayer, command: DotFpsCommand, racing: Dictionary, point: Dictionary, next: Dictionary,
		toward: Vector3, on_tile: bool) -> bool:
	# Walked into, for its last metre and a half, a point it may have to stop at (a run slides a metre past, off the
	# edge beside a mover). Never on the tiles (see [method _bot_may_board]).
	var stops := bool(point["wait"]) or (not next.is_empty() and bool(next["board"]) and not on_tile)

	# Only on the way IN: a window timed at a run is missed by a bot that walks through it.
	if bool(point["walk"]) or (stops and toward.length() < 1.6 and toward.length() > float(point["reach"])):
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	# Onto a tile at a walk (a running jump overshoots a row of two metres), once on them at a run.
	if bool(point["board"]) and not bool(point["ride"]) and not on_tile \
			and not stage.tile_columns(point["at"]).is_empty():
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	# Two seconds at the most behind anybody: whoever is in front may be stuck themselves.
	if bool(point["jump"]) and toward.length() < 4.0 and int(racing.get("queued", 0)) < _rate() * 2 \
			and _bot_queue(player, command, point["at"]):
		racing["queued"] = int(racing.get("queued", 0)) + 1
		return true
	return false


## True when the hop under way carries past the jump point ahead, which makes it the jump: the route moves on.
func _bot_hop_is_jump(player: WoPlayer, point: Dictionary, next: Dictionary, next_index: int, toward: Vector3,
		at: Vector3, grounded: bool, command: DotFpsCommand) -> bool:
	# A hop that carries past the jump point ahead is the jump: the route moves on and the landing is steered onto
	# what is beyond the gap.
	if grounded and command.is_pressed(DotFpsCommand.BUTTON_JUMP) and bool(point["jump"]) \
			and float(point["reach"]) <= 0.6 and not next.is_empty():
		var airtime := 2.0 * sqrt(2.0 * _cfg().gravity * _cfg().jump_height) / _cfg().gravity
		var flat := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
		if flat.length() * airtime > toward.length() and stage.supported(at + flat * airtime + Vector3(0.0, 0.1, 0.0),
				_tick + int(airtime * float(_rate()))):
			_bot_route[player.player_id] = next_index
			return true
	return false
