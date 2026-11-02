extends "dedicated_rig.gd"

## `time_up: finish_round` waits for a round being played, never for warmup: the game hands
## dot-vote `round_in_progress_fn`. Run on a director of its own, so the real vote's clock is
## untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## A module reload must leave ONE link under the server, still named for the client's route.
## A second link would rename the live one `@Node@n` and lose every RPC without an error.
## The proof is a real client over the socket: signing on is server events.
func _test_a_module_reload() -> void:
	_section("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("wipeout").ok, "the module unloads")
		var back: DotResult = await server.modules.load_module("res://game/wo_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == WoNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(WoNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(WoNetLink.NODE_NAME)) == null:
			var sink := WoNetLink.attached_to(link, null, false)
			sink.name = WoNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	_check(joined and spawned[0], "a real client still hears the server's events after two reloads")
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


## A seat whose client has not lifted its loading cover (dot-game's "still loading") cannot be
## harmed, eliminated or put across, and can once it does; an admin's slay still passes. Over a
## real ENet socket: the client joins and says nothing, then sends `game.cover`.
func _test_a_covered_seat_is_not_harmed() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")

	var module := _module()
	var c := await _join_cover_client(module)
	var link: DotClientLink = c["link"]
	var peer: int = c["peer"]
	var session: int = c["session"]
	var key := WoNetBridge.player_key(session)
	var victim: WoPlayer = game.players.get(key)
	_check(victim != null, "a client joins over the socket and is seated", "peer %d session %d" % [peer, session])

	if victim == null:
		for what in [
			"the server holds it as loading", "a lethal hit does nothing to it",
			"a fall on a course is not counted against it", "an admin's slay still passes",
			"its cover report crosses the wire", "and the same hit now lands",
			"and a fall counts again",
		]:
			_check(false, what)
	else:
		await _cover_checks(module, link, peer, session, victim)

	link.disconnect_from_server("done")
	(c["side"] as Node).queue_free()
	_finished()


func _join_cover_client(module: Object) -> Dictionary:
	var bridge := module.get("bridge") as WoNetBridge if module != null else null
	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Covered"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	# RPC paths are relative to the multiplayer root, so the link must sit at the path the
	# server's does: "Dedicated/Server" under the root.
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	# The link retires whatever the game left under it when it signs on, so a sink for the
	# server's snapshots is put back at each phase change (a real game scene does this itself).
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(WoNetLink.NODE_NAME)) == null:
			var sink := WoNetLink.attached_to(link, null, false)
			sink.name = WoNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	joined = joined and spawned[0]
	var peer := side.multiplayer.get_unique_id() if joined else 0
	var session := 0
	if bridge != null and joined:
		var _seated := await _until(func() -> bool: return bridge.player_for_peer(peer) != 0, 10.0)
		session = bridge.player_for_peer(peer)
	var key := WoNetBridge.player_key(session)
	var _there := await _until(func() -> bool: return game.players.has(key), 10.0)
	return {"side": side, "link": link, "peer": peer, "session": session}


func _cover_checks(module: Object, link: DotClientLink, peer: int, session: int, victim: WoPlayer) -> void:
	var key := WoNetBridge.player_key(session)
	_check(bool(module.call("is_peer_loading", peer)) and not game.can_be_harmed(key),
		"the server holds it as loading from its spawn")

	victim.health.alive = true
	victim.health.health = victim.health.max_health
	victim.health.invulnerable = false
	victim.health.cannot_die = false
	victim.health.invulnerable_until_tick = -1
	victim.watching = false
	var before := victim.health.health
	# A death on a course revives at once (a restart or the lounge), so health alone proves
	# nothing: the signal is the proof.
	var deaths := []
	var on_died := func(id: StringName, _by: StringName, _why: StringName, _weapon: StringName) -> void: deaths.append(id)
	game.player_died.connect(on_died)
	var hit := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
	hit.tick = game._tick
	hit.context = {"why": &"shot"}
	var _applied: Variant = game.combat.apply_damage(hit)
	_check(deaths.is_empty() and victim.is_alive() and is_equal_approx(victim.health.health, before),
		"a lethal hit does nothing to it", "%s -> %s, deaths %d" % [before, victim.health.health, deaths.size()])

	# A fall on a course costs time only, so what a covered seat must keep is its count; on an
	# arena the fall is a lethal hit, which the resolver has just been shown to refuse.
	var falls := victim.falls
	game._fell(victim)
	_check(victim.is_alive() and (victim.falls == falls or game.stage.is_arena()),
		"a fall is not counted against it and does not eliminate it", "falls %d -> %d" % [falls, victim.falls])

	var slain: Variant = (module.get("services") as Object).call("_mod_hurt", StringName(str(session)), -1.0)
	_check(slain is DotResult and (slain as DotResult).ok and deaths.has(key),
		"an admin's slay still passes", str(slain))
	game.player_died.disconnect(on_died)
	victim.health.alive = true
	victim.health.health = before

	await _cover_lifted(module, link, peer, victim, key)


func _cover_lifted(module: Object, link: DotClientLink, peer: int, victim: WoPlayer, key: StringName) -> void:
	DotGameClient.report_cover(link, false)
	var lifted := await _until(func() -> bool: return not bool(module.call("is_peer_loading", peer)), 10.0)
	_check(lifted and game.can_be_harmed(key), "its cover report crosses the wire and ends the loading state")
	var after_lift := victim.health.health
	var late := DotDamage.make(0, victim.entity_id, 1.0, null)
	late.tick = game._tick
	late.context = {"why": &"late"}
	var _late_applied: Variant = game.combat.apply_damage(late)
	_check(victim.health.health < after_lift, "and the same hit now lands",
		"%s -> %s" % [after_lift, victim.health.health])
	var falls := victim.falls
	game._fell(victim)
	_check(victim.falls == falls + 1 or game.stage.is_arena(), "and a fall counts again",
		"falls %d -> %d" % [falls, victim.falls])
