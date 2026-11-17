extends RefCounted

## The phone's controls: dot-mobile's stick, drag-look and buttons (fire, alt-fire (throw), jump, duck, grab, reload,
## the weapon arrows, the held board and the chat box) over the HUD, driving the client's own [DotFpsTouchSampler].
## Fire is read through [method is_held], so a thumb and auto-fire (the server's `sv_autofire`, off unless it says so)
## take one path. Built only where [method DotPlatform.has_touch] is true.

const WoPlayer := preload("wo_player.gd")

const CHANNEL := "wipeout.touch"
## The share of the screen height the button cluster may reach: leaves the top right to the course name and announcer.
const MAX_HEIGHT := 0.8
## A body's width for the crosshair test, metres.
const BODY_RADIUS := 0.45

const FIRE := DotGameTouchLayout.FIRE
const ALT := DotGameTouchLayout.ALT
const JUMP := DotGameTouchLayout.JUMP
const CROUCH := DotGameTouchLayout.CROUCH
const GRAB := &"grab"
const RELOAD := DotGameTouchLayout.RELOAD
const PREV := DotGameTouchLayout.PREV
const NEXT := DotGameTouchLayout.NEXT
const BOARD := DotGameTouchLayout.BOARD
const CHAT := DotGameTouchLayout.CHAT

var controls: DotMobileControls = null
## dot-ui's buttons inside the overlay, for the shell's DPI fit and the HUD's clearance.
var buttons: DotTouchButtons:
	get:
		return controls.buttons if controls != null else null

var _client: Node = null


## The fps preset with grab where use sits; a refused layout is a programmer error, so it logs and returns none.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {DotGameTouchLayout.USE: null, GRAB: &"inner"})
	if not res.ok:
		DotLog.error(CHANNEL, "touch layout refused", {"error": str(res.error)})
		return DotGameTouchLayout.custom()
	return res.value as DotGameTouchLayout


## The preset's rows, jump and duck carrying the sampler bit the overlay holds for them.
static func layout() -> Array[Dictionary]:
	var rows := touch_layout().buttons()
	for row: Dictionary in rows:
		if row["id"] == JUMP:
			row["hold"] = DotFpsCommand.BUTTON_JUMP
		elif row["id"] == CROUCH:
			row["hold"] = DotFpsCommand.BUTTON_CROUCH
	return rows


## Builds the overlay under [param parent] (the HUD), following [param rules] (the server's). [param handlers] maps a
## button id (not fire, jump or duck: the overlay's own) to a Callable taking `down: bool`. The sampler's own
## `ignore_fn` (a finger on the Menu button) moves to the overlay.
func build(client: Node, parent: Node, sampler: DotFpsSampler, rules: DotMobileRules, handlers: Dictionary) -> DotMobileControls:
	_client = client
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	controls.setup(sampler, layout())
	controls.live_fn = _live
	controls.crosshair_fn = _crosshair
	controls.button_pressed.connect(func(id: StringName) -> void: route(id, true, handlers))
	controls.button_released.connect(func(id: StringName) -> void: route(id, false, handlers))
	parent.add_child(controls)
	return controls


## One button's edge to its handler.
static func route(id: StringName, down: bool, handlers: Dictionary) -> void:
	if handlers.has(id):
		(handlers[id] as Callable).call(down)


## A declared button held by a thumb, or fire held by auto-fire.
func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


## True when the overlay is up and forwards [param event] itself, or [param event] is the mouse Godot emulates from a
## touch, which would turn the view and click a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


## Called every frame by the client: the overlay hides and lets go while [param busy] (a menu, the chat box, a cover),
## and auto-fire matches the gun in hand.
func sync(busy: bool, gun: DotWeaponDef) -> void:
	if controls == null:
		return
	controls.paused = busy
	controls.autofire.automatic = gun == null or gun.is_continuous()


func contains_point(position: Vector2) -> bool:
	return buttons != null and buttons.contains_point(position)


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


func _live() -> bool:
	return is_instance_valid(_client) and bool(_client.call(&"touch_live"))


