extends GSGameCheckSuite

## The on-screen buttons: the layout fits a phone, the gs-mobile overlay drives the sampler and reaches the handlers, and the
## crosshair test holds fire on team-mates and the dead.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`.

const WoTouch := preload("../game/wo_touch.gd")
const WoHud := preload("../game/wo_hud.gd")
const WoSettings := preload("../game/wo_settings.gd")

const CHECKS := 39
var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-wipeout: touch buttons")
	_entered += 1
	var ids := {}
	var fits := true
	for b: Dictionary in WoTouch.layout():
		ids[b["id"]] = true
		var off: Vector2 = b["offset"]
		fits = fits and off.y + float(b["radius"]) <= 375.0 and off.y - float(b["radius"]) >= 0.0
	_check(ids.size() == WoTouch.layout().size(), "every button id is unique")
	_check(fits, "every button fits a 375 px tall screen")
	for id: StringName in [WoTouch.FIRE, WoTouch.ALT, WoTouch.JUMP, WoTouch.CROUCH, WoTouch.GRAB, WoTouch.RELOAD]:
		_check(ids.has(id), "%s has a button" % id)

	var built := GSGameTouchLayout.build(GSGameTouchLayout.FPS, {GSGameTouchLayout.USE: null, WoTouch.GRAB: &"inner"})
	_check(built.ok and WoTouch.touch_layout().validate().ok, "the layout is the fps preset and validates")
	var canon := true
	for id: StringName in WoTouch.touch_layout().ids():
		canon = canon and GSGameTouchLayout.canonical_id(id) == id
	_check(canon, "no button keeps a pre-canonical id")
	_check(not ids.has(&"duck") and not ids.has(&"use") and ids.has(&"crouch"), "duck is crouch, and use is dropped")
	var homes := WoTouch.touch_layout()
	_check(homes.row(WoTouch.FIRE)["offset"] == Vector2(80, 84) and homes.row(WoTouch.JUMP)["offset"] == Vector2(80, 172)
		and homes.row(WoTouch.GRAB)["offset"] == Vector2(190, 150), "fire, jump and grab sit where the player's thumb learnt them")

	var tunables := GSFpsTunables.new()
	var kb := WoTouch.make_sampler(tunables, Callable())
	_check(kb != null and not GSPlatform.has_touch() and not kb is GSFpsTouchSampler, "no touch device gets the keyboard sampler")
	_overlay()
	_crosshair()

	for view: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
		# GSGameScreenFit stretches a phone to a canvas with a 720 unit short side, and scales the buttons up to a thumb
		# (44 real px at least, a 9 mm target on a dense screen): the HUD is laid out in that canvas against those buttons.
		var plan := GSGameScreenFit.plan_for(view, Vector2(1152, 648))
		var canvas := Vector2(plan["size"])
		for target: float in [44.0, 96.0, 160.0]:
			var k := GSGameScreenFit.button_scale_for(WoTouch.layout(), float(plan["stretch"]), target, canvas * Vector2(0.45, WoTouch.MAX_HEIGHT))
			_check_no_overlap(canvas, k)

	_finished += 1
	_report_sections(_entered, _finished, 1, CHECKS)


## Every HUD piece's rectangle clear of every other's, of every touch button (scaled by [param k], 28 units in) and of the Menu button, in one canvas.
## Where gs-menu puts the touch Menu button: the corner this game's spec asks for, a 96 x 52 button 14 units in from it.
func _menu_rect(view: Vector2) -> Rect2:
	var corner := WoSettings.spec_for().menu_button_corner
	var size := Vector2(96.0, 52.0)
	var inset := 14.0
	var right := corner == &"top_right" or corner == &"bottom_right"
	var bottom := corner == &"bottom_right" or corner == &"bottom_left"
	return Rect2(Vector2(view.x - inset - size.x if right else inset, view.y - inset - size.y if bottom else inset), size)


func _check_no_overlap(view: Vector2, k: float) -> void:
	var left := view.x
	var buttons := WoTouch.layout()
	for b: Dictionary in buttons:
		left = minf(left, view.x - 28.0 - (b["offset"] as Vector2).x * k - float(b["radius"]) * k)
	var rects: Dictionary = WoHud.touch_rects(view, left)
	rects["menu"] = _menu_rect(view)
	var clear := true
	var culprit := ""
	var names := rects.keys()
	for i in names.size():
		var a: Rect2 = rects[names[i]]
		if not Rect2(Vector2.ZERO, view).encloses(a):
			clear = false
			culprit = "%s leaves the screen" % names[i]
		for j in range(i + 1, names.size()):
			if a.intersects(rects[names[j]]):
				clear = false
				culprit = "%s and %s" % [names[i], names[j]]
		for b: Dictionary in buttons:
			var centre := view - Vector2(28.0, 28.0) - (b["offset"] as Vector2) * k
			var radius := float(b["radius"]) * k
			var nearest := centre.clamp(a.position, a.end)
			if nearest.distance_to(centre) < radius:
				clear = false
				culprit = "%s and the %s button" % [names[i], b["id"]]
	_check(clear, "no HUD piece overlaps another or a button at %dx%d, buttons x%.2f" % [int(view.x), int(view.y), k], culprit)


