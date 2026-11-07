extends "wo_game_state.gd"
## The flashlight's rules in the simulation, under the stand-ins' layers: the server owns each player's on/off. No `class_name`.

const WoFlashlight := preload("wo_flashlight.gd")

## The flashlight config and binder, made on first use so a suite that builds a game by hand still has one; the stage the lights were last set for.
var flashlight_config: DotFlashlightConfig = null
var flashlight_binder: DotGameConfigBinder = null
var _flashlight_stage: String = ""


## The flashlight config, made on first use.
func flashlight_conf() -> DotFlashlightConfig:
	if flashlight_config == null:
		flashlight_config = WoFlashlight.make_config()
		flashlight_binder = WoFlashlight.make_binder(flashlight_config)
		DotLog.result("wo.game", "flashlight config", flashlight_binder.load_layers())
	return flashlight_config


## The course or arena the light rules are asked about.
func _flashlight_stage_id() -> String:
	return String(stage.id()) if stage != null else ""


## A new course or arena sets everybody's light by its mood (a daylit course starts dark). Server side.
func _advance_flashlights() -> void:
	var cfg := flashlight_conf()
	var id := _flashlight_stage_id()

	if id != _flashlight_stage:
		_flashlight_stage = id
		for p: WoPlayer in players.values():
			p.flashlight_ready = false

	for key: StringName in players:
		var player: WoPlayer = players[key]

		if not player.flashlight_ready:
			player.flashlight_ready = true
			player.flashlight = WoFlashlight.starts_on(cfg, id)


## A living player on the course or in the arena switches their light. Refused for somebody who is out, watching, and where the config disallows it. Server side.
func toggle_flashlight(id: StringName) -> bool:
	var player: WoPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or player.out_for_round \
			or not DotFlashlightRules.allowed_on(flashlight_conf(), _flashlight_stage_id()):
		return false

	player.flashlight = not player.flashlight
	return true
