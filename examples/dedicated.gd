extends "dedicated_late.gd"


## The game as a deployed server runs it: a real [DotServer], booted from a config file, with
## the module loaded BY PATH the way an operator names it — so the netcode, the services, the
## cvars and the stand-ins are the ones a deployment gets, not a copy assembled for a test.
##
## [b]What neither of the other suites can reach.[/b] `headless_run` drives a world by hand and
## `headless_net` joins two halves with no server; this is the only place [WoModule] loads,
## [DotGameModule]'s order runs, a cvar is typed at a console and a round is played by
## nothing but the stand-ins the module seats itself.

const SECTIONS := 15
const CHECKS := 107


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout as a dedicated server")
	print("")

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_commands()
		_test_config_and_noblock()
		await _test_a_round_runs()
		await _test_a_reload_keeps_delivered_courses()
		_test_the_course_vote()
		_test_rotation_file()
		_test_rotation_file_frees()
		_test_finish_round_waits_for_a_live_round()
		await _test_a_module_reload()
		await _test_a_covered_seat_is_not_harmed()
		await _test_ambient_cvars_reach_the_client()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


## Takes the server down before quitting: a booted [DotServer]'s listener holds the main loop,
## and a run that only called `quit()` prints its results and hangs. See mg-smash-copter.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(game):
		remove_child(game)
		game.free()
		game = null

	if is_instance_valid(server):
		remove_child(server)
		server.free()
		server = null

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")

	# `startup_config`, because `sv_tickrate` is startup-only and dot-server execs this file
	# before the listener for exactly that reason.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "wipeout test"
	config.max_players = 24
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off, or this run never ends: a thread blocked in a read of stdin is one Godot will not
	# exit without.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(server.state == DotServer.State.RUNNING, "the server boots", DotServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine",
		"%d" % Engine.physics_ticks_per_second)
	_finished()


func _test_the_module_loads() -> void:
	_section("the module")

	# The world is built after the server (whose tick rate it reads) and before the module
	# (which refuses to load without a world to run; it cannot build one).
	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.course_seconds = 10.0
	config.minimum_players = 3
	config.course_ids = PackedStringArray(["wo_practice"])

	var binder := WoConfig.make_binder(config)
	_check(binder.load_layers().ok, "the config layers load")
	game = WoGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(DotRegistry.get_node_service(WoGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(game.stage.is_course(), "and already has a course")

	(load("res://game/wo_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/wo_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(game != null and game.progress != null and game.progress.durable_key_fn.is_valid(),
		"progress is filed under dot-game's stable stats key")
	_check(module != null and module.get("net") != null and module.get("bridge") != null,
		"with its netcode and the game's bridge")

	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.tick_rate == TICK_RATE, "the netcode runs at the configured rate")
	_check(net != null and absf(net.config.world_extent - WoGame.NET_WORLD_EXTENT) < 0.01,
		"against the world extent both ends decode with")
	_finished()


func _test_the_commands() -> void:
	_section("the console")
	_check(_said(_run_command("wo_status"), "wipeout"), "wo_status says what the round is doing")
	_check(_said(_run_command("wo_courses"), "wo_practice"), "wo_courses lists the courses")
	_check(_said(_run_command("wo_courses"), "arenas"), "and the arenas")
	_check(_said(_run_command("wo_net"), "bridge"), "wo_net says what the netcode is doing")

	# A cvar's default is the value the world was built with, and setting one writes through.
	_check(_said(_run_command("wo_course_seconds"), "10"), "wo_course_seconds reports the world's own value")
	var _set := _run_command("wo_course_seconds 12")
	_check(is_equal_approx(game.config.course_seconds, 12.0), "and setting it writes through to the world",
		"%.1f" % game.config.course_seconds)
	var _back := _run_command("wo_teams 1")
	_check(game.config.team_count == 0, "one team is not a mode, and is taken as solo")
	# And it is REPLICATED: dot-server sends it to every client before its scene loads and on
	# every change, so a client's own combat manager (following its link) predicts tracers
	# under the server's level rather than its default.
	var shared := server.console.find_cvar("mp_teammate_passthrough")
	var _two := _run_command("mp_teammate_passthrough 2")
	_check(shared != null and shared.has_flag(DotConVar.FLAG_REPLICATED)
			and server.console.replicated_values().get("mp_teammate_passthrough", "") == "2",
		"mp_teammate_passthrough is replicated: a client is sent the server's level",
		str(server.console.replicated_values()))
	var _one := _run_command("mp_teammate_passthrough 1")
	_finished()


## A whole round, played by the stand-ins the module seats on its own.
## The config as cvars and a workbench set, the old cvar names as aliases, and dot-team's block rules through dot-game.
func _test_config_and_noblock() -> void:
	_section("config and noblock")
	var console := server.console
	var binder := game.config_binder
	_check(binder != null and console.has_name("wo_finale_seconds") and console.has_name("wo_config_diff"), "the config is bound to cvars and commands")
	var _set := _run_command("wo_thrown_seconds 5")
	_check(is_equal_approx(game.config.thrown_seconds, 5.0) and binder.source_of("thrown_seconds") == "cvar", "a wo_<field> cvar writes the field")
	var _hp := _run_command("wo_health 0")
	_check(not game.config.health_enabled and console.get_string("wo_health_enabled", "") == "0", "the old wo_health alias writes the field and its cvar")
	var _back := _run_command("wo_health_enabled 1")
	_check(game.config.health_enabled and console.get_string("wo_health", "") == "1", "and the field's cvar moves the alias")
	var module := _module()
	var wb: DotGameWorkbench = module.get("workbench") if module != null else null
	_check(wb != null and wb.api != null, "the module hosts a workbench")
	if wb == null or wb.api == null:
		return
	var rel := "config_players"
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": rel, "id": binder.profile_id, "key": "friendly_fire", "value": true})
	_check(res.ok and game.config.friendly_fire and game.combat.rules.friendly_fire and console.get_string("wo_friendly_fire", "") == "1",
		"a workbench edit changes the field, the live cvar and the combat rules", "" if res.ok else res.error.message)
	var amb: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "ambience", "id": DotGameWorkbench.CVAR_SET_ID, "key": "wo_ambient_volume", "value": 0.2})
	_check(amb.ok and is_equal_approx(console.get_float("wo_ambient_volume"), 0.2), "the wo_ambient* cvars are a workbench set and an edit moves the cvar", "" if amb.ok else amb.error.message)
	var _restore := console.set_cvar("wo_ambient_volume", "0.35")
	var teamblock := console.find_cvar("mp_teamblock")
	var enemyblock := console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1", "mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(game.block_rules != null, "block rules are wired to the world")
	_check(game.team_of_side(&"nobody") == "", "a player with no side has no block side")
	var _reset := _run_command("wo_thrown_seconds 3")
	var _ff := _run_command("wo_friendly_fire 0")
	_finished()


