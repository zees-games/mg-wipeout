extends "headless_run_rig.gd"

## A real offline client, booted: its settings are built and read by its sampler and its
## camera, and Escape opens the screen. Escape used to let go of the mouse and offer nothing.
func _test_the_client_settings() -> void:
	_section("the client's settings are read, and Escape opens them")
	var client: Node = (load("res://game/wo_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)

	# The course used to be drawn, and steered, while it was still being built: the cover is up
	# at the start, blocks input, and lifts once the player is in.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 400:
		await get_tree().physics_frame
		if platform != null and platform.is_shown():
			break
	for i in 2:
		await get_tree().process_frame
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and int(settings.describe().get("look_bound", 0)) > 0 \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its sampler and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)
	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()

	# The Tab board, held: the menu's, drawn from the local world offline.
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	settings.menu.handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().size() >= 1
		and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player on it and picked out",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	settings.menu.handle_event(tab)
	_check(board != null and not board.is_open() and not settings.is_open(), "and letting go puts it away")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## A watched player carrying a prop is drawn with both arms out under it (the person's
## held-gun arms); with the arms down the prop read as a crate following
## somebody about. A mirrored player (no gravity gun here) is told by the snapshot's bit.
func _test_a_carrier_is_drawn_carrying() -> void:
	_section("a carrier is drawn carrying")
	var game := await _world()
	var carrier := game.add_player(&"u1", "Ada")
	carrier.carrying = true
	var _shown := carrier.present_body(false, carrier.global_position, Color.WHITE)
	# The figure is one of the family's people: carrying is the held-gun arms, out in front.
	var person: DotHumanoidFigure = carrier.figure.person if carrier.figure != null else null
	_check(
		carrier.figure != null and carrier.figure.carrying and person != null
			and person.hold == DotHumanoidFigure.Hold.GUN,
		"both arms are out under the prop",
		str(carrier.figure.describe()) if carrier.figure != null else "no figure"
	)
	carrier.carrying = false
	_shown = carrier.present_body(false, carrier.global_position, Color.WHITE)
	_check(carrier.figure != null and not carrier.figure.carrying and person != null
			and person.hold == DotHumanoidFigure.Hold.NONE,
		"and down again when it is let go")
	_finished()


## The HUD's health and clock are dot-ui's glance pieces, handed this world's numbers; health
## only in a final death; the plate above the chat box's full log. A headless viewport is
## 64 x 64, so the layout is checked as arithmetic on two bottom-anchored things, and looked
## at with `tools/shot.sh --view=finale`.
func _test_the_hud() -> void:
	_section("the HUD draws health and the clock through dot-ui")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 0.2)
	var me := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int(0.4 * TICK_RATE))

	var hud := WoHud.new()
	add_child(hud)
	hud.bind(game, me)
	hud._process(0.0)
	_check(
		game.phase == WoGame.Phase.COURSE and hud.strip.clock == DotScoreStrip.clock_text(game.seconds_left())
		and hud.strip.under_text() == hud._phase_line(),
		"on a course the strip shows the clock with the phase line under it",
		"%s / %s" % [hud.strip.clock, hud.strip.under_text()]
	)
	_check(hud.vitals.visible == game.config.health_enabled, "on a course the health bar shows while health is on")
	game.config.health_enabled = false
	hud._process(0.0)
	_check(not hud.vitals.visible, "and is hidden when health is off: nothing on a course can hurt you")
	game.config.health_enabled = true

	game.phase = WoGame.Phase.FINALE
	me.health.health = 17.4
	hud._process(0.0)
	_check(
		hud.vitals.visible and hud.vitals.number_text() == "18" and hud.vitals.is_low(),
		"in a final death DotVitals shows health, red at a quarter",
		"%s low=%s" % [hud.vitals.number_text(), str(hud.vitals.is_low())]
	)

	var chat := WoClient.new_chat()
	add_child(chat)
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var plate_bottom := -(hud.vitals.offset_top + hud.vitals.footprint().end.y)
	_check(
		plate_bottom >= log_top,
		"a full chat log stays under the health plate",
		"log reaches %.0f px off the bottom, the plate ends %.0f off it" % [log_top, plate_bottom]
	)
	chat.queue_free()

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var settings := WoSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	hud.follow_menu(settings.menu)
	var plate := hud.vitals.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7, "the HUD is dark by default, in the menu's theme", str(plate))
	var _t := settings.settings.set_value(&"ui_theme", &"contrast")
	var contrast: DotMenuPalette = settings.menu.palette()
	_check(contrast.id == &"contrast" and hud.vitals.colour(&"plate") == contrast.hud_plate and hud.strip.colour(&"text") == contrast.hud_text,
		"a theme picked in the menu reaches every piece at once")
	_check(hud.vitals.colour(&"highlight") == WoHud.AMBER and hud._field.get_theme_color(&"font_color") == contrast.hud_text,
		"keeping this game's amber, and the HUD's own lines follow it too")
	_t = settings.settings.set_value(&"ui_theme", &"midnight")
	settings.queue_free()

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 13 and FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 13, the weapon icons (requires.floor.json)",
		str(asks.get("dot_ui"))
	)
	hud.queue_free()
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := WoSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	_check(keys.key_for(&"dot_menu_weapon_next") == "Wheel down"
		and keys.key_for(&"dot_menu_weapon_previous") == "Wheel up",
		"the wheel is on the Controls page: up previous, down next",
		"%s / %s" % [keys.key_for(&"dot_menu_weapon_previous"), keys.key_for(&"dot_menu_weapon_next")])
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Wipeout",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: M opens the course list, and solo a choice
## changes the course now. The server's half (the owner's flag, the vote) is dot-vote's suite.
## Offline the world samples the local player's movement itself, so the client's buttons
## have to go onto that sample. They were stamped on the controller's command and then sampled
## over, and offline no trigger ever reached the world's gun (game-zombie-zone's play test).
func _test_offline_trigger() -> void:
	_section("offline, the client's trigger reaches the world's gun")
	var game := await _world()
	var me := game.add_player(&"local", "You", 0, true)
	await _step(game, 2)
	var client := WoClient.new()
	client.game = game
	client._adopt(me)
	client._firing = true
	me.simulate(game.current_tick() + 1, 1.0 / float(TICK_RATE))
	var pressed := game.weapon_command_for(me).is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_check(me.sampler != null and pressed, "the world's weapon command has the trigger the client holds")
	client.free()
	_finished()


