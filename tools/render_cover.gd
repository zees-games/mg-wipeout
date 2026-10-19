extends Node

const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")

## Two frames of a real client on a real server, to look at: the loading cover while the
## server still holds the seat as loading, and the first frame after the cover lifts. A
## dedicated server runs in a second process (this scene with `--role server`); both
## halves have the same root name because an RPC path is the name.
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_cover.tscn
## [/codeblock]
## Writes screenshots/cover_up.png, cover_lifted.png and cover_after_1s.png.

const PORT := 27199

var _server_pid := -1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	if "server" in OS.get_cmdline_user_args():
		_serve.call_deferred()
	else:
		_run.call_deferred()


func _serve() -> void:
	var data := "user://render_cover_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	var config := WoConfig.new()
	config.minimum_players = 2
	config.warmup_seconds = 0.0
	config.countdown_seconds = 3.0
	config.course_ids = PackedStringArray(["wo_practice"])
	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = 60
	add_child(game)

	var server_config := DotServerConfig.new()
	server_config.hostname = "render cover"
	server_config.port = PORT
	server_config.bind_address = "127.0.0.1"
	server_config.transport_mode = "dual"
	server_config.rcon_password = ""
	server_config.admins_path = "%s/admins.json" % data
	server_config.bans_path = "%s/bans.json" % data
	server_config.audit_log_path = "%s/audit.jsonl" % data
	server_config.hibernate_when_empty = false
	server_config.startup_config = ""
	server_config.autoexec_config = ""
	server_config.query_enabled = false
	server_config.enet_share_udp_port = false
	server_config.stdin_console_enabled = false
	server_config.log_level = "error"
	var server := DotServer.new()
	server.name = "Server"
	server.config = server_config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("render_cover server: ", booted.error)
		get_tree().quit(1)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/wo_module.gd")
	if not loaded.ok:
		printerr("render_cover server: ", loaded.error)
		get_tree().quit(1)
		return
	print("render_cover server: ready on %d" % PORT)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://screenshots/%s.png" % name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("render_cover: %s %s" % [path, image.save_png(path)])


func _run() -> void:
	_server_pid = OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tools/render_cover.tscn", "--", "server"]))
	await get_tree().create_timer(8.0).timeout

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var t := 0.0
	while not link.is_playing() and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	print("render_cover: playing after %.1f s" % t)

	var client: Node = (load("res://game/wo.tscn") as PackedScene).instantiate()
	add_child(client)
	for i in 3:
		await get_tree().process_frame
	var gate: DotLoadGate = client.get("gate")
	print("render_cover: gate open at the first shot: ", gate.is_open() if gate != null else "no gate")
	await _shot("cover_up")

	t = 0.0
	while gate != null and not gate.is_open() and t < 40.0:
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	for i in 3:
		await get_tree().process_frame
	print("render_cover: lifted after %.1f s" % t)
	await _shot("cover_lifted")
	await get_tree().create_timer(1.0).timeout
	await _shot("cover_after_1s")
	link.disconnect_from_server("done")
	if _server_pid > 0:
		var _k := OS.kill(_server_pid)
	get_tree().quit(0)
