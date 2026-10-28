extends "wo_game_state.gd"
## A stand-in's racer state and how it fights and aims in a final death.

## The node overrides these two, so this layer reads its exports without declaring them.
func _cfg() -> WoConfig:
	return null


func _rate() -> int:
	return 1


## Bots: player id -> the route point they are heading for.
var _bot_route: Dictionary = {}

var _bot_wait: Dictionary = {}

## Bots: player id -> how this stand-in is racing this round: the plan for the route point it
## is heading for (fumble, early or late, rash), when a window was seen, a pause after a fall,
## its own skill factor, and its dot-bot [DotBotAim] for a final death. See [method _racer_of].
var _bot_racer: Dictionary = {}

## How the stand-ins race: mistake rates by dot-bot's `bot_difficulty`. See [WoRacer].
var racer: WoRacer = null

## Bots: player id -> ticks spent getting up to speed on a top before jumping off it.
var _bot_runup: Dictionary = {}

## Stand-ins' navigation of the current io course, baked on first use.
var _io_bot: WoIoBot = null

## Bots: player id -> `[position, tick]` a second ago, for [method _bot_unstick].
var _bot_stuck: Dictionary = {}


## How [param player], a stand-in, is racing this round; made on first use.
## `factor` is its share of the preset's mistakes, drawn per bot and round; `plan_*` what it
## gets wrong at its next route point, drawn per point and ATTEMPT so a fumble is not permanent.
func _racer_of(player: WoPlayer) -> Dictionary:
	var held: Variant = _bot_racer.get(player.player_id)

	if held != null:
		return held

	var draw := random.stream_for(&"bot_skill", round_number * 8192 + int(player.entity_id % 8192))
	var racing := {
		"factor": WoRacer.factor(racer.value("variety"), draw.next_range_f(-1.0, 1.0)),
		"plan_index": -1,
		"plan_falls": -1,
		"fumble": false,
		"late": 0,
		"early": 0.0,
		"rash": false,
		"window": -1,
		"pause_until": 0,
		"aim": DotBotAim.new(int(player.entity_id), DotBotSettings.of(self)),
	}
	_bot_racer[player.player_id] = racing
	return racing


## A draw in [0, 1) for one decision of one stand-in: seeded from the round, the bot and
## [param salt], so a replayed round makes the same mistakes and two bots make different ones.
func _bot_roll(name: StringName, player: WoPlayer, salt: int) -> float:
	var subject := (round_number * 4099 + int(player.entity_id % 4096)) * 65536 + (salt & 0xffff)
	return random.stream_for(name, subject).next_range_f(0.0, 1.0)


func _bot_fight(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var enemy := _nearest_enemy(player)

	if player.weapons != null and enemy != null:
		_aim_bot(player, command, enemy)
		var distance := enemy.controller.state.position.distance_to(at)

		if distance > 7.0:
			command.move = Vector2(0.0, 1.0)

		return

	# Nothing in hand: the nearest weapon, then the nearest prop, then walk at somebody.
	var target := Vector3.INF
	var best := INF

	for pickup_id: int in pickups:
		var spot: Vector3 = (pickups[pickup_id] as Dictionary)["at"]
		var distance := spot.distance_to(at)

		if distance < best:
			best = distance
			target = spot

	if player.grab != null and player.grab.is_carrying() and enemy != null:
		_aim_bot(player, command, enemy)
		# Thrown once the aim is on (dot-bot's trigger) and they are near enough to hit.
		command.set_button(DotFpsCommand.BUTTON_USER_0, command.is_pressed(DotFpsCommand.BUTTON_USER_0)
			and enemy.controller.state.position.distance_to(at) < 9.0)
		command.move = Vector2(0.0, 1.0)
		player.wants_grab = false
		return

	if target == Vector3.INF:
		for prop in props.all_props():
			var body := prop.body()

			if body == null:
				continue

			var distance := body.global_position.distance_to(at)

			if distance < best:
				best = distance
				target = body.global_position

		if target != Vector3.INF and best < GRAB_REACH - 0.6:
			var look := target - player.eye_position()
			command.yaw = rad_to_deg(atan2(-look.x, -look.z))
			command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
			player.wants_grab = not player.wants_grab
			return

	if target == Vector3.INF and enemy != null:
		target = enemy.controller.state.position

	if target != Vector3.INF:
		var toward := target - at
		toward.y = 0.0
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)


func _nearest_enemy(player: WoPlayer) -> WoPlayer:
	var best: WoPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: WoPlayer = players[id]

		if other == player or not other.is_alive() or other.watching:
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(player.controller.state.position)

		if distance < closest:
			closest = distance
			best = other

	return best


## Aims a stand-in at [param target] and fires when dot-bot's [DotBotAim] says: turn rate,
## first-shot error and reaction time come from `bot_difficulty`, the same one as for the race.
func _aim_bot(player: WoPlayer, command: DotFpsCommand, target: WoPlayer) -> void:
	var aim: DotBotAim = _racer_of(player)["aim"]
	var eye := player.eye_position()
	var point := target.eye_position() - Vector3(0.0, 0.35, 0.0)

	if eye.distance_to(point) < 0.01:
		return

	var now := _bot_now()
	var _new := aim.engage(int(target.entity_id), eye, point, now)
	var view := aim.track(eye, point, target.controller.state.velocity, now, (1.0 / float(maxi(_rate(), 1))))
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(now, eye.distance_to(point))

	if fire:
		aim.note_shot(eye, point, now)

	command.set_button(DotFpsCommand.BUTTON_USER_0, fire)


## The game clock in seconds, for the stand-ins' aim.
func _bot_now() -> float:
	return float(_tick) / float(maxi(_rate(), 1))