func _test_a_round_runs() -> void:
	_section("a round, played by the stand-ins")
	var rounds: Array = []
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: rounds.append([n, winner, why]))

	# Real time: the server ticks itself. The module tops the server up every two seconds.
	var until := Time.get_ticks_msec() + 20000

	while Time.get_ticks_msec() < until and rounds.is_empty():
		await get_tree().physics_frame

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as WoPlayer).is_bot:
			bots += 1

	_check(bots == game.config.minimum_players, "the module seated stand-ins up to the minimum", "%d" % bots)
	_check(not rounds.is_empty(), "and a round was decided", str(rounds))
	_check(not rounds.is_empty() and str(rounds[0][2]) != "", "with a sentence saying why", str(rounds))
	# [b]A person takes a stand-in's place, and leaving gives it back[/b]: DotBotQuota's fill
	# mode, the family's default. Driven by calling the roster check rather than waiting for
	# its interval, with a person added through the bridge the way a test's player is (peer
	# zero, not a stand-in), so the count is exact and nothing else moves under it.
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	# How the stand-ins race and aim is one word, dot-bot's, plus this game's racing settings.
	var bot_settings := DotBotSettings.of(game)
	_check(server.console.get_string("bot_difficulty", "") == "medium" and bot_settings.difficulty() == "medium",
		"bot_difficulty is the module's and medium is the default")
	var _hard := _run_command("bot_difficulty hard")
	_check(is_equal_approx(server.console.get_float("bot_reaction"), DotBotProfile.preset_value("hard", "reaction"))
			and is_equal_approx(server.console.get_float("wo_bot_fumble"), WoRacer.preset_value("hard", "fumble")),
		"bot_difficulty hard writes bot_reaction and the racing wo_bot_* settings",
		"%s / %s" % [server.console.get_string("bot_reaction"), server.console.get_string("wo_bot_fumble")])
	var _medium := _run_command("bot_difficulty medium")
	_check(server.console.find_cvar("wo_bot_spread") == null and server.console.find_cvar("wo_bot_mistakes") != null,
		"wo_bot_spread is gone (dot-bot's bot_aim_error took it over), wo_bot_mistakes scales the racing")
	var _alias := _run_command("wo_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old wo_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: DotResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
		# Named from the game's list through dot-bot, never "Stand-in 2", never twice.
		var names: Array = []
		for id: StringName in quota_module.get("_bot_ids"):
			names.append((game.players[id] as WoPlayer).display_name)
		var distinct := {}
		for n in names:
			distinct[n] = true
		_check(distinct.size() == names.size() and names.all(func(n: String) -> bool: return WoGame.BOT_NAMES.has(n)),
			"the stand-ins have names from the list, none shared", str(names))
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")
		_check(false, "the stand-ins have names from the list, none shared", "no module")

	var _restored := _run_command("wo_min_players 3")

	_check(_said(_run_command("wo_status"), "round"), "and wo_status still answers")
	_finished()


## A reload keeps the courses the server names. `wo_reload` reads the course directory again with
## `load_from`, which forgets everything read before, and in two of the three games built this
## way it stopped there: every delivered course was gone until a restart, with nothing logged.
## A pack "mounted" on the disk and a descriptor naming it stand in for dot-cloud and the
## deployment's map config (dot-server-deploy's cfg/content.yml), which a suite has neither of.
func _test_a_reload_keeps_delivered_courses() -> void:
	_section("a reload keeps the courses the server names")
	var key := "dot-test/wo-delivered@1.0.0"
	var mount := DotGameContent.mount_of(key)
	var dir := mount.path_join("courses")
	var id := &"wo_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	# Plain, the way a document on the disk is: the built-in one holds Vector3s, which JSON
	# writes as strings the reader refuses.
	file.store_string(JSON.stringify(load("res://game/wo_course_doc.gd").call("_to_plain", doc)))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := DotGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("wo_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.courses.has(id), "a course the server names is in the catalogue after wo_reload",
		str(game.catalogue.courses.keys()))
	_check(game.catalogue.courses.has(&"wo_practice"),
		"beside the built-in one")

	manager.set("_current", was)
	var _second := _run_command("wo_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.courses.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## The players' vote decides the next course, end to end through what a player types: a
## nomination, the ballot opening on its own clock with the nomination on it, a vote by
## number, the round's end putting the winner on the next round, and rock-the-vote opening a
## ballot early. Commands run at the console, which is where a `!vote` typed in chat lands
## (`_on_chat_command` runs it as the player); the console's voter is "console", so the
## voter list is that one name. Stand-ins are not voters, and a server of stand-ins never
## opens a ballot by itself.
##
## Synchronous from the round's end to the course laid: the stand-ins' rounds are running,
## and one that started in a frame between would lay the voted course itself and leave the
## check reading the rotation's.
func _test_the_course_vote() -> void:
	_section("the course vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a course vote")

	if vote == null:
		_finished()
		return

	var commands_there := true

	for name in ["vote", "rtv", "nominate"]:
		commands_there = commands_there and server.console.find_command(name) != null

	_check(commands_there, "and registered dot-vote's vote, rtv and nominate")


	# Hibernation: DotGameModule hands the director the server, the ballot's timer waits with
	# it, and waking starts both again from the top.
	var director: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(director.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_course", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and director.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_course: float = vote.get("_on_course_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_course_sec"), on_course), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(is_zero_approx(vote.get("_on_course_sec")) and not vote.get("_opened_this_course") and not director.hibernating,
		"waking wakes the vote, and the course ballot is owed again from the top")

	# Every course in the directory, not only this suite's practice course.
	game.config.course_ids = PackedStringArray()
	vote.call("refresh_courses")
	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("wo_grand_tour") and ids.has("wo_log_roll") and not ids.has("wo_arena_pit"),
		"it offers the courses, and no arena", str(ids))

	await _course_vote_menu(vote)

	# A course that is not the one being played, so it can be nominated.
	var playing := String(game.stage.id()) if game.stage != null and not game.stage.is_arena() \
		else str(game.course_doc.get("id", ""))
	director.begin(StringName(playing))
	var wanted := "wo_log_roll" if playing != "wo_log_roll" else "wo_grand_tour"
	var captured: Array = []
	vote.set("voters_fn", func() -> Array: return [&"console"])
	vote.set("ballot_fn", func(state: Dictionary) -> void: captured.append(state))

	_check(_said(_run_command("nominate %s" % wanted), "Nominated"), "a player nominates a course", wanted)

	vote.set("_on_course_sec", 0.0)
	vote.set("_opened_this_course", false)
	vote.call("advance", float(vote.get("open_after_sec")) + 0.1)
	var options: Array[StringName] = director.ballot.option_ids() if director.is_voting() else ([] as Array[StringName])
	_check(director.is_voting() and options.has(StringName(wanted)),
		"the ballot opens on its own clock, with the nomination on it", str(options))
	# The feed is polled each tick before the ballot timer opens one, so it sees it next tick.
	(vote.get("feed") as DotVoteBallotFeed).poll()
	var drawn: Dictionary = captured.back() if not captured.is_empty() else {}
	_check(bool(drawn.get("open", false)) and str(drawn.get("command", "")) == "vote" \
			and (drawn.get("options", []) as Array).size() == options.size(),
		"and the ballot a client draws says so, with the command that votes", str(drawn.keys()))

	_check(_said(_run_command("vote %d" % (options.find(StringName(wanted)) + 1)), "Voted"),
		"a vote by the number on the ballot counts")
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	vote.call("advance", 0.05)
	_check(director.pending_id() == StringName(wanted), "and decides it, waiting for the round's end",
		str(director.pending_id()))

	vote.call("note_round_end")
	_check(game.next_course_id == StringName(wanted), "the round's end hands it to the world", str(game.next_course_id))
	game.call("_lay_out_course")
	_check(game.stage.id() == StringName(wanted) and game.next_course_id == &"",
		"and the next course laid is the one voted for, once", "%s / %s" % [game.stage.id(), game.next_course_id])

	# The course laid is a world_rebuilt, which starts the director over on it; rocking the
	# vote then brings the ballot forward instead of waiting for open_after_sec.
	_check(director.current_id() == StringName(wanted) and not director.is_voting(),
		"the new course starts the vote over", str(director.current_id()))
	# Past dot-vote's cooldown between two ballots, on the director alone so the course's own
	# ballot timer does not open one first. In play a course outlasts it.
	director.rules.rtv_delay_sec = 0.0
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var opened_count := [0]
	var counter := func(_options: Array, _seconds: float) -> void: opened_count[0] += 1
	director.vote_opened.connect(counter)
	# The map's own rules came back with it; this fixture has one voter.
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	var _rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and rock-the-vote opens a ballot before its time", str(_rocked))
	# The director opens it under MANUAL; this game used to open it from clock.expired too.
	_check(opened_count[0] == 1, "and opens exactly one rtv ballot, not a second from the game", str(opened_count[0]))
	director.vote_opened.disconnect(counter)
	_finished()

## Stands in for the module a vote's commands are registered on, recording the names.

func _course_vote_menu(vote: Node) -> void:
	# The map menu's server half (M): the owner's flag changes the course now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the course now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every course, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(changed["ok"]) and game.stage.id() == target, "staff choosing one changes the course on the spot",
		"%s: %s" % [target, changed.get("text", "")])


