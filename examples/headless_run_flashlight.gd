extends "headless_run_client.gd"
## The flashlight: the course's mood sets it, a player switches it, the out and a config may not.

const WoFlashlight := preload("res://game/wo_flashlight.gd")


func _test_the_flashlight() -> void:
	_section("the flashlight: the course sets it, a player switches it, the out and a config may not")
	var game := await _world()
	var a := game.add_player(&"f1", "Ada")
	var b := game.add_player(&"f2", "Bo")
	await _step(game, 4)
	var cfg := game.flashlight_conf()
	var keys := WoBindings.make()
	_check(cfg.key == "F" and game.flashlight_binder != null, "the key is F and the config has a binder", cfg.key)
	_check(str(keys.row_for_action(WoBindings.FLASHLIGHT).get("default", "")) == "F" and keys.defaults_on("F").size() == 1,
		"the key is a bindings row, and nothing else defaults to F")
	_check(not WoFlashlight.starts_on(cfg, "wo_practice"), "a daylit course starts dark")
	_check(WoFlashlight.starts_on(cfg, "wo_scary_house") and WoFlashlight.starts_on(cfg, "wo_sweet_tooth"),
		"and the horror house and the night courses start lit")

	cfg.default_state = DotFlashlightConfig.START_ON
	a.flashlight_ready = false
	await _step(game, 2)
	_check(a.flashlight, "a config that starts lit lights the player")
	cfg.default_state = DotFlashlightConfig.START_OFF
	a.flashlight_ready = false
	await _step(game, 2)
	_check(not a.flashlight, "and one that starts dark does not")

	_check(game.toggle_flashlight(a.player_id) and a.flashlight, "the switch turns a light on")
	_check(game.toggle_flashlight(a.player_id) and not a.flashlight, "and the next press turns it off")

	b.watching = true
	_check(not game.toggle_flashlight(b.player_id) and not b.flashlight, "somebody out in the gallery has no switch")

	cfg.enabled = false
	_check(not game.toggle_flashlight(a.player_id) and not a.flashlight, "a disabled config has no light")
	cfg.enabled = true
	cfg.default_state = DotFlashlightConfig.START_DARK
	_finished()
