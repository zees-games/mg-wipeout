extends Node

const WoConfig := preload("wo_config.gd")
const WoGame := preload("wo_game.gd")

## What a [DotServer] loads as its game scene; never a client. Lives in `game/`, not `scenes/`: a vendored game copies
## `game/` and only the `.tscn`s, so a script under `scenes/` never reaches the build. The rest is in `wo_module.gd`.

const CHANNEL := "wo.server"

## The world this server is running. What the module will find in the registry.
var game: WoGame = null


func _ready() -> void:
	var config := WoConfig.new()

	# The family's `defaults < JSON < environment < argv` chain, on the server too (`WO_COURSE_SECONDS`,
	# `--wo-columns`); the module's cvars are its live half. Through DotGameConfigBinder: strict on a dedicated server.
	var binder := WoConfig.make_binder(config, "user://cfg/wipeout.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = WoGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# The engine's rate, already set from `sv_tickrate` before this scene loads; a game that picked its own
	# would simulate at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"courses": config.course_directory,
		"teams": config.team_count,
	})

	# Not started here: nothing is listening yet, because the module builds the bridge that answers
	# `world_rebuilt`, so a course laid out now is never sent. The module starts it, on its load's last line.