class CommandHost extends Node:
	var added: Dictionary = {}

	func add_command(full: String, fn: Callable, _help: String, _permission: String) -> Object:
		added[full] = fn
		return null


## A catalogue that has a real maps.yml applied must free when the last reference goes. The
## rotation file's `fallback_in` lambda once read the catalogue's own `_defs`, which captured the
## catalogue itself: a RefCounted cycle that nothing frees, reported only at exit as leaked objects
## (mg-deathrun had 29), where no assertion reaches. A WeakRef is the in-process proof.
func _test_rotation_file_frees() -> void:
	_section("rotation file frees")
	var path := SERVER_DIR.path_join("leak_maps.yml")
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "a maps.yml is written")

	if file == null:
		_finished()
		return

	file.store_string("defaults:\n  rotations:\n    short:\n      mode: cycle\n      maps: [\"*\"]\n")
	file.close()

	var read := DotMapRotationFile.load_files(PackedStringArray([path]), "mg-wipeout")
	_check(read.ok, "and read by dot-map", str(read.error))
	var probe := _apply_and_drop(read.value)
	_check(probe.get_ref() == null, "the catalogue it was applied to is freed with its last reference")
	_finished()


## Own function so no local keeps the catalogue alive when the WeakRef is read.
func _apply_and_drop(rotation_file: DotMapRotationFile) -> WeakRef:
	var catalogue = load("res://game/wo_catalogue.gd").new()
	catalogue.rotation_file = rotation_file
	catalogue.apply_rotation()
	return weakref(catalogue)


