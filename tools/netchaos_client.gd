extends DotGameNetchaosClient

## Wipeout's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient). No fire action: the pilot only walks and jumps.


func _configure() -> void:
	client_scene = "res://game/wo.tscn"


func _roster() -> Array:
	var game = _client.get("game") if _client != null else null
	return game.players.values() if game != null else []