func _crosshair() -> int:
	if not is_instance_valid(_client) or not _client.is_inside_tree():
		return DotMobileAutoFire.TARGET_NONE
	var cam: Camera3D = _client.get(&"camera")
	var me: Node = _client.get(&"player")
	var game: Object = _client.get(&"game")
	if cam == null or me == null or game == null:
		return DotMobileAutoFire.TARGET_NONE
	var mask := 0
	var physics: Object = game.get(&"physics")
	if physics != null:
		mask = int(physics.call(&"mask_of", [&"world", &"prop"]))
	return crosshair_kind(cam.global_position, -cam.global_basis.z, me, game, cam.get_world_3d().direct_space_state, mask)


## What the crosshair is on: the nearest body the camera's ray passes through. ENEMY for a living opponent, FRIEND
## for a team-mate or the dead (never shot), NONE when nothing is or a wall or prop is in front. One analytic test a
## body and at most one physics ray.
static func crosshair_kind(eye: Vector3, forward: Vector3, me: Node, game: Object, space: PhysicsDirectSpaceState3D,
		mask: int) -> int:
	var best: Node3D = null
	var best_t := INF
	var best_aim := Vector3.ZERO
	var players: Dictionary = game.get(&"players")
	for id: Variant in players:
		var p := players[id] as Node3D
		if p == null or p == me or not is_instance_valid(p) or not p.is_inside_tree():
			continue
		var height := _height(p)
		var t := forward.dot(p.global_position - eye)
		if t < -height or t >= best_t or not ray_hits_body(eye, forward, p.global_position, height, BODY_RADIUS):
			continue
		best_t = t
		best = p
		best_aim = p.global_position + Vector3(0.0, height * 0.6, 0.0)
	if best == null:
		return DotMobileAutoFire.TARGET_NONE
	if not _is_enemy(game, me, best):
		return DotMobileAutoFire.TARGET_FRIEND
	if space != null and mask != 0 and not space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, best_aim, mask)).is_empty():
		return DotMobileAutoFire.TARGET_NONE
	return DotMobileAutoFire.TARGET_ENEMY


## Whether the ray from [param from] along [param dir] (unit) passes within [param radius] of the upright body whose
## feet are at [param feet], [param height] tall, in front of the eye.
static func ray_hits_body(from: Vector3, dir: Vector3, feet: Vector3, height: float, radius: float) -> bool:
	var w := from - feet
	var denom := height * (dir.y * dir.y - 1.0)
	var s := 0.5 if absf(denom) < 0.0001 else (dir.y * dir.dot(w) - w.y) / denom
	s = clampf(s, 0.0, 1.0)
	var on_segment := feet + Vector3(0.0, height * s, 0.0)
	var t := dir.dot(on_segment - from)
	if t <= 0.0:
		return false
	return (from + dir * t).distance_to(on_segment) <= radius


static func _height(p: Node3D) -> float:
	var controller: Object = p.get(&"controller")
	var tunables: Object = controller.get(&"tunables") if controller != null else null
	return float(tunables.get(&"stand_height")) if tunables != null else 1.8


## A living player on another side. Solo, every side is its own, so everyone else is one; the dead and the watchers
## are never shot.
static func _is_enemy(game: Object, me: Node, other: Node3D) -> bool:
	if not bool(other.call(&"is_alive")) or bool(other.get(&"watching")):
		return false
	var mine := int(game.call(&"team_of", StringName(str(me.get(&"player_id")))))
	var theirs := int(game.call(&"team_of", StringName(str(other.get(&"player_id")))))
	var config: Object = game.get(&"config")
	var teams := config != null and bool(config.call(&"teams"))
	return not (teams and mine > 0 and mine == theirs)


## A touch sampler where a phone is, the keyboard one otherwise. [param ignore_fn] keeps a finger off the stick.
static func make_sampler(tunables: DotFpsTunables, ignore_fn: Callable) -> DotFpsSampler:
	var sampler: DotFpsSampler
	if DotPlatform.has_touch():
		var touch := DotFpsTouchSampler.new(tunables)
		touch.ignore_fn = ignore_fn
		sampler = touch
	else:
		sampler = DotFpsSampler.new(tunables)
	WoPlayer.register_actions(sampler)
	return sampler
