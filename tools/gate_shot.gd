extends SceneTree

## Renders the real offline client's first frames, to see what the load gate covers.
##
##     xvfb-run -a godot --path . --resolution 1280x720 --script tools/gate_shot.gd
##
## Saves screenshots/gate_<n>.png on a few chosen frames and prints, per frame, whether the gate
## is open and the local body's height. Not --headless: that renders nothing.

var _client: Node = null
var _frame := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_client = (load("res://game/wo.tscn") as PackedScene).instantiate()
	_client.force_offline = true
	root.add_child(_client)


func _process(_delta: float) -> bool:
	_frame += 1
	var p = _client.player
	var gate: DotLoadGate = _client.get("gate")
	var y: float = p.global_position.y if p != null else NAN
	print("f%d open=%s settling=%s y=%.2f phase=%d" % [_frame,
		gate.is_open() if gate != null else "nogate",
		gate.is_settling() if gate != null else "-", y, _client.game.phase])
	if _frame in [2, 6, 20, 40, 80, 140]:
		root.get_texture().get_image().save_png("res://screenshots/gate_%03d.png" % _frame)
	return _frame >= 150
