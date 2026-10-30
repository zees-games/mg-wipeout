extends Node

const WoPlayer := preload("wo_player.gd")

## Where somebody knocked out of the final death looks, and what the server lets them see. The policy is the server's
## (a client deciding for itself could look at anything): a server runs an authoritative [DotSpectatorManager], a
## client a MIRROR told each change in a `SPECTATE` event. No delay: every client already has every live position.

const CHANNEL := "wo.spectate"

## Seconds the death camera holds before handing over: a second and a half, enough to see what happened (the barrel,
## the edge). Not a killcam.
const DEATH_CAM_SECONDS := 1.5

## Seconds the freeze camera holds on whoever put you out, in the final death.
const FREEZE_CAM_SECONDS := 1.5

## How far above the floor a faller's death camera hangs, looking down the drop. Not where they died: a fall is
## recorded at the kill height, where nothing is worth seeing, so the camera goes back up over the point they left.
const DROP_CAM_RISE := 6.0

## Which of the two overview cameras is the final death's. See [method set_overviews].
const OVERVIEW_FIELD := 0
const OVERVIEW_SHOWDOWN := 1

## A viewer's camera changed: a death, a hand-over, a target leaving, a step through the
## list. [param player_id] is theirs. What the bridge tells that one client about.
signal view_changed(player_id: StringName)

var manager: DotSpectatorManager = null

## player id -> WoPlayer. The world's own dictionary, shared rather than copied, so a join
## is visible here the moment the world has it.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}

## [code]() -> int[/code], the world's phase. See [method camera_for].
var phase_fn: Callable = Callable()

## [code](phase) -> bool[/code]: whether a phase is the final death's.
var in_showdown_fn: Callable = Callable()

## Whether this decides anything. A connected client's world is a mirror.
var authoritative: bool = true

## Set while a viewer is stepping through the list themselves. See [method _prefer_side].
var _stepping: bool = false

## Set while [method _prefer_side] is moving somebody, so its own watch does not re-enter.
var _preferring: bool = false


## The key the HUD names for the free camera; the client sets it from the bindings.
var roam_key: String = "G"


## Builds the manager on [param rules], the world's own [member WoGame.spectate_rules].
func setup(p_authoritative: bool, tick_rate: int, rules: DotSpectatorRules) -> DotResult:
	authoritative = p_authoritative

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = authoritative
	manager.rules = configure_rules(rules, tick_rate)
	manager.participants_fn = _participants
	manager.team_fn = func(key: String) -> int: return int(sides.get(StringName(key), 0))
	manager.alive_fn = _alive
	manager.pose_fn = _pose_of
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("wipeout spectating")

	manager.view_changed.connect(_on_view_changed)
	manager.retargeted.connect(_on_retargeted)

	# DEBUG rather than INFO: the world is built once per process on a server but once per
	# test in every suite, and the policy it logs is already in `wo_status`.
	DotLog.debug(CHANNEL, "spectating is set up", {
		"authoritative": authoritative,
		"force_camera": manager.rules.force_camera,
		"roaming": manager.rules.roaming_permitted(),
	})
	return DotResult.success(null)


## The policy this game adds to the operator's: how long the cameras hold and where they stand. Static so a suite can
## read it without a world. `force_camera` and `allow_roaming` are the operator's (`mp_forcecamera`, `mp_freeroam`),
## not set here.
static func configure_rules(rules: DotSpectatorRules, tick_rate: int) -> DotSpectatorRules:
	# Dead players stay dead until the next round, so a list that included them would be
	# a list of bodies at the kill height.
	rules.cycle_includes_dead = false
	rules.death_cam_ticks = int(DEATH_CAM_SECONDS * float(maxi(tick_rate, 1)))
	rules.freeze_cam_ticks = int(FREEZE_CAM_SECONDS * float(maxi(tick_rate, 1)))
	rules.chase_distance = 4.6
	rules.chase_height = 1.2
	rules.delay_ticks = 0
	rules.history_ticks = 2
	return rules


## Changes who may watch whom, from the next decision on. What the deprecated `wo_spectate_camera` writes (`mp_forcecamera` is the rule now).
func set_force_camera(force_camera: int) -> void:
	if manager == null or manager.rules == null:
		return

	manager.rules.force_camera = clampi(force_camera, 0, 2)

	# INFO: a rule an admin changed and a player is going to ask about.
	DotLog.info(CHANNEL, "the spectator policy changed", {
		"force_camera": manager.rules.force_camera,
	})


