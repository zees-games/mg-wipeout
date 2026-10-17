extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

## Races a field of stand-ins round every course at every difficulty and prints how long they
## took: the numbers a course's length and a preset's mistake rates are tuned against.
##
## [codeblock]
## godot --headless --path . res://tools/race_times.tscn -- [--course=wo_first_splash]
##     [--difficulty=medium] [--bots=8] [--rounds=1] [--damage=1] [--csv=user://race_times.csv]
## [/codeblock]
##
## [b]Deterministic[/b]: the same arguments print the same numbers, because every mistake is a
## seeded draw (see [WoGame] `_bot_roll`) and the ticks are driven here, not paced by frames
## (legitimate for the reason `headless_courses` gives). Each round is a different round number,
## so `--rounds=3` is three different draws of who gets what wrong. Knock damage is on, as a
## server plays it (a stand-in can be knocked out of a round); weather is off, so a course's
## number is the course's.
##
## Per course and preset: how many of the field finished, and the finish times' fastest,
## median, slowest, the falls per runner, and how many were knocked out of the round (`out`,
## health gone on the course). A runner neither home nor out was still running at the close.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _world: WoGame = null
var _csv: Array[String] = ["course,difficulty,round,bot,finished,seconds,falls,knocks"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var only_course := ""
	var difficulties: Array = DotBotProfile.PRESETS.duplicate()
	var bots := 8
	var rounds := 1
	var damage := true
	var csv_path := ""
	var mistakes := 1.0
	var verbose := false
	var overrides := {}
	var follow := ""
	var extra := ""

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--course="):
			only_course = arg.trim_prefix("--course=")
		elif arg.begins_with("--difficulty="):
			difficulties = arg.trim_prefix("--difficulty=").split(",")
		elif arg.begins_with("--bots="):
			# Two at the least: a round needs two sides to start.
			bots = clampi(arg.trim_prefix("--bots=").to_int(), 2, 16)
		elif arg.begins_with("--rounds="):
			rounds = clampi(arg.trim_prefix("--rounds=").to_int(), 1, 20)
		elif arg.begins_with("--damage="):
			damage = arg.trim_prefix("--damage=") != "0"
		elif arg.begins_with("--set="):
			# A racing setting by hand, as `wo_bot_<field>` would: --set=hop_miss=0
			var pair := arg.trim_prefix("--set=").split("=")
			if pair.size() == 2:
				overrides[pair[0]] = pair[1]
		elif arg.begins_with("--extra="):
			# More documents from an absolute directory: a scratch course to try a section on.
			extra = arg.trim_prefix("--extra=")
		elif arg.begins_with("--follow="):
			# Prints one runner's state every tick: --follow=Tumble
			follow = arg.trim_prefix("--follow=")
			verbose = true
		elif arg == "--verbose":
			verbose = true
		elif arg.begins_with("--mistakes="):
			mistakes = arg.trim_prefix("--mistakes=").to_float()
		elif arg.begins_with("--csv="):
			csv_path = arg.trim_prefix("--csv=")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	if extra != "":
		var _added := catalogue.add_directory(extra)
	var ids: Array = catalogue.courses.keys()
	ids.sort()

	print("race times: %d bots, %d round(s) each, damage %s, weather off" % [bots, rounds, "on" if damage else "off"])
	print("%-20s %-10s %8s %7s %7s %7s %6s %4s" % ["course", "preset", "finished", "fastest", "median", "slowest", "falls", "out"])

	for id: StringName in ids:
		if only_course != "" and not String(id).begins_with(only_course):
			continue
		if String(id) == "wo_practice" and only_course == "":
			continue

		for difficulty: String in difficulties:
			var times: Array[float] = []
			var falls := 0
			var runners := 0
			var out := 0

			for round_index in range(rounds):
				var result := await _race(catalogue.courses[id], difficulty, bots, round_index, damage, mistakes, verbose, overrides, follow, extra)
				for row: Dictionary in result:
					runners += 1
					falls += int(row["falls"])
					out += 1 if bool(row["out"]) else 0
					if bool(row["finished"]):
						times.append(float(row["seconds"]))
					_csv.append("%s,%s,%d,%s,%d,%.2f,%d,%d" % [id, difficulty, round_index, row["name"],
						1 if bool(row["finished"]) else 0, float(row["seconds"]), int(row["falls"]), int(row["knocks"])])

			times.sort()
			var median := times[times.size() / 2] if not times.is_empty() else 0.0
			print("%-20s %-10s %4d/%-3d %7.1f %7.1f %7.1f %6.1f %4d" % [id, difficulty, times.size(), runners,
				times.front() if not times.is_empty() else 0.0, median,
				times.back() if not times.is_empty() else 0.0, float(falls) / float(maxi(runners, 1)), out])

	if csv_path != "":
		var file := FileAccess.open(csv_path, FileAccess.WRITE)
		if file != null:
			file.store_string("\n".join(_csv) + "\n")
			print("wrote %s" % ProjectSettings.globalize_path(csv_path))

	if _world != null:
		remove_child(_world)
		_world.free()

	get_tree().quit(0)


func _race(doc: Dictionary, difficulty: String, bots: int, round_index: int, damage: bool, mistakes: float, verbose: bool = false, overrides: Dictionary = {}, follow: String = "", extra: String = "") -> Array[Dictionary]:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := WoConfig.new()
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.bot_mistakes = mistakes
	config.seed_value = 20261012 + round_index * 7919
	if not damage:
		config.knock_damage_per_speed = 0.0
	config.course_ids = PackedStringArray([str(doc["id"])])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_world = game
	var _set := DotBotSettings.of(game).set_difficulty(difficulty)
	if extra != "" and game.catalogue != null:
		var _added := game.catalogue.add_directory(extra)
	for field: String in overrides:
		var _over := game.racer.set_value(field, str(overrides[field]))

	var field: Array[WoPlayer] = []
	var taken: Array = []

	for i in range(bots):
		var bot_name := DotBotNames.pick(taken, i, WoGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := game.add_player(StringName("u%d" % (900100 + i)), bot_name)
		bot.is_bot = true
		field.append(bot)

	await get_tree().physics_frame
	await get_tree().physics_frame

	# Where each fall happened and what the bot meant to do there: the route point it was
	# heading for and the plan it had drawn for it.
	var last_at := {}
	# A grid of tiles: which column each crossing of it went down (counted on the first tile
	# of it a runner stands on), and how many falls were from it or the deck's edge before it.
	var columns := {}
	var tile_falls := [0]
	if verbose:
		game.player_fell.connect(func(id: StringName, checkpoint: int) -> void:
			var who: WoPlayer = game.players.get(id)
			var where: Vector3 = last_at.get(id, Vector3.ZERO)
			for reach: Vector3 in [Vector3.ZERO, Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2), Vector3(0, 0, -2)]:
				if not game.stage.tile_cell(where + reach).is_empty():
					tile_falls[0] += 1
					break
			print("  fall  %-10s t=%5.1f cp=%d last on the ground at %s" % [who.display_name if who else id,
				game.course_elapsed, checkpoint, (last_at.get(id, Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)])
		)

	# Knocked out of the round (health gone on the course) while the course was open, which
	# is not the same as still running when it closed: then everybody not home watches.
	var eliminated := {}
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName) -> void:
		if game.phase == WoGame.Phase.COURSE:
			eliminated[id] = true
		if verbose:
			print("  died  %-10s t=%5.1f why=%s" % [(game.players.get(id) as WoPlayer).display_name if game.players.has(id) else String(id), game.course_elapsed, why])
	)

	if verbose:
		game.phase_changed.connect(func(to: int) -> void:
			print("  phase %d at course %.1f s" % [to, game.course_elapsed]))

	game.start()

	var limit := game.course_limit() + config.countdown_seconds + 1.0
	var started := false
	# What each runner had done at the last tick the course was open. Read after the loop, the
	# runner has already been reset: a course that everybody finishes closes at once (the
	# intermission is 0 here) and the next one's countdown puts them back on the start pad with
	# `finished` cleared, so every field read 0/N on any course it got home on.
	var last := {}

	for i in range(int(limit * TICK_RATE)):
		game.simulate(TICK)

		if game.phase == WoGame.Phase.COURSE:
			for bot in field:
				var seen: Dictionary = last.get(bot.player_id, {})
				if not seen.get("finished", false):
					seen = {"finished": bot.finished, "seconds": bot.finish_seconds if bot.finished else game.course_elapsed}
				seen["falls"] = bot.falls
				seen["knocks"] = bot.knocks
				last[bot.player_id] = seen

		if verbose:
			for bot in field:
				var grounded := bot.controller.state.mode == DotFpsState.Mode.GROUND
				if bot.display_name == follow:
					var st := bot.controller.state
					print("  %-10s t=%6.2f at=%s v=%s %s route=%s" % [follow, game.course_elapsed, st.position.snapped(Vector3.ONE * 0.01),
						st.velocity.snapped(Vector3.ONE * 0.1), "G" if grounded else "A", game._bot_route.get(bot.player_id, -1)])
				if grounded:
					last_at[bot.player_id] = bot.controller.state.position
					var tile := game.stage.tile_under(bot.controller.state.ground_id)
					var crossing := "%d/%d" % [int(tile.get("piece", -1)), bot.falls]
					if not tile.is_empty() and bot.get_meta(&"crossing", "") != crossing:
						bot.set_meta(&"crossing", crossing)
						var counts: Array = columns.get(int(tile["piece"]), [0, 0, 0, 0, 0])
						counts[int(tile["col"])] += 1
						columns[int(tile["piece"])] = counts
				elif bot.get_meta(&"was_grounded", false):
					var v := bot.controller.state.velocity
					print("  air   %-10s t=%5.2f at=%s v=(%.1f flat, %.1f up) route=%s" % [bot.display_name, game.course_elapsed,
						bot.controller.state.position.snapped(Vector3.ONE * 0.1), Vector2(v.x, v.z).length(), v.y, game._bot_route.get(bot.player_id, -1)])
				bot.set_meta(&"was_grounded", grounded)
				if bot.knocks > int(bot.get_meta(&"knocks_told", 0)):
					bot.set_meta(&"knocks_told", bot.knocks)
					print("  knock %-10s t=%5.1f at=%s" % [bot.display_name, game.course_elapsed, bot.controller.state.position.snapped(Vector3.ONE * 0.1)])

		if i % 512 == 0:
			await get_tree().process_frame

		if game.phase == WoGame.Phase.COURSE:
			started = true
		elif started:
			break

	var out: Array[Dictionary] = []

	if verbose:
		for piece: int in columns:
			print("  tiles piece %d: crossings by column %s" % [piece, columns[piece]])
		print("  tiles falls from the tiles or the deck before them: %d" % tile_falls[0])
		for bot in field:
			print("  end   %-10s %s at %s route %s falls %d" % [bot.display_name, "home %.1f s" % bot.finish_seconds if bot.finished else "out" if bot.watching else "running",
				bot.controller.state.position.snapped(Vector3.ONE * 0.1), game._bot_route.get(bot.player_id, -1), bot.falls])

	for bot in field:
		out.append({
			"name": bot.display_name, "finished": last[bot.player_id]["finished"],
			"seconds": last[bot.player_id]["seconds"],
			"falls": last[bot.player_id]["falls"], "knocks": last[bot.player_id]["knocks"],
			"out": eliminated.has(bot.player_id) and not last[bot.player_id]["finished"],
		})

	return out
