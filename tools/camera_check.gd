extends Node

## The cameras and bodies the first play test caught, in the real offline game:
##
## - the third-person and spectator chase cameras flown round the start and every
##   checkpoint of the course (dot-core's DotCameraCheck): never inside, armed by the
##   unprotected camera being in or behind the course on some frames;
## - a stand-in run into the back of a player who stands still: with `mp_solidplayers 1`
##   their capsules never overlap; with 0 they do (the armed half: the play test's face
##   filling the screen at the start line);
## - with `--render`, that moment from the player's eyes before (pass-through, no fade) and
##   after, and both views.
##
##   tools/camera_check.sh            # headless; exit 1 on a failure
##   tools/camera_check.sh --render   # and the frames, in screenshots/cameras/

const WoClient := preload("../game/wo_client.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

var _client: Node = null
var _render := false
var _failed := false
var _closest_at := ""


func _ready() -> void:
	_render = OS.get_cmdline_user_args().has("--render")
	_client = WoClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var game: WoGame = _client.get("game")
	game.config.warmup_seconds = 0.0
	game.config.countdown_seconds = 1.0
	await _seconds(2.5)

	_fly(game)
	# A stand-in steers and jumps along its route, so one run may never cross the player's
	# line: solid must hold on every try, and pass-through must show on at least one.
	var solid_closest := INF
	var loose_closest := INF
	for i in 4:
		solid_closest = minf(solid_closest, await _bodies(game, true))
		loose_closest = minf(loose_closest, await _bodies(game, false))
	_check(solid_closest > 0.6, "mp_solidplayers 1: a stand-in running into a player's back stops at it, four tries (closest %.2f m apart)" % solid_closest)
	_check(loose_closest < 0.3, "armed: mp_solidplayers 0, the same stand-in walks through them on some try (closest %.2f m)" % loose_closest)
	game.body_rules.solid = true

	if _render:
		await _views(game)

	print("%s" % ("all passed" if not _failed else "FAILED"))
	get_tree().quit(1 if _failed else 0)


func _fly(game: WoGame) -> void:
	var pivots: Array[Vector3] = []
	var start: Vector3 = game.course_doc["start"]["at"]
	pivots.append(start + Vector3.UP * WoPlayer.EYE_HEIGHT)
	# Beside every piece of machinery: the arms, hammers, gantries and walls a camera swings
	# into. A pivot inside a piece is skipped (the eye is always clear in play).
	var space := _client.get_viewport().world_3d.direct_space_state
	for piece in game.stage.pieces:
		var spec: Dictionary = piece.get("spec", {})
		if not spec.has("at"):
			continue
		for side in [Vector3(1.6, 0, 0), Vector3(-1.6, 0, 0), Vector3(0, 0, 1.6)]:
			var eye: Vector3 = (spec["at"] as Vector3) + side + Vector3.UP * WoPlayer.EYE_HEIGHT
			if not DotCameraProbe.is_inside(space, eye, 0.3, _client.call("_level_mask")):
				pivots.append(eye)
	var mask: int = _client.call("_level_mask")
	var world := _client.get_viewport().world_3d
	var cases := {
		"third_person": Vector3(0.0, WoClient.CHASE_UP - WoPlayer.EYE_HEIGHT, WoClient.CHASE_BACK),
		"chase": Vector3(0.0, 1.2, 4.6),
	}
	for name in cases:
		var total := {}
		for pivot in pivots:
			total = DotCameraCheck.add(total, DotCameraCheck.fly(world, DotCameraCheck.orbit_path(pivot), cases[name], mask))
		_check(DotCameraCheck.passed(total), "%s round %d points of the course: %s" % [name, pivots.size(), DotCameraCheck.summary(total)])


## A stand-in run into the back of a player standing still. Returns the closest the two
## capsules' axes came, in metres.
func _bodies(game: WoGame, solid: bool) -> float:
	game.body_rules.solid = solid
	var me: WoPlayer = _client.get("player")
	var bot: WoPlayer = null
	for id in game.players:
		var other: WoPlayer = game.players[id]
		if other != me and other.is_bot:
			bot = other
			break
	if bot == null or me == null:
		_check(false, "a stand-in and a player to run into each other")
		return INF

	# Into the course: the stand-ins are running.
	var waited := 0.0
	while game.phase != WoGame.Phase.COURSE and waited < 10.0 and bot.controller.state.velocity.length() < 2.0:
		await _seconds(0.25)
		waited += 0.25
	await _seconds(1.5)
	var heading := Vector3(bot.controller.state.velocity.x, 0.0, bot.controller.state.velocity.z)
	if heading.length() < 0.5:
		heading = Vector3.FORWARD
	heading = heading.normalized()
	me.controller.teleport(bot.controller.state.position + heading * 3.2)
	var closest := INF
	for i in 150:
		await get_tree().physics_frame
		var a := me.controller.state.position
		var b := bot.controller.state.position
		# Overlapping is the capsules intersecting: closer than two radii across while less
		# than a body height apart up and down. A stand-in standing on a head is not that.
		var across := Vector2(a.x - b.x, a.z - b.z).length()
		if absf(a.y - b.y) < 1.6 and across < closest:
			closest = across
			_closest_at = "%.2f across, %.2f up, tick %d of the try" % [across, b.y - a.y, i]
	print("    %s: closest %s" % ["solid" if solid else "pass-through", _closest_at])
	return closest


func _views(game: WoGame) -> void:
	DirAccess.make_dir_recursive_absolute("screenshots/cameras")
	var me: WoPlayer = _client.get("player")
	var start: Vector3 = game.course_doc["start"]["at"]
	me.controller.teleport(start + Vector3.UP * 0.2)
	await _seconds(0.8)
	await _shot("wipeout_view_first")
	_client.call("toggle_view")
	await _seconds(0.8)
	await _shot("wipeout_view_third")
	_client.call("toggle_view")
	await _seconds(0.3)

	# The play test's face at the lens: a stand-in on the player's eye, where walking through
	# them put it. Before: nothing hides it. After: the fade does (and solid bodies keep it
	# from getting there at all, which the check above measures). Re-placed every frame,
	# because its own brain moves it on.
	var fade: DotCameraFade = _client.get("_fade")
	var camera: Camera3D = _client.get("camera")
	var bot: WoPlayer = null
	for id in game.players:
		var other: WoPlayer = game.players[id]
		if other != me and other.is_bot:
			bot = other
			break
	if bot == null:
		return
	game.body_rules.solid = false
	var figures: Callable = fade.bodies_fn
	fade.bodies_fn = Callable()
	await _held_in_front(bot, me, camera, "wipeout_walk_in_before")
	fade.bodies_fn = figures
	await _held_in_front(bot, me, camera, "wipeout_walk_in_after")
	game.body_rules.solid = true


func _held_in_front(bot: WoPlayer, me: WoPlayer, camera: Camera3D, file: String) -> void:
	var ahead := -camera.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	for i in 20:
		bot.controller.teleport(me.controller.state.position + ahead * 0.35, rad_to_deg(atan2(ahead.x, ahead.z)))
		bot.global_position = bot.controller.state.position
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _shot(file: String) -> void:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout
