extends "wo_client_flashlight.gd"

## What the client plays and shows for what the world says happened: stages, phases, deaths, falls and breaks.

## How long the same stage is not introduced again. See [method _on_stage].
const INTRODUCE_AGAIN_MSEC := 5000


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


## [param who]'s body falls the way the server picked ([member WoPlayer.death]), copied from the figure this client
## draws; the figure stays hidden while they are dead ([method WoPlayer.present_body]). No figure, nothing.
func _fall(who: WoPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The level is on `world`; a body lands on it and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)


func _on_phase(phase: int) -> void:
	_hear_phase(phase)

	match phase:
		WoGame.Phase.COUNTDOWN:
			hud.shout("GET READY", 2.0)
			_disarm_locally()
		WoGame.Phase.COURSE:
			hud.shout("GO", 1.4)
			if announcer != null:
				announcer.on_go()

			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
		WoGame.Phase.HANDOVER:
			if player != null and player.watching:
				hud.shout("THE FINAL DEATH — you are watching", 3.0)
			else:
				hud.shout("THE FINAL DEATH — grab something", 3.0)
		WoGame.Phase.FINALE:
			hud.shout("LAST ONE STANDING", 1.8)
			if announcer != null:
				announcer.on_finale()


## A new course or arena. The name, once, big; the camera re-placed, because the player was
## just moved somewhere that may be eighty metres away.
## Hands the course's converted map (an `io` world piece) to the platform's map culling; off unless `vis_mode` is set.
func _cull_world() -> void:
	platform.detach_visibility()
	var io: Object = game.stage.io if game.stage != null else null
	var world: DotMapWorld = io.world if io != null else null
	if world != null and world.visual != null and world.visual.is_inside_tree():
		var _culled := platform.attach_visibility(world.mesh, world.visual)


func _on_stage(stage_id: StringName, is_arena: bool) -> void:
	if ragdolls != null:
		# A body from before would lie on a floor that has been rebuilt or reset.
		ragdolls.clear()
	_clear_pickups()

	# A new course's clock is not the last one's, so its first frame is not a sweep of every arm.
	if audio != null:
		audio.reset_machinery()

	if game.stage == null:
		return

	if audio != null:
		audio.on_course(stage_id, game.stage.doc)

	# The new stage's toys are heard: a beach ball's bounce, one knocked off an arena's edge.
	if game.stage.toys != null and not game.stage.toys.sound.is_connected(_toy_sound):
		var _toys := game.stage.toys.sound.connect(_toy_sound)

	var name_of := str(game.stage.doc.get("name", ""))
	var blurb := str(game.stage.doc.get("blurb", ""))

	# Once, though the world is rebuilt twice for it: the warmup lays round one out and `WoGame.start` builds the
	# same again, so the name was shouted twice at boot. By time rather than round: a one-course server should
	# introduce it again next round.
	var now := Time.get_ticks_msec()
	if stage_id == _introduced and now - _introduced_msec < INTRODUCE_AGAIN_MSEC:
		return
	_introduced = stage_id
	_introduced_msec = now

	if not is_arena:
		hud.shout(name_of, 3.0)

	if announcer != null:
		announcer.on_stage(name_of, is_arena)

	if chat != null and name_of != "":
		var author := str(game.stage.doc.get("author", ""))
		chat.say_locally("%s%s" % [name_of, " by %s" % author if author != "" else ""], Color(0.80, 0.90, 1.0))
	if blurb_label != null and not is_arena:
		blurb_label.show_blurb(blurb)


## Somebody fell in, crossed a checkpoint, or finished. What the feed and the speakers say.
func _on_progress(session_id: int, kind: int, value: int, seconds: float) -> void:
	var who: WoPlayer = game.players.get(WoNetBridge.player_key(session_id))
	var mine := session_id == _watch_id

	match kind:
		WoEvents.Progress.FELL:
			if audio != null and who != null:
				var _heard := audio.on_splash(who.global_position)
			if announcer != null and who != null and camera != null:
				announcer.on_fell(who.player_id, who.global_position.distance_to(camera.global_position) < 30.0)
		WoEvents.Progress.CHECKPOINT:
			if mine and audio != null:
				var _heard := audio.on_checkpoint()
			if mine:
				hud.shout("CHECKPOINT", 1.2)
			if announcer != null and who != null:
				announcer.on_checkpoint(who.player_id)
		WoEvents.Progress.FINISHED:
			if audio != null:
				var _heard := audio.on_finish(mine)
			if mine:
				hud.shout("FINISHED #%d — %.1f s" % [value, seconds], 3.0)
			if announcer != null and who != null:
				announcer.on_finished(who.player_id, value, seconds)
			if chat != null and who != null:
				chat.say_locally("%s finished #%d in %.1f s" % [who.display_name, value, seconds],
					Color(0.98, 0.86, 0.40))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if audio != null:
		var _heard := audio.on_round(began)

	if began:
		hud.shout("ROUND %d" % number, 2.4)
		if killcam != null:
			killcam.new_round()
		return

	if announcer != null and player != null:
		announcer.on_round_over(winner != 0 and winner == player.team, winner != 0)

	hud.shout(why if why != "" else "round over", 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))

	_begin_round_end()


## A round ended: the killcam if it ended on a kill, then the reveal.
func _begin_round_end() -> void:
	if killcam == null:
		return
	if killcam.round_ended():
		DotLog.debug(CHANNEL, "the reveal waits for the final killcam")


