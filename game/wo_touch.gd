extends RefCounted

## The on-screen buttons a phone needs: fire, alt-fire (throw), jump, duck, grab, reload, the weapon arrows, the held
## board and the chat box. The look and move halves of the screen are [DotFpsTouchSampler]'s.

const WoPlayer := preload("wo_player.gd")

const CHANNEL := "wipeout.touch"

const FIRE := &"fire"
const ALT := &"alt"
const JUMP := &"jump"
const DUCK := &"duck"
const GRAB := &"grab"
const RELOAD := &"reload"
const PREV := &"prev"
const NEXT := &"next"
const BOARD := &"board"
const CHAT := &"chat"

var buttons: DotTouchButtons = null


## Offsets are from the bottom-right corner towards the middle; small enough for a 375 px tall screen.
static func layout() -> Array[Dictionary]:
	return [
		{"id": FIRE, "label": "FIRE", "offset": Vector2(80, 84), "radius": 44.0},
		{"id": ALT, "label": "ALT", "offset": Vector2(190, 60), "radius": 30.0},
		{"id": JUMP, "label": "JUMP", "offset": Vector2(80, 172), "radius": 32.0},
		{"id": DUCK, "label": "DUCK", "offset": Vector2(262, 60), "radius": 28.0},
		{"id": GRAB, "label": "GRAB", "offset": Vector2(190, 150), "radius": 26.0},
		{"id": RELOAD, "label": "R", "offset": Vector2(262, 140), "radius": 22.0},
		{"id": PREV, "label": "<", "offset": Vector2(138, 246), "radius": 22.0},
		{"id": NEXT, "label": ">", "offset": Vector2(80, 246), "radius": 22.0},
		{"id": BOARD, "label": "TAB", "offset": Vector2(196, 246), "radius": 22.0},
		{"id": CHAT, "label": "CHAT", "offset": Vector2(254, 246), "radius": 22.0},
	]


## Builds the buttons under [param parent]: jump and duck go to the sampler (read through the callable, the active
## one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Node, sampler_fn: Callable, handlers: Dictionary) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout())
	parent.add_child(buttons)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == DUCK:
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