## The two places nobody-left-to-watch looks from: over the course, and over the arena. A viewer whose whole side is
## out has nobody the "own side" rule lets them follow, so dot-spectate falls back to a fixed camera. Set from the
## stage that is built.
func set_overviews(field: Transform3D, showdown: Transform3D) -> void:
	if manager == null:
		return

	var cameras: Array[Transform3D] = [field, showdown]
	manager.fixed_cameras = cameras


## Somebody is out. Starts the death camera; the server's tick hands it over. [param at] is where they died; a fall is
## recorded at the kill height, so the camera moves back up (see [constant DROP_CAM_RISE]).
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	manager.on_death(String(player_id), where, String(by), tick)

	# DEBUG: a transition. "My camera went somewhere odd when I fell" is answered by what
	# it was put on.
	DotLog.debug(CHANNEL, "somebody who is out is watching", {
		"player": String(player_id), "by": String(by), "fell": fell,
	})


## Somebody is back in the world — a new round, or a join. They stop watching.
func on_spawned(player_id: StringName) -> void:
	if manager == null:
		return

	if manager.is_spectating(String(player_id)):
		DotLog.debug(CHANNEL, "a new round ends watching", {"player": String(player_id)})

	manager.on_spawn(String(player_id))


## Somebody left. Called AFTER the world has dropped them, which is dot-spectate's rule:
## the replacement is chosen from the roster, and a roster still holding the leaver picks
## the leaver.
func on_left(player_id: StringName) -> void:
	if manager != null:
		manager.on_leave(String(player_id))


func advance(tick: int) -> void:
	if manager != null:
		manager.advance(tick)


## The next or the previous person this viewer may watch, or 0 for the other camera. Asked of the server and answered
## by it: the list is its own `targets_for`, so a client can never step onto somebody the policy forbids.
func step(player_id: StringName, direction: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	var key := String(player_id)

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	if direction == 0:
		return _cycle_camera(key)

	_stepping = true
	var moved := manager.next_target(key) if direction > 0 else manager.previous_target(key)
	_stepping = false
	return moved


## The free-roam key, asked of the server like every other camera change. Refused with a line when roaming is off
## (`mp_freeroam 0`) or a restricted camera is set (`mp_forcecamera`). The server owns the mode (ROAMING in the view
## event); the client flies the camera, because a position per frame is the wire cost this avoids.
func toggle_roam(player_id: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	var key := String(player_id)

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	if not manager.can_roam(key):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Free roam is off on this server.")

	return manager.toggle_roam(key)


func can_roam(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id)) \
		and manager.can_roam(String(player_id))


func is_roaming(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id)) \
		and manager.view(String(player_id)).mode == DotSpectatorView.Mode.ROAMING


## First person, then behind them, when the policy allows it.
func _cycle_camera(key: String) -> DotResult:
	var view := manager.view(key)

	if not view.follows_target() or view.mode == DotSpectatorView.Mode.FREEZE_CAM:
		return DotResult.fail(DotError.CODE_STATE, "There is nobody in front of this camera.")

	var wanted := DotSpectatorView.Mode.CHASE
	if view.mode == DotSpectatorView.Mode.CHASE:
		wanted = DotSpectatorView.Mode.FIRST_PERSON

	var set_to := manager.set_mode(key, wanted)

	if not set_to.ok:
		return set_to

	if int(set_to.value) != wanted:
		# dot-spectate downgrades rather than refuses, and says so at DEBUG; the viewer who
		# pressed the key is the one who needs to hear it.
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This server only lets you watch through their eyes."
		)

	return set_to


## Adopts a view the server decided. The client half.
func apply_view(
	player_id: StringName, mode: int, target: StringName, killer: StringName, death_at: Vector3
) -> void:
	if manager == null:
		return

	var view := manager.view(String(player_id))
	view.mode = clampi(mode, 0, DotSpectatorView.Mode.size() - 1) as DotSpectatorView.Mode
	view.target = String(target)
	view.killer = String(killer)
	# Carried by this game's own event: it is bit-packed and session-keyed, which dot-spectate's dictionary is not,
	# and a mirror without a death position puts every death camera at the world origin, under the start pad.
	view.death_position = death_at
	view.until_tick = -1
	view_changed.emit(player_id)


func is_spectating(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id))


func mode_of(player_id: StringName) -> int:
	return int(manager.view(String(player_id)).mode) if manager != null else 0


## Who a viewer is watching, or an empty name.
func watching(player_id: StringName) -> StringName:
	if manager == null or not manager.is_spectating(String(player_id)):
		return &""

	return StringName(manager.view(String(player_id)).target)


## Where [param player_id]'s camera goes this frame. Identity when they are playing. The fixed camera is chosen by the
## phase on both ends: this game has exactly two and which is right is a fact about the round, so it is read from the
## phase a client already has.
func camera_for(player_id: StringName) -> Transform3D:
	if manager == null:
		return Transform3D.IDENTITY

	var key := String(player_id)

	if not manager.is_spectating(key):
		return Transform3D.IDENTITY

	var view := manager.view(key)

	if view.mode == DotSpectatorView.Mode.FIXED:
		var showdown := false
		if phase_fn.is_valid() and in_showdown_fn.is_valid():
			showdown = bool(in_showdown_fn.call(int(phase_fn.call())))
		view.fixed_index = OVERVIEW_SHOWDOWN if showdown else OVERVIEW_FIELD

	return manager.camera_of(key)


## One line for the HUD, or an empty string while playing.
func line_for(player_id: StringName) -> String:
	if not is_spectating(player_id):
		return ""

	var view := manager.view(String(player_id))

	match view.mode:
		DotSpectatorView.Mode.DEATH_CAM:
			return "you are out"
		DotSpectatorView.Mode.FREEZE_CAM:
			return "shot by %s" % _name_of(StringName(view.target))
		DotSpectatorView.Mode.FIXED:
			return "nobody left to watch%s" % _roam_suffix(player_id)
		DotSpectatorView.Mode.ROAMING:
			return "free camera   %s back to players" % roam_key
		DotSpectatorView.Mode.CHASE:
			return "watching %s  (behind)   click: next   F5: their eyes%s" % [
				_name_of(StringName(view.target)), _roam_suffix(player_id)
			]
		_:
			return "watching %s   click: next   F5: behind them%s" % [
				_name_of(StringName(view.target)), _roam_suffix(player_id)
			]


## The hint for the free camera, only while the server allows it.
func _roam_suffix(player_id: StringName) -> String:
	return "   %s: free camera" % roam_key if can_roam(player_id) else ""


func _name_of(player_id: StringName) -> String:
	var body: WoPlayer = players.get(player_id)
	return body.display_name if body != null else String(player_id)


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _alive(key: String) -> bool:
	var body: WoPlayer = players.get(StringName(key))
	# Somebody in the gallery is up and is not in the fight; a camera on them is a camera on
	# a wall of other spectators.
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
	var basis := Basis.from_euler(Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0))
	return Transform3D(basis, at + Vector3(0.0, WoPlayer.EYE_HEIGHT, 0.0))


func _on_view_changed(key: String, mode: int, target: String) -> void:
	_prefer_side(key, mode, target)
	view_changed.emit(StringName(key))


func _on_retargeted(key: String, _from: String, to: String, _reason: StringName) -> void:
	_prefer_side(key, int(manager.view(key).mode), to)
	view_changed.emit(StringName(key))


## When the server picks somebody for a viewer, it picks a team-mate if there is one: dot-spectate takes the first
## allowed name in key order, a stranger, and somebody who just fell wants to see their own side. Only an AUTOMATIC
## choice moves; a viewer stepping through the list stays where they asked.
func _prefer_side(key: String, mode: int, target: String) -> void:
	if not authoritative or _stepping or _preferring or target == "":
		return

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.CHASE:
		return

	var mine := int(sides.get(StringName(key), 0))

	if mine <= 0 or int(sides.get(StringName(target), 0)) == mine:
		return

	for candidate in manager.targets_for(key):
		if int(sides.get(StringName(candidate), 0)) != mine:
			continue

		_preferring = true
		var _moved := manager.watch(key, candidate, mode)
		_preferring = false
		return


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])

	return manager.describe_lines()
