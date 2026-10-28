extends DotGameCheckSuite

const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")
const WoRacer := preload("../game/wo_racer.gd")
const WoNetBridge := preload("../game/net/wo_net_bridge.gd")
const WoAmbience := preload("../game/wo_ambience.gd")
const WoNetLink := preload("../game/net/wo_net_link.gd")

## The booted server of dedicated: its constants, state and the console helpers.

const SERVER_DIR := "user://wo_dedicated"
const PORT := 28931
const QUERY_PORT := 28932
const TICK_RATE := 60

var _sections_entered := 0
var _sections_finished := 0

var server: DotServer = null
var game: WoGame = null


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _module() -> DotModule:
	return server.modules.get_module("wipeout") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
