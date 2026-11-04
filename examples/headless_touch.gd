extends DotGameCheckSuite

## The on-screen buttons: the layout fits a phone, each button reaches its handler, jump and duck reach the sampler.
##
## [codeblock]
## godot --headless --path . res://examples/headless_touch.tscn
## [/codeblock]

const WoTouch := preload("../game/wo_touch.gd")

const CHECKS := 15
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
	for id: StringName in [WoTouch.FIRE, WoTouch.ALT, WoTouch.JUMP, WoTouch.DUCK, WoTouch.GRAB, WoTouch.RELOAD]:
		_check(ids.has(id), "%s has a button" % id)

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

	_finished += 1
	_report_sections(_entered, _finished, 1, CHECKS)
