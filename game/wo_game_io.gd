extends "wo_game_bot_run.gd"

## What a map's own logic does to people on a course: hurts, falls, teleports, pushes, uses and shots.

const DIED_FELL := &"fell"
const DIED_STRUCK := &"struck"

## How far a use key reaches on a course that runs its map's entities.
const IO_USE_REACH := 2.6

## Somebody fell in and was put back. Not a death: the course goes on.
signal player_fell(player_id: StringName, checkpoint: int)

## The last events an io world's map raised that nothing here plays (text, hints, scores), for
## `describe()` and the suites. Capped.
var io_events: Array = []

## What the map's own logic did to people, for the suites: teleports, pushes, hurts.
var io_log: Dictionary = {"teleports": 0, "pushes": 0, "hurts": 0, "uses": 0}

## Where the map teleported whom, in order: `{"body": WoPlayer, "to": Vector3}`. Capped.
var io_teleported: Array = []

var _io_bodies: Array = []

## player id -> `{DotMapHurt: true}`: the hurt volumes a respawned body stands in, which do not hurt it until it
## has left them. A map's anti-camp volume (switched on 30 s in around its spawn) would otherwise kill each
## respawn in the same place, forever.
var _hurt_grace: Dictionary = {}


## Whether [param player_id] may be damaged, eliminated or counted as across now: false while
## their client is behind its loading cover. True for anybody the gate does not know (bots,
## offline).
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


## Once a tick, after everybody moved: the map's entity logic and volumes see who is where.
func _step_io() -> void:
	if stage == null or stage.io == null or not authoritative:
		return

	_io_bodies.clear()

	if phase == Phase.COURSE:
		for id: StringName in players:
			var player: WoPlayer = players[id]

			if player.is_alive() and not player.watching and not player.finished:
				_io_bodies.append(io_body(player))

	_release_hurt_grace()
	stage.io.step(_tick, _io_bodies)


## The body a map's volumes and filters see for [param player]. On no Source team (0): a map's team filter then
## passes only what it names the other way round (Pauls' knife-round teleports are for terrorists, and sit on its
## start line); headless_io reports which filters turn a runner away.
func io_body(player: WoPlayer) -> Dictionary:
	var tunables := player.controller.tunables
	return {
		"id": String(player.player_id), "body": player, "position": player.controller.state.position,
		"height": tunables.stand_height if tunables != null else 1.8,
		"radius": tunables.radius if tunables != null else 0.35,
		"kind": "player", "name": String(player.player_id), "class": "player", "team": 0,
	}


## The grab key as "use" on a course that runs its map's entities: an edge, and the first mover
## the player's eyes meet within reach is pressed (a button, a door).
func _use_io() -> void:
	if stage == null or stage.io == null or not authoritative or phase != Phase.COURSE:
		return

	var space := get_world_3d().direct_space_state if get_world_3d() != null else null

	if space == null:
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]
		var pressed := player.wants_grab and not bool(player.get_meta(&"use_held", false))
		player.set_meta(&"use_held", player.wants_grab)

		if not pressed or not player.is_alive() or player.watching or player.finished:
			continue

		var eyes := player.eye_position()
		var query := PhysicsRayQueryParameters3D.create(eyes, eyes + player.aim_direction() * IO_USE_REACH)
		query.collide_with_areas = false
		query.exclude = [player.get_rid()]
		var hit := space.intersect_ray(query)

		if hit.is_empty():
			continue

		var mover := stage.io.mover_of((hit["collider"] as Object).get_instance_id())

		if mover != null:
			io_log["uses"] = int(io_log["uses"]) + 1
			var _used := stage.io.world.io.use(mover.index, String(id))


