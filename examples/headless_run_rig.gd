extends DotGameCheckSuite

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoContent := preload("../game/wo_content.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoWorld := preload("../game/wo_world.gd")
const WoCourseCfg := preload("../game/wo_course_cfg.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")
const WoAnnouncer := preload("../game/wo_announcer.gd")
const WoAudio := preload("../game/wo_audio.gd")
const WoBindings := preload("../game/wo_bindings.gd")
const WoClient := preload("../game/wo_client.gd")
const WoEvents := preload("../game/net/wo_events.gd")
const WoGame := preload("../game/wo_game.gd")
const WoHud := preload("../game/wo_hud.gd")
const WoPaths := preload("../game/wo_paths.gd")
const WoPlayer := preload("../game/wo_player.gd")
const WoProgress := preload("../game/wo_progress.gd")
const WoRacer := preload("../game/wo_racer.gd")
const WoSettings := preload("../game/wo_settings.gd")

## The simulation harness of headless_run: the tick, the world factory and the section counters.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _sections_entered := 0
var _sections_finished := 0

var _worlds: Array[WoGame] = []


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


## A world on the practice course (or on [param course]), stepped by hand. The previous
## world is freed first: all share ONE physics space with every course at the origin, so a
## leftover start gate blocks the next runner.
func _world(configure: Callable = Callable(), course: Dictionary = {}) -> WoGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.course_ids = PackedStringArray(["wo_practice"])
	config.arena_ids = PackedStringArray(["wo_practice_arena"])
	config.keep_progress = true
	# One course then the final death, the round most sections were written against; the
	# courses-per-round section asks for more.
	config.courses_per_round = 1

	if configure.is_valid():
		configure.call(config)

	var game := WoGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	if not course.is_empty():
		var _built := game.build_stage(course)

	# Two frames, so every collider is in the physics space before anything is asserted.
	await _physics_frame()
	await _physics_frame()
	return game


func _step(game: WoGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: WoGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame
