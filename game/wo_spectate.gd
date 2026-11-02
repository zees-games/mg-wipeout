extends DotSpectatorHost

const WoPlayer := preload("wo_player.gd")

## Where somebody knocked out of the final death looks: [DotSpectatorHost] with this game's numbers. The server runs it
## authoritatively, a client a MIRROR told each change in a `SPECTATE` event. No delay: every client already has every
## live position.

const CHANNEL := "wo.spectate"

## Seconds the death camera holds: enough to see what happened (the barrel, the edge). Not a killcam.
const DEATH_CAM_SECONDS := 1.5

## Seconds the freeze camera holds on whoever put you out, in the final death.
const FREEZE_CAM_SECONDS := 1.5

## How far above the floor a faller's death camera hangs. A fall is recorded at the kill height, where nothing is worth
## seeing, so the camera goes back up over the point they left.
const DROP_CAM_RISE := 6.0

## Which of the two overview cameras is the final death's. See [method set_overviews].
const OVERVIEW_FIELD := 0
const OVERVIEW_SHOWDOWN := 1

## player id -> WoPlayer. The world's own dictionary, shared so a join is visible here at once.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}

## [code]() -> int[/code], the world's phase. See [method camera_for].
var phase_fn: Callable = Callable()

## [code](phase) -> bool[/code]: whether a phase is the final death's.
var in_showdown_fn: Callable = Callable()


func _init() -> void:
	death_cam_seconds = DEATH_CAM_SECONDS
	freeze_cam_seconds = FREEZE_CAM_SECONDS
	chase_distance = 4.6
	chase_height = 1.2
	history_seconds = 0.0
	eye_height = WoPlayer.EYE_HEIGHT
	prefer_own_side = true
	guard_roam = true
	name_fn = _name_of
	fixed_index_fn = _overview_for


func _channel() -> String:
	return CHANNEL


func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	# Dead players stay dead until the next round, so a list with them would be bodies at the kill height.
	r.cycle_includes_dead = false
	r.delay_ticks = 0
	return r


## The two places nobody-left-to-watch looks from: over the course, and over the arena. Set from the stage that is built.
func set_course_overviews(field: Transform3D, showdown: Transform3D) -> void:
	var cameras: Array[Transform3D] = [field, showdown]
	set_overviews(cameras)


## Somebody is out. [param at] is where they died; a fall is recorded at the kill height, so the camera moves back up
## (see [constant DROP_CAM_RISE]).
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	death(String(player_id), where, String(by), tick)

	DotLog.debug(CHANNEL, "somebody who is out is watching", {
		"player": String(player_id), "by": String(by), "fell": fell,
	})


## Somebody is back in the world: a new round, or a join.
func on_spawned(player_id: StringName) -> void:
	spawned(String(player_id))


## Call AFTER the world has dropped them, so the replacement is not the leaver.
func on_left(player_id: StringName) -> void:
	left(String(player_id))


## The fixed camera is chosen by the phase on both ends: which of the two is right is a fact about the round.
func _overview_for(_key: String) -> int:
	var showdown := false

	if phase_fn.is_valid() and in_showdown_fn.is_valid():
		showdown = bool(in_showdown_fn.call(int(phase_fn.call())))

	return OVERVIEW_SHOWDOWN if showdown else OVERVIEW_FIELD


func _name_of(key: String) -> String:
	var body: WoPlayer = players.get(StringName(key))
	return body.display_name if body != null else key


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _team_of(key: String) -> int:
	return int(sides.get(StringName(key), 0))


func _is_alive(key: String) -> bool:
	var body: WoPlayer = players.get(StringName(key))
	# Somebody in the gallery is up and is not in the fight; a camera on them is a camera on a wall of spectators.
	return body != null and is_instance_valid(body) and body.is_alive() and not body.watching


## Where somebody's eyes are, from where this process DRAWS them. The drawn position, not the node, on a world that
## simulates: a node moves once a tick, so a camera on it steps (the same blend as the player's own camera,
## `render_state`). A mirror's remote players are written each frame by the interpolator.
func _pose_of(key: String) -> Transform3D:
	var body: WoPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative:
		at = body.controller.render_state().position

	var state := body.controller.state
	return eye_pose(at, state.pitch, state.yaw)
