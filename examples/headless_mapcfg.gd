extends DotGameCheckSuite

const WoMapConfig := preload("../game/wo_map_config.gd")

## A course gets its per-map file's rules and the next course has the previous values back.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The cvars start away from the fixture's values, so the default cannot show through as "got them".

const CHECKS := 7
const DIR := "res://cfg/game/mg-wipeout/dot_map/map/"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-wipeout: per-map cvars from cfg/game/mg-wipeout/dot_map/map")
	DotAddonConfig.game = "mg-wipeout"
	var fixture := DIR + "wo_mapcfg_fixture_*.yml"
	DirAccess.make_dir_recursive_absolute(DIR)
	var file := FileAccess.open(fixture, FileAccess.WRITE)
	file.store_string("wo_instant_death: 1\nwo_knock_damage: 7\nwo_other: 9\nwo_gravity: 0\n")
	file.close()

	var console := DotConsole.new()
	add_child(console)
	console.cvar("wo_instant_death", "0", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("wo_knock_damage", "2", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("wo_gravity", "20", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("wo_other", "5", "", DotConVar.FLAG_ARCHIVE)
	var cfg := DotGameMapConfig.for_console("mg-wipeout", console, WoMapConfig.KEYS)

	var got := cfg.apply("wo_mapcfg_fixture_a")
	_check(console.find_cvar("wo_instant_death").get_int() == 1, "wo_instant_death is 1 on the course (%s)" % [got])
	_check(console.find_cvar("wo_knock_damage").get_float() == 7.0, "wo_knock_damage is 7 on the course")
	_check(console.find_cvar("wo_other").get_int() == 5 and console.find_cvar("wo_gravity").get_float() == 1.0,
		"a cvar outside the whitelist is refused and a value under its minimum is clamped")

	cfg.apply("wo_first_splash")
	_check(console.find_cvar("wo_instant_death").get_int() == 0, "the next course has wo_instant_death back")
	_check(console.find_cvar("wo_knock_damage").get_float() == 2.0, "and wo_knock_damage")
	_check(cfg.applied().is_empty(), "a course with only commented values applies nothing")

	cfg.apply("wo_mapcfg_fixture_b")
	_check(console.find_cvar("wo_knock_damage").get_float() == 7.0, "another course matching the glob gets it again")

	cfg.restore()
	DirAccess.remove_absolute(fixture)

	_report(CHECKS)