## Spawn protection from the hurt volumes round [param player]'s feet, for as long as it stays in them.
func _protect_from_hurts(player: WoPlayer) -> void:
	_hurt_grace.erase(player.player_id)

	if stage == null or stage.io == null or not authoritative:
		return

	var feet := player.controller.state.position
	var tall := player.controller.tunables.stand_height if player.controller.tunables != null else 1.8
	var held: Dictionary

	for node: DotMapVolumeNode in stage.io.world.volumes.nodes:
		if node.volume.kind == "hurt" and node.entity != null and node.volume.touches_column(feet, tall):
			held[node.entity] = true

	if not held.is_empty():
		_hurt_grace[player.player_id] = held


## Drops each protection whose body has left the volume it covered.
func _release_hurt_grace() -> void:
	if _hurt_grace.is_empty():
		return

	for id: StringName in _hurt_grace.keys():
		var player: WoPlayer = players.get(id)

		if player == null:
			_hurt_grace.erase(id)
			continue

		var feet := player.controller.state.position
		var tall := player.controller.tunables.stand_height if player.controller.tunables != null else 1.8
		var held: Dictionary = _hurt_grace[id]

		for node: DotMapVolumeNode in stage.io.world.volumes.nodes:
			if held.has(node.entity) and not node.volume.touches_column(feet, tall):
				held.erase(node.entity)

		if held.is_empty():
			_hurt_grace.erase(id)


func _io_damage(body: Variant, amount: float, _kind: String, attacker: Variant) -> void:
	var player := body as WoPlayer

	if player != null and _hurt_grace.has(player.player_id) and (_hurt_grace[player.player_id] as Dictionary).has(attacker):
		return

	if player == null or player.health == null or not authoritative or stage == null \
			or not stage.is_course() or phase != Phase.COURSE or player.finished or not player.is_alive() or amount <= 0.0:
		return

	io_log["hurts"] = int(io_log["hurts"]) + 1

	# A volume that kills is the water's rule, so a one-life course puts the body out and any
	# other sends it back to its checkpoint, whether or not health is on.
	if amount >= player.health.max_health:
		_fell(player)
		return

	var _charged := _hurt_on_course(player, amount, DIED_STRUCK, Vector3.ZERO)


func _io_move(body: Variant, motion: Variant) -> void:
	var player := body as WoPlayer

	if player == null or not authoritative or player.finished or not player.is_alive():
		return

	if motion is Transform3D:
		io_log["teleports"] = int(io_log["teleports"]) + 1
		io_teleported.append({"body": player, "to": (motion as Transform3D).origin})

		if io_teleported.size() > 64:
			io_teleported.pop_front()

		var heading := rad_to_deg((motion as Transform3D).basis.get_euler().y)
		player.place_at((motion as Transform3D).origin, heading)
		return

	if motion is Vector3:
		io_log["pushes"] = int(io_log["pushes"]) + 1
		var state := player.controller.state
		var push: Vector3 = motion
		state.velocity.x = push.x
		state.velocity.z = push.z

		if push.y > 0.1:
			state.velocity.y = push.y
			state.mode = DotFpsState.Mode.AIR


func _io_event(kind: String, data: Dictionary) -> void:
	io_events.append({"kind": kind, "data": data})

	if io_events.size() > 64:
		io_events.pop_front()


## A finale shot against an io course's own breakables, buttons and doors (dot-map's `DotMapWorld.shoot`):
## each pellet's ray, no further than where the combat stopped it, so a player in front shields the panel.
func _shoot_io(shooter: WoPlayer, shot: DotShot) -> void:
	if not authoritative or stage == null or stage.io == null or stage.io.world == null or physics == null or shooter == null:
		return
	var space := stage.get_world_3d().direct_space_state
	var mask := physics.layer_mask(&"world")
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for i in range(directions.size()):
		var far: Vector3 = shot.impacts[i] if i < shot.impacts.size() else shot.origin + (directions[i] as Vector3) * shot.max_range
		var limit := shot.origin.distance_to(far)
		var index := stage.io.world.shoot(space, shot.origin, shot.origin + (directions[i] as Vector3) * shot.max_range, shot.damage,
				io_body(shooter), mask, limit)
		if index >= 0:
			io_log["shots"] = int(io_log.get("shots", 0)) + 1


## Takes [param amount] of a player's health on the course once the shared checks pass: authority, a course in play,
## health on, alive, not yet across. The health they had BEFORE rides in the damage's context, because the death is
## decided from it ([method decide_death]). True when charged.
func _hurt_on_course(player: WoPlayer, amount: float, why: StringName, direction: Vector3) -> bool:
	if not authoritative or not config.health_enabled or amount <= 0.0 or stage == null \
			or not stage.is_course() or phase != Phase.COURSE or combat == null \
			or player.health == null or not player.is_alive() or player.finished:
		return false

	var hurt := DotDamage.make(0, player.entity_id, amount, null)
	hurt.point = player.controller.state.position
	hurt.direction = direction
	hurt.tick = _tick
	hurt.context = {"why": why, "health_before": player.health.health}
	var _applied := combat.apply_damage(hurt)
	return true


func _fell(player: WoPlayer) -> void:
	if stage.is_arena():
		if player.watching:
			var spot := stage.gallery_spot(0)
			player.place_at(spot[0], spot[1])
			return

		if player.is_alive() and combat != null:
			var damage := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
			damage.point = player.controller.state.position
			damage.direction = Vector3.DOWN
			damage.tick = _tick
			damage.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(damage)
		return

	# On a course a fall costs time only: back to the last checkpoint, the start, or (if finished) the lounge. A seat
	# behind its loading cover is put back but the fall is not counted and the checkpoint kept: it did not choose to
	# be there.
	if not can_be_harmed(player.player_id):
		var home := stage.respawn_point(player.checkpoint, 0)
		player.place_at(home[0], home[1])
		return

	# Instant death: the water is fatal and the round is over for them. Through the damage
	# path, so the body falls, the kill is counted and `_on_player_died` seats them in the lounge.
	if config.instant_death and authoritative and not player.finished and combat != null \
			and player.health != null and player.is_alive():
		player.remove_meta(&"air_peak")
		var lethal := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
		lethal.point = player.controller.state.position
		lethal.direction = Vector3.DOWN
		lethal.tick = _tick
		lethal.context = {"why": DIED_FELL}
		var _killed := combat.apply_damage(lethal)
		return

	player.falls += 1
	player.remove_meta(&"air_peak")

	if player.finished:
		var spot := stage.lounge_spot(player.place)
		player.place_at(spot[0], spot[1])
	else:
		var spot := stage.respawn_point(player.checkpoint, player.falls % 5)
		player.place_at(spot[0], spot[1])
		_protect_from_hurts(player)

		# Back at the checkpoint healed, as crossing it heals: the knock that threw you in already cost the time, and
		# on long courses the health cost added up until stand-ins were knocked OUT of the round. Knocks along a deck
		# that do not end in the water still add up, so `course_deaths_eliminate` means something.
		if config.checkpoint_heals and authoritative and player.health != null and player.is_alive():
			var _healed := player.health.heal(player.health.max_health)

	if player.is_bot:
		_bot_route[player.player_id] = _route_after(player.controller.state.position)
		var put_on := int((stage.route()[_bot_route[player.player_id]] as Dictionary).get("branch", 0)) \
			if int(_bot_route[player.player_id]) < stage.route().size() else 0
		if put_on != 0:
			_racer_of(player)["branch"] = put_on
		# Shaking it off: a person back on the deck looks round before running again.
		var racing := _racer_of(player)
		racing["pause_until"] = _tick + int(racer.value("recover") * float(racing["factor"]) * float(tick_rate))
		racing["plan_index"] = -1
		racing["backed_up"] = -1
		racing["backup_until"] = 0

	if progress != null:
		progress.on_fell(player.player_id)

	player_fell.emit(player.player_id, player.checkpoint)