## Offline: the world IS the authority, so its own signals are what happened. A connected client hears the same from
## the bridge's signals ([method _hear_the_wire]); both call the same [WoAudio] method, so they differ only in where a
## fact came from.
func _hear_the_world() -> void:
	if game == null:
		return

	game.world_rebuilt.connect(func() -> void:
		_on_stage(game.stage.id(), game.stage.is_arena())
		_cull_world())
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _course: StringName) -> void:
		_on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void:
		_on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName, weapon_id: StringName) -> void:
		if killcam != null and _offline:
			killcam.note_kill(String(by), String(id), String(why), String(weapon_id))
		_hear_death(game.players.get(id), why))
	game.player_fell.connect(func(id: StringName, _checkpoint: int) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.FELL, 0, 0.0))
	game.checkpoint_reached.connect(func(id: StringName, index: int) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.CHECKPOINT, index, game.course_elapsed))
	game.player_finished.connect(func(id: StringName, place: int, seconds: float) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.FINISHED, place, seconds))
	game.pickup_placed.connect(_on_pickup)
	game.pickup_taken.connect(func(pickup_id: int, by: StringName) -> void:
		_on_pickup_gone(pickup_id, 0)
		if by == &"local" and player != null:
			_arm_locally(player.weapons.arsenal.current_id() if player.weapons != null \
				and player.weapons.arsenal.has_method("current_id") else &"")
	)
	game.player_armed.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon)
	)
	game.weapon_layer.lost.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_weapon_lost(_watch_id, weapon))
	game.weapon_layer.picked.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon))

	if audio == null:
		return

	game.blast.connect(func(at: Vector3, _radius: float) -> void:
		var _heard := audio.on_blast(at))
	# Everybody else's weapons, from each rig as it is built.
	game.player_armed.connect(func(id: StringName, _weapon: StringName) -> void:
		var armed: WoPlayer = game.players.get(id)
		if armed == null or armed == player or armed.weapons == null:
			return
		if armed.weapons.used.is_connected(_on_rig_used.bind(armed)):
			return
		armed.weapons.used.connect(_on_rig_used.bind(armed))
	)


func _on_rig_used(outcome: DotWeaponOutcome, armed: WoPlayer) -> void:
	if audio != null and is_instance_valid(armed):
		var _heard := audio.on_weapon(armed.global_position, ZeeWeaponNet.kind_number(outcome.kind))


func _hear_phase(phase: int) -> void:
	if audio == null:
		return

	match phase:
		WoGame.Phase.COURSE:
			var _heard := audio.on_gate()
		WoGame.Phase.HANDOVER:
			var _heard := audio.on_handover()
		WoGame.Phase.FINALE:
			var _heard := audio.on_finale()


func _hear_death(who: WoPlayer, why: StringName) -> void:
	if who == null:
		return

	# Knocked to pieces by a blow or a blast is this game's own look; anything less, what is
	# left of the body falls as a ragdoll, the way the server picked.
	# A flung body (a knockout at low health) is the flight itself: not broken up on the way.
	var flung := who.death != null and who.death.reaction == WoGame.FLING
	if flung or not _break(who, why):
		_fall(who)

	if audio == null:
		return

	var _heard := audio.on_death(who.global_position, who == player)


## The body comes apart, depending on what did it: lightning and a hard knock blow it to pieces, anything else takes a
## limb or two, seeded so every client breaks it the same way. Mended a moment later. True when it went to pieces.
func _break(who: WoPlayer, why: StringName) -> bool:
	if who.figure == null or who == player:
		return false

	var rules := DotPlayerBreakRules.new()
	rules.criticals_only = false
	var seed_value := hash(String(who.player_id)) + who.falls * 31 + who.knocks
	if why == WoGame.DIED_STRUCK or why == WoGame.DIED_BLAST or (seed_value % 3 == 0):
		rules.mode = DotPlayerBreakRules.Mode.EXPLODE
	else:
		rules.mode = DotPlayerBreakRules.Mode.LIMBS
		rules.limbs = 1 + seed_value % 3
	rules.lifetime = 2.5

	var before := DotPlayerBodyBreak.visible_meshes(who.figure)
	var made := DotPlayerBodyBreak.break_apart(
		who.figure, game, rules, who.global_position, Vector3.UP, seed_value
	)
	if made == null:
		return false

	var mend := get_tree().create_timer(1.2)
	mend.timeout.connect(func() -> void:
		if not is_instance_valid(who) or who.figure == null:
			return
		who.figure.visible = true
		for mesh in before:
			if is_instance_valid(mesh):
				mesh.visible = true
	)
	return rules.mode == DotPlayerBreakRules.Mode.EXPLODE


## Somebody got a weapon. If it was us, the gun comes up in our hands, on its own slot.
func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id:
		return

	_arm_locally(weapon_id)

	if chat != null:
		chat.say_locally("You picked up a %s." % String(weapon_id).replace("_", " "),
			Color(0.86, 0.92, 0.80))


## A gun left the watched player's hands (thrown, or left where they fell): the drawn rig lets go of it too.
func _on_weapon_lost(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id or weapons == null:
		return
	var def := weapons.arsenal.catalogue.get_def(weapon_id)
	if def != null:
		var empty: Array[int] = []
		var _gone := weapons.arsenal.drop_from_slot(def.slot, empty)