func _test_the_map_menu() -> void:
	_section("M opens the course list, and solo a choice changes the course")
	var game := await _world(func(c: WoConfig) -> void: c.course_ids = PackedStringArray())
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 2)
	var round_before := game.match_node.round_number
	var settings := WoSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows := game.course_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one course to choose, the one playing marked", "%d courses" % rows.size())
	var _maps := settings.use_maps(game.course_rows, game.change_course_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	# The first row that is not the course being played, by its number on its page.
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	await _step(game, 2)
	_check(wanted != &"" and game.stage.id() == wanted and game.match_node.round_number == round_before + 1,
		"choosing one builds it now and starts a round on it", "%s, playing %s, phase %s, match %s" % [wanted, game.stage.id(), WoGame.Phase.keys()[game.phase], DotMatch.State.keys()[game.match_node.state]])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every
## model the weapons table names must be here. Sync it with zee-dot-weapons' tools/sync-art.sh.
func _test_the_weapon_art_is_vendored() -> void:
	_section("every model the weapon art table names is vendored in this game")
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_finished()


## The play test's weapons, from a pickup: the drawn rig was given the whole pack, so the slot
## held whatever was given last and never the gun the server fired; nothing counted the magazine;
## nothing said a shot had landed. Armed: with `give_everything` back the first check fails,
## without `correct_drawn` the fourth, without the HIT path the last.
func _test_the_drawn_gun() -> void:
	_section("an armed racer draws the server's gun, counted on the HUD, with a marker for a hit")
	var client: Node = (load("res://game/wo_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	for i in 8:
		await get_tree().process_frame
	var world: WoGame = client.get("game")
	var me: WoPlayer = client.get("player")
	var _armed := world.arm(me, ZeeWeaponIds.SMG)
	for i in 4:
		await get_tree().physics_frame

	var drawn: ZeeWeaponRig = client.get("weapons")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null and drawn != me.weapons
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same, "the drawn gun holds exactly the server's weapons, slot for slot", " ".join(held))

	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	var def := drawn.current_def() if drawn != null else null
	var expected := "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] if def != null else "?"
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and counter.count_text() == expected,
		"the HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])
	var icon_script: Script = load("res://game/wo_weapon_icons.gd")
	var icons: DotWeaponIconStyle = icon_script.get("shared")
	var icon_rect: TextureRect = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.visible and icon_rect.texture != null and icon_rect.texture == icons.texture(def.id),
		"the HUD draws the held gun's sprite over the counter, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and not icon_rect.visible, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.visible and icon_rect.get_global_rect().end.y <= counter.get_global_rect().position.y + 4.0,
		"the sprite sits above the ammunition plate, not on it")

	_check(counter.anchor_left == 1.0 and counter.anchor_top == 1.0 and counter.offset_top >= -180.0
		and counter.offset_bottom <= -100.0,
		"it sits bottom right, above the field line and clear of the chat and the health plate")

	var world_count := me.weapons.arsenal.current().magazine
	drawn.arsenal.current().magazine = maxi(world_count - 5, 0)
	client.set("_drawn_quiet", 0.0)
	for i in 10:
		await get_tree().physics_frame
	var early := drawn.arsenal.current().magazine
	for i in 60:
		await get_tree().physics_frame
	_check(early == maxi(world_count - 5, 0) and drawn.arsenal.current().magazine == world_count,
		"the drawn gun takes the server's count once quiet, and not before",
		"after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count])

	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), true, false)
	_check(marker != null and marker.alpha() > 0.9 and marker.kill, "a hit the world confirms flashes the marker, a kill's")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()
