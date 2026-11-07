extends RefCounted

## The on-screen buttons a phone needs: fire, alt-fire (throw), jump, duck, grab, reload, the weapon arrows, the held
## board and the chat box. The look and move halves of the screen are [DotFpsTouchSampler]'s.

const WoPlayer := preload("wo_player.gd")

const CHANNEL := "wipeout.touch"
## The share of the screen height the button cluster may reach: leaves the top right to the course name and announcer.
const MAX_HEIGHT := 0.8

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

var buttons: DotTouchButtons = null


## The fps preset with grab where use sits; a refused layout is a programmer error, so it logs and returns none.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {DotGameTouchLayout.USE: null, GRAB: &"inner"})
	if not res.ok:
		DotLog.error(CHANNEL, "touch layout refused", {"error": str(res.error)})
		return DotGameTouchLayout.custom()
	return res.value as DotGameTouchLayout


static func layout() -> Array[Dictionary]:
	return touch_layout().buttons()


## Builds the buttons under [param parent]: jump and duck go to the sampler (read through the callable, the active
## one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Node, sampler_fn: Callable, handlers: Dictionary) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout().apply(buttons)
	parent.add_child(buttons)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == CROUCH:
		var sampler: Variant = sampler_fn.call()
		if sampler != null and sampler.has_method(&"hold"):
			var bit := DotFpsCommand.BUTTON_JUMP if id == JUMP else DotFpsCommand.BUTTON_CROUCH
			sampler.call(&"hold", bit, down)
		return
	if handlers.has(id):
		(handlers[id] as Callable).call(down)


func contains_point(position: Vector2) -> bool:
	return buttons != null and buttons.contains_point(position)


## A touch sampler where a phone is, the keyboard one otherwise. [param ignore_fn] keeps a button's finger off the stick.
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
