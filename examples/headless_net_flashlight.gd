extends "headless_net_workbench.gd"
## The flashlight over the wire: the ask, and the replicated flag.


func _test_the_flashlight_crosses() -> void:
	_section("the flashlight is asked for, and the server's state comes back to everybody")
	var key := WoNetBridge.player_key(SESSION)
	var server_me: WoPlayer = _server_game.players[key]
	var mine: WoPlayer = _client_game.players[key]
	var server_net := server_me.get_node("Net") as DotNetBehaviour
	_check(server_net.find_var(&"net_flashlight").audience == DotNetVar.Audience.EVERYONE,
		"the flag is declared for everybody: the beam is drawn for the others")
	var was := server_me.flashlight
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight != was, "the server switched it")
	_check(mine.flashlight == server_me.flashlight, "and the owner is told")
	var theirs: WoPlayer = _client_game.players[_stand_in.player_id]
	_stand_in.flashlight = true
	await _steps(8)
	_check(theirs.flashlight, "and the others' flag is the server's")
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight == was and mine.flashlight == was, "the next ask switches it back")
	_finished()
