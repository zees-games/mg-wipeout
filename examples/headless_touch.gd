extends DotGameCheckSuite

## The on-screen buttons: the layout fits a phone, each button reaches its handler, jump and duck reach the sampler.
##
## [codeblock]
## godot --headless --path . res://examples/headless_touch.tscn
## [/codeblock]

const WoTouch := preload("../game/wo_touch.gd")
const WoHud := preload("../game/wo_hud.gd")

const CHECKS := 25
var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
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

	var built := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {DotGameTouchLayout.USE: null, WoTouch.GRAB: &"inner"})
	_check(built.ok and WoTouch.touch_layout().validate().ok, "the layout is the fps preset and validates")
	var canon := true
	for id: StringName in WoTouch.touch_layout().ids():
		canon = canon and DotGameTouchLayout.canonical_id(id) == id
	_check(canon, "no button keeps a pre-canonical id")
	_check(not ids.has(&"duck") and not ids.has(&"use") and ids.has(&"crouch"), "duck is crouch, and use is dropped")
	var homes := WoTouch.touch_layout()
	_check(homes.row(WoTouch.FIRE)["offset"] == Vector2(80, 84) and homes.row(WoTouch.JUMP)["offset"] == Vector2(80, 172)
		and homes.row(WoTouch.GRAB)["offset"] == Vector2(190, 150), "fire, jump and grab sit where the player's thumb learnt them")

	var tunables := DotFpsTunables.new()
	var sampler := DotFpsTouchSampler.new(tunables)
	var seen := {}
	var handlers := {}
	for id: StringName in [WoTouch.FIRE, WoTouch.ALT, WoTouch.GRAB, WoTouch.RELOAD]:
		handlers[id] = func(down: bool) -> void: seen[id] = down
	var holder := Control.new()
	add_child(holder)
	var touch := WoTouch.new()
	var buttons := touch.build(holder, func() -> Variant: return sampler, handlers)
	buttons.button_down.emit(WoTouch.FIRE)
	_check(seen.get(WoTouch.FIRE, false) == true, "fire down reaches its handler")
	buttons.button_up.emit(WoTouch.FIRE)
	_check(seen.get(WoTouch.FIRE, true) == false, "fire up reaches its handler")
	buttons.button_down.emit(WoTouch.GRAB)
	_check(seen.get(WoTouch.GRAB, false) == true, "grab is held")
	buttons.button_down.emit(WoTouch.JUMP)
	_check(sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "jump down reaches the sampler")
	buttons.button_up.emit(WoTouch.JUMP)
	_check(not sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "jump up clears it")
	_check(not touch.contains_point(Vector2(-50, -50)), "a point off every button is not a button's")
	var kb := WoTouch.make_sampler(tunables, Callable())
	_check(kb != null and not DotPlatform.has_touch() and not kb is DotFpsTouchSampler, "no touch device gets the keyboard sampler")
	holder.queue_free()

	for view: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
		_check_no_overlap(view)
		# DotGameScreenFit stretches a phone to a canvas with a 720 unit short side: the view the HUD is laid out in.
		var canvas := Vector2(DotGameScreenFit.plan_for(view, Vector2(1152, 648))["size"])
		_check_no_overlap(canvas, false)

	_finished += 1
	_report_sections(_entered, _finished, 1, CHECKS)


## Every HUD piece's rectangle clear of every other's, of every touch button and of the Menu button, in one phone view.
func _check_no_overlap(view: Vector2, with_buttons: bool = true) -> void:
	var rects: Dictionary = WoHud.touch_rects(view)
	rects["menu"] = Rect2(0.0, 0.0, 110.0, 64.0)
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
		for b: Dictionary in (WoTouch.layout() if with_buttons else []):
			var centre := view - (b["offset"] as Vector2)
			var radius := float(b["radius"])
			var nearest := centre.clamp(a.position, a.end)
			if nearest.distance_to(centre) < radius:
				clear = false
				culprit = "%s and the %s button" % [names[i], b["id"]]
	_check(clear, "no HUD piece overlaps another or a button at %dx%d" % [int(view.x), int(view.y)], culprit)
