extends DotGameClientBench

const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")
const WoWorld := preload("../game/wo_world.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## `--bots N` seats N stand-ins through minimum_players (fill mode); `--play` supplies the movement.


func _configure() -> void:
	client_scene = "res://game/wo.tscn"
	forward_action = &"dot_fps_forward"
	# A real client reads an io course's mesh from the mounted maps pack; none is mounted here, and without
	# it the client predicts on the pad alone while the server walks the map.
	WoWorld.add_dir("res://worlds")


func _boot_server(bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
	var config := make_server_config(data_dir)
	config.max_players = 24
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var wo_config := WoConfig.new()
	wo_config.warmup_seconds = 0.0
	wo_config.intermission_seconds = 0.0
	wo_config.course_seconds = 600.0
	wo_config.minimum_players = bots_wanted
	var game := WoGame.new()
	game.name = "World"
	game.config = wo_config
	game.config_binder = WoConfig.make_binder(wo_config)
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame
	(load("res://game/wo_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/wo_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