## A stand-in for a player: the members the crosshair test reads.
class Body extends Node3D:
	var player_id: StringName = &""
	var alive := true
	var watching := false

	func is_alive() -> bool:
		return alive


## A stand-in for the game state: players, sides and whether there are teams.
class Match extends RefCounted:
	var players := {}
	var sides := {}
	var config := Cfg.new()

	func team_of(id: StringName) -> int:
		return int(sides.get(id, 0))


class Cfg extends RefCounted:
	var team_count := 2

	func teams() -> bool:
		return team_count >= 2


func _overlay() -> void:
	GSPlatform.touch_override = 1
	# The real parent is the HUD, a CanvasLayer.
	var host := CanvasLayer.new()
	add_child(host)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var seen := {}
	var handlers := {}
	for id: StringName in [WoTouch.ALT, WoTouch.GRAB, WoTouch.RELOAD, WoTouch.PREV, WoTouch.NEXT]:
		handlers[id] = func(down: bool) -> void: seen[id] = down
	var touch := WoTouch.new()
	var controls := touch.build(self, host, sampler, GSMobileRules.new(), handlers)
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	_check(touch.buttons != null and touch.buttons.radius_of(WoTouch.FIRE) > 0.0, "the buttons are built, fire among them")
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(touch.takes(tap) and touch.takes(fake), "it takes touches and the mouse emulated from them")
	_check(not touch.takes(InputEventMouseMotion.new()), "a real mouse is not its")
	for id: StringName in [WoTouch.ALT, WoTouch.GRAB, WoTouch.RELOAD]:
		controls.button_pressed.emit(id)
		_check(seen.get(id, false) == true, "%s down reaches its handler" % id)
	controls.button_released.emit(WoTouch.GRAB)
	_check(seen.get(WoTouch.GRAB, true) == false, "grab up reaches its handler")
	controls.button_pressed.emit(WoTouch.JUMP)
	_check(not seen.has(WoTouch.JUMP), "jump is the overlay's own, not a handler's")
	touch.sync(true, null)
	_check(not controls.visible and not touch.active(), "a menu pauses it")
	touch.sync(false, null)
	_check(touch.active(), "and closing the menu brings it back")
	_check(not touch.contains_point(Vector2(-9000, -9000)), "a point off every button is not a button's")
	host.free()
	GSPlatform.touch_override = -1


func _crosshair() -> void:
	var game := Match.new()
	var me := _body(game, &"1", 1, Vector3.ZERO)
	var enemy := _body(game, &"7", 2, Vector3(0, 0, -10))
	var eye := Vector3(0, 1.6, 0)
	var ahead := Vector3(0, 0, -1)
	var foe := GSMobileAutoFire.TARGET_ENEMY
	var friend := GSMobileAutoFire.TARGET_FRIEND
	var none := GSMobileAutoFire.TARGET_NONE
	_check(WoTouch.crosshair_kind(eye, ahead, me, game, null, 0) == foe, "the crosshair on a living opponent is an enemy")
	_check(WoTouch.crosshair_kind(eye, Vector3(1, 0, 0), me, game, null, 0) == none, "looking away is nothing")
	var mate := _body(game, &"4", 1, Vector3(0, 0, -5))
	_check(WoTouch.crosshair_kind(eye, ahead, me, game, null, 0) == friend, "a team-mate in front holds fire")
	mate.free()
	game.players.erase(&"4")
	enemy.alive = false
	_check(WoTouch.crosshair_kind(eye, ahead, me, game, null, 0) == friend, "the dead are never shot")
	enemy.alive = true
	game.config.team_count = 0
	game.sides[&"7"] = 1
	_check(WoTouch.crosshair_kind(eye, ahead, me, game, null, 0) == foe, "without teams the nearest body is an enemy")
	for b: Node in [me, enemy]:
		b.free()


func _body(game: Match, id: StringName, side: int, at: Vector3) -> Body:
	var b := Body.new()
	b.player_id = id
	add_child(b)
	b.global_position = at
	game.players[id] = b
	game.sides[id] = side
	return b
