extends "wo_client_view.gd"
## The flashlight's presentation, split out of `wo_client.gd` (which extends this): the light on the eye and the others' beams (dot-flashlight); the server owns on/off. No `class_name`.

## The light on the eye and the others' beams.
var flash: DotFlashlight = null
var flash_crowd: DotFlashlightCrowd = null
var _flash_msec := -100000
var _flash_retain := 0.0


## Whether the camera is this player's own eye (first person, not watching anybody); the client says.
func _eye_is_ours() -> bool:
	return true


## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if audio == null or audio.manager == null or not audio.manager.is_inside_tree():
		return null
	return DotNodeRef.of_path(audio.manager.get_path())


## The light on the eye follows the server's state (but not for 0.4 s after our own switch, which is shown at once); everybody else's beam, and ours when the camera is not our eye, comes from the crowd.
func _present_flashlights(delta: float) -> void:
	if camera == null or player == null or game == null:
		return

	var cfg := game.flashlight_conf()
	var allowed := DotFlashlightRules.allowed_on(cfg, String(game.stage.id()) if game.stage != null else "")

	if flash == null or not is_instance_valid(flash):
		flash = DotFlashlight.new()
		flash.name = "Flashlight"
		flash.config = cfg
		flash.handle_input = false
		flash.authoritative = false
		flash.audio = _flash_audio_ref()
		flash.switch_requested.connect(_on_flash_switch)
		camera.add_child(flash)

	flash.allowed = allowed

	if flash_crowd == null:
		flash_crowd = DotFlashlightCrowd.new()
		flash_crowd.name = "Flashlights"
		flash_crowd.config = cfg
		flash_crowd.audio = _flash_audio_ref()
		add_child(flash_crowd)

	var own_eye := _eye_is_ours()
	var lit := player.flashlight and player.is_alive() and not player.watching

	if own_eye and Time.get_ticks_msec() - _flash_msec > 400:
		flash.apply_state({"on": lit})
	elif not own_eye:
		flash.apply_state({"on": false})

	flash_crowd.set_viewer(camera.global_position)

	for key: Variant in game.players:
		var other: WoPlayer = game.players[key]
		var shown := allowed and other.flashlight and other.is_alive() and not other.watching \
			and (other != player or not own_eye)
		flash_crowd.set_lit(key, shown)
		if shown:
			flash_crowd.place(key, other.eye_position(), other.aim_direction())

	_flash_retain -= delta
	if _flash_retain <= 0.0:
		_flash_retain = 2.0
		flash_crowd.retain(game.players.keys())


## Our own switch: shown at once, asked of the server (or done here, offline).
func _on_flash_switch(_want: bool) -> void:
	_flash_msec = Time.get_ticks_msec()
	if bridge != null:
		bridge.ask_flashlight()
	elif game != null and player != null:
		var _switched := game.toggle_flashlight(player.player_id)