## `maps.yml` (dot_map tiers): which courses rotate. The format is dot-map's selftest's; this is what the GAME
## does with it: a course left out is installed and loadable and is never drawn, never on a
## ballot, never nominated, marked in the map list; a switch of rotation takes effect; a renamed
## command is registered; no file means every course.
func _test_rotation_file() -> void:
	_section("rotation file")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var catalogue = game.catalogue
	var made: Array[StringName] = []
	var kept_ids: PackedStringArray = game.config.course_ids
	game.config.course_ids = PackedStringArray()

	for n in 4:
		var doc: Dictionary = catalogue.practice().duplicate(true)
		doc["id"] = "rot_%d" % n
		doc["name"] = "Rotation %d" % n
		var _added: bool = catalogue._add(doc, "rotation test")
		made.append(StringName("rot_%d" % n))

	catalogue._rebuild_order()
	var keep_a: Array = ["rot_0", "rot_1"]
	var keep_b: Array = ["rot_2", "rot_3"]

	var parsed := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "a",
		"rotations": {"a": {"maps": keep_a, "mode": "random"}, "b": {"maps": keep_b, "mode": "cycle"}},
		"commands": {"names": {"rtv": "rockit", "wo_courses": "courselist"}},
	}}], "mg-wipeout")
	_check(parsed.ok, "a rotation file parses", str(parsed.error))
	var kept = catalogue.rotation_file
	catalogue.rotation_file = parsed.value
	catalogue.apply_rotation(game.config.course_ids)

	var drawn := {}
	for _i in 30:
		var doc: Dictionary = catalogue.next_course(game.config.course_ids, true, game.random.stream(&"course"), &"")
		drawn[String(doc["id"])] = true
		catalogue.note_played(StringName(str(doc["id"])))
	var strays := drawn.keys().filter(func(id: String) -> bool: return not keep_a.has(id))
	_check(not drawn.is_empty() and strays.is_empty(), "a course outside the rotation is never drawn", str(strays))
	_check(catalogue.courses.has(&"rot_2") and catalogue.playable_courses(game.config.course_ids).has(&"rot_2"),
		"and stays installed and loadable")
	_check(not catalogue.rotating(game.config.course_ids).has(&"rot_2"), "but is not what the rotation offers")

	if vote != null:
		vote.call("refresh_courses")
		var ballot: Array = []
		for choice in (vote.get("source") as DotVoteListSource).entries:
			ballot.append(String(choice.id))
		_check(ballot.has("rot_0") and not ballot.has("rot_2"), "never on a ballot", str(ballot))
		var refused := _run_command("nominate rot_2")
		_check(not _said(refused, "Nominated"), "refused by nominate", ", ".join(refused))
		var accepted := _run_command("nominate rot_0")
		# A ballot may be running from the section before, which refuses any nomination; what
		# matters is that a course in the rotation is known to nominate, an unlisted one is not.
		_check(not _said(accepted, "nothing called"), "while one in the rotation is known to it", ", ".join(accepted))
	else:
		_check(false, "never on a ballot", "no vote")
		_check(false, "refused by nominate", "no vote")
		_check(false, "while one in the rotation is known to it", "no vote")

	var out_row: Dictionary = {}
	var in_row: Dictionary = {}
	for row: Dictionary in game.course_rows():
		if row["id"] == "rot_2":
			out_row = row
		elif row["id"] == "rot_0":
			in_row = row
	_check(not out_row.is_empty() and not bool(out_row["in_rotation"])
			and str(out_row["name"]).contains("not in rotation"), "the course list marks it")
	_check(not in_row.is_empty() and bool(in_row["in_rotation"])
			and not str(in_row["name"]).contains("not in rotation"), "and leaves the rotating ones alone")
	_check(game.change_course_now(&"rot_2").ok, "while an admin's course change still loads it",
		str(game.stage.id()))

	_check(catalogue.switch_rotation("b").ok
			and catalogue.rotating(game.config.course_ids) == ([&"rot_2", &"rot_3"] as Array[StringName]),
		"a rotation switch takes effect")
	_check(not catalogue.switch_rotation("nowhere").ok, "and an unknown rotation changes nothing")

	var seen: Array = []
	for _i in 4:
		var doc: Dictionary = catalogue.next_course(game.config.course_ids, true, null, &"")
		seen.append(String(doc["id"]))
		catalogue.note_played(StringName(str(doc["id"])))
	_check(seen[0] != seen[1] and seen[0] == seen[2] and seen[1] == seen[3]
			and keep_b.has(seen[0]) and keep_b.has(seen[1]), "a cycle walks the rotation in turn", str(seen))

	_check(game.command_names("wo_courses") == PackedStringArray(["courselist"])
			and game.command_names("wo_reload") == PackedStringArray(["wo_reload"]),
		"the game's own map command is renameable from the file")

	var host := CommandHost.new()
	var bound: DotResult = vote.call("install_commands", host) if vote != null else null
	_check(bound != null and bound.ok and host.added.has("rockit") and not host.added.has("rtv"),
		"and a renamed rtv is registered under its new name", ", ".join(host.added.keys().slice(0, 6)))
	host.free()

	# No file: every course rotates, as it always did.
	catalogue.rotation_file = null
	catalogue.apply_rotation(game.config.course_ids)
	_check(catalogue.rotating(game.config.course_ids) == catalogue.playable_courses(game.config.course_ids)
			and catalogue.in_rotation(&"rot_2"), "with no file every course is in the rotation")

	# Put the world back: the other suites share this catalogue.
	for id in made:
		var _gone: bool = catalogue.courses.erase(id)
	catalogue._rebuild_order()
	catalogue.rotation_file = kept
	catalogue.apply_rotation(game.config.course_ids)
	game.config.course_ids = kept_ids
	if vote != null:
		vote.call("refresh_courses")
	_finished()


## A seat whose client has not lifted its loading cover (dot-game's "still loading") cannot be
## harmed, eliminated or put across, and can once it does; an admin's slay still passes. Over a
## real ENet socket: the client joins and says nothing, then sends `game.cover`.
func _test_a_covered_seat_is_not_harmed() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")

	var module := _module()
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
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

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
	falls = victim.falls
	game._fell(victim)
	_check(victim.falls == falls + 1 or game.stage.is_arena(), "and a fall counts again",
		"falls %d -> %d" % [falls, victim.falls])

	link.disconnect_from_server("done")
	side.queue_free()
	_finished()


func _test_it_unloads_cleanly() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(server.console.find_command("wo_status") == null if server.console.has_method("find_command") else true,
		"and takes its commands with it")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished()


## [b]`wo_ambient*` on a client.[/b] The server's ambience intent rides the replicated cvars over a real socket, and a
## director that follows the game's rules (as [WoClient] wires it) has it in its layer's config.
func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's wo_ambient* reaches a client's ambience director, live")
	var side := Node.new()
	side.name = "AmbientClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Ambient"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(WoNetLink.NODE_NAME)) == null:
			var sink := WoNetLink.attached_to(link, null, false)
			sink.name = WoNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var rules := WoAmbience.make_rules()
	var _followed := rules.follow_cvars(link)
	var director := DotAmbienceDirector.new()
	director.ambient = DotAmbience.new()
	director.follow_settings(null, rules)
	var joined := false
	for _i in 1800:
		await get_tree().physics_frame
		if link.replicated_cvar("wo_ambient_volume", "") != "":
			joined = true
			break
	_check(joined and link.replicated_cvar("wo_ambient_dir", "x") == "x",
		"the join carried wo_ambient_volume, and the machine-local wo_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := server.console.set_cvar("wo_ambient_volume", "0.8")
	var _mood := server.console.set_cvar("wo_ambient_mood", "swamp")
	var _off := server.console.set_cvar("wo_ambient", "0")
	var arrived := false
	for _i in 900:
		await get_tree().physics_frame
		if is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
				and not director.ambient.config.enabled:
			arrived = true
			break
	_check(arrived, "a change of volume, mood and the switch reaches the director live", str(rules.describe()))
	var _back_vol := server.console.set_cvar("wo_ambient_volume", "0.35")
	var _back_mood := server.console.set_cvar("wo_ambient_mood", "")
	var _back_on := server.console.set_cvar("wo_ambient", "1")
	var back := false
	for _i in 900:
		await get_tree().physics_frame
		if rules.is_on() and rules.mood == "":
			back = true
			break
	_check(back, "and back", str(rules.describe()))
	director.ambient.free()
	director.free()
	link.disconnect_from_server("done")
	for _i in 120:
		await get_tree().physics_frame
	side.queue_free()
	_finished()


## No message script preloads itself: in mg-buses-from-hell that one line leaked the whole
## script graph at exit (8ed866c), and the leak is printed after `quit()`, where no assertion
## reaches. So the cause is checked, on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()
	var dir := DirAccess.open("res://game/net")

	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue

		var source := FileAccess.get_file_as_string("res://game/net/" + file)

		if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
			offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished()
