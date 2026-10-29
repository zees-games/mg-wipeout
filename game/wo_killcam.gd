extends Node

## The final killcam. Client side: every drawn frame goes into dot-replay's [DotKillcamBuffer]; when a round ends on
## a kill, [DotKillcam] replays it from the killer's eye before the reveal. No killer (a fall, a clock) goes straight
## to [signal over]. The length is `mp_killcam_time`.

const CHANNEL := "wo.killcam"
const WoPlayer := preload("wo_player.gd")
const WoWeaponIcons := preload("wo_weapon_icons.gd")

## Skip keys: the ones a runner's hands are on.
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "ui_cancel", "ui_accept"]

## The killcam is over, or never began; the end-of-round flow goes on from here.
signal over(skipped: bool)

## `func() -> Dictionary` of id to WoPlayer.
var players_fn: Callable = Callable()

## Seconds of replay; 0 disables.
var seconds_fn: Callable = func() -> float: return 7.0

## Seconds, monotonic. Injected by a test.
var now_fn: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

## Nodes hidden while the replay runs (the HUD): anything with `visible`.
var hide_while_playing: Array = []

var buffer := DotKillcamBuffer.new()
var killcam: DotKillcam = null
var camera: Camera3D = null

var _previous_camera: Camera3D = null
var _hidden: Dictionary = {}


func _ready() -> void:
	killcam = DotKillcam.new()
	killcam.name = "Killcam"
	killcam.skip_actions = SKIP_ACTIONS
	killcam.icon_provider = func(id: String) -> Texture2D:
		return WoWeaponIcons.shared.menu_texture(StringName(id))
	add_child(killcam)
	killcam.started.connect(_on_started)
	killcam.frame_drawn.connect(_apply)
	killcam.finished.connect(_on_finished)
	camera = Camera3D.new()
	camera.name = "KillcamCamera"
	add_child(camera)


func is_playing() -> bool:
	return killcam != null and killcam.is_active()


## Records this frame, after every body is presented; while the replay runs it records only
## while the killcam waits for the frames after the kill.
func frame() -> void:
	if is_playing() and killcam.state != DotKillcam.State.WAITING:
		return
	if not players_fn.is_valid():
		return
	var shot := {}
	var all: Dictionary = players_fn.call()
	for id: Variant in all:
		var row := _state_of(all[id])
		if not row.is_empty():
			shot[String(id)] = row
	var _kept := buffer.push_frame(now_fn.call(), shot)


## A kill this client was told about. Without a killer there is nobody to watch through.
func note_kill(killer: String, victim: String, cause: String, weapon_id: String = "") -> void:
	if killer == "":
		return
	buffer.note_event(now_fn.call(), &"kill", {"killer": killer, "victim": victim, "cause": cause, "weapon_id": weapon_id})


## Forgets the last round's kills, so a round that ends on a fall replays nothing.
func new_round() -> void:
	buffer.clear()


## The round ended: replay its last kill if there is one. False means [signal over] has been
## emitted and nothing plays.
func round_ended() -> bool:
	if killcam == null or is_playing():
		return is_playing()
	killcam.max_seconds = maxf(float(seconds_fn.call()), 0.0)
	var kill := buffer.last_event(&"kill")
	var killer: WoPlayer = _player(String(kill["data"].get("killer", ""))) if not kill.is_empty() else null
	if not killcam.enabled() or killer == null:
		over.emit(false)
		return false
	var victim: WoPlayer = _player(String(kill["data"].get("victim", "")))
	var played := killcam.play(buffer, kill, {
		"killer": killer.display_name,
		"victim": victim.display_name if victim != null else "",
		"weapon": String(kill["data"].get("cause", "")).capitalize(),
		"weapon_id": String(kill["data"].get("weapon_id", "")),
		"hint": "Jump to skip",
	})
	if not played.ok:
		DotLog.debug(CHANNEL, "no final killcam", {"why": played.error.message})
		over.emit(false)
		return false
	return true


func skip() -> void:
	if killcam != null:
		killcam.skip()


func _player(key: String) -> WoPlayer:
	if key == "" or not players_fn.is_valid():
		return null
	var all: Dictionary = players_fn.call()
	var p: Variant = all.get(StringName(key))
	return p as WoPlayer if p is WoPlayer and is_instance_valid(p) else null


# [feet, yaw, pitch, alive]: where the controller had the body this frame.
func _state_of(p: WoPlayer) -> Array:
	if p == null or p.controller == null:
		return []
	var st := p.controller.state
	return [st.position, st.yaw, st.pitch, p.is_alive() and not p.watching]


func _on_started(_kill: Dictionary) -> void:
	_previous_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _previous_camera != null and _previous_camera != camera:
		camera.fov = _previous_camera.fov
		camera.cull_mask = _previous_camera.cull_mask
	camera.make_current()
	for n: Variant in hide_while_playing:
		if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
			_hidden[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)
	DotLog.info(CHANNEL, "final killcam", killcam.describe())


func _apply(s: Dictionary) -> void:
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	var killer_key := String(killcam.kill()["data"].get("killer", ""))
	if not camera.current:
		camera.make_current()
	for key: Variant in b:
		var p := _player(String(key))
		if p == null:
			continue
		var rb: Array = b[key]
		var ra: Array = a.get(key, rb)
		var feet: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var yaw := rad_to_deg(lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
		var pitch := lerpf(ra[2], rb[2], alpha)
		var alive: bool = rb[3] if alpha >= 0.5 else ra[3]
		var speed := (ra[0] as Vector3).distance_to(rb[0]) * 60.0
		if String(key) == killer_key:
			camera.global_position = feet + Vector3(0.0, WoPlayer.EYE_HEIGHT, 0.0)
			camera.global_rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)
		_place(p, feet, yaw, pitch, speed, alive and String(key) != killer_key)


func _place(p: WoPlayer, feet: Vector3, yaw: float, pitch: float, speed: float, shown: bool) -> void:
	if p.figure == null:
		return
	p.figure.visible = shown
	if not shown:
		return
	p.figure.set_motion({"on_floor": true, "aim": deg_to_rad(pitch)})
	p.figure.pose(feet, deg_to_rad(yaw), speed)


func _on_finished(skipped: bool) -> void:
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe_lines() -> PackedStringArray:
	var out := buffer.describe_lines()
	if killcam != null:
		out.append_array(killcam.describe_lines())
	return out
