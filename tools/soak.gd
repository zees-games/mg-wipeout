extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

## Bot soak on the real game: N stand-ins race one course for M simulated minutes through dot-bot's
## DotBotSoak, fed by dot-spawn's DotSpawnWatch. A "map" here is a course id.
##
## [codeblock]
## ./game.sh soak [course] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map wo_first_splash --bots 4 --minutes 2
## [/codeblock]
##
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<course>.json, prints the SOAK line, exits 1 when the run fails.
## Rounds run back to back (no warm-up or intermission). A bot is only judged stuck while the
## course is open and it has not finished. Kills are off: knocks are not kills.

const DEFAULT_MAP := &"wo_first_splash"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 4
const TICK_RATE := 64

var _game: WoGame
var _tick := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := StringName(_arg("map", String(DEFAULT_MAP)))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	if not catalogue.courses.has(map_id):
		_fail("no course %s" % map_id)
		return

	var config := WoConfig.new()
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray([String(map_id)])

	_game = WoGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)

	var taken: Array = []
	for i in range(cfg.bots):
		var bot_name := DotBotNames.pick(taken, i, WoGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := _game.add_player(StringName("u%d" % (900100 + i)), bot_name)
		bot.is_bot = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.start()

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees run.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = String(map_id)
	var falls := 0
	for id: StringName in _game.players:
		var body: WoPlayer = _game.players[id]
		falls += body.falls
	report["falls"] = falls
	report["rounds"] = _game.course_number()
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a world still loaded at quit can abort the process.
func _release_game() -> void:
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _step(_delta: float) -> void:
	_tick += 1
	_game.simulate(1.0 / float(TICK_RATE))


func _movers() -> Array:
	var out: Array = []
	var open: bool = _game.phase == WoGame.Phase.COURSE
	for id: StringName in _game.players:
		var body: WoPlayer = _game.players[id]
		out.append({"id": id, "position": body.controller.state.position, "kind": &"bot",
			"has_goal": open and not body.finished and body.is_alive()})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
