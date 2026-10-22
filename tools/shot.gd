extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
##
##   tools/shot.sh                                  # a player's own eyes, a few seconds in
##   tools/shot.sh --view=course --wo-course-ids=wo_spin_cycle
##   tools/shot.sh --view=start                     # the start pad, from behind the runners
##   tools/shot.sh --view=hazard                    # the first thing that throws you, close
##   tools/shot.sh --view=race --seconds=25         # the field mid-race, over the second runner's shoulder
##   tools/shot.sh --view=crowd --seconds=6         # the first grandstand and its crowd
##   tools/shot.sh --view=duck --seconds=30 --wo-course-ids=wo_the_sweeper   # a stand-in ducking, close
##   tools/shot.sh --view=falls --seconds=3 --wo-course-ids=wo_punch_alley   # the first water/slime fall
##   tools/shot.sh --view=tiles --wo-course-ids=wo_trapdoor_run   # drop-tiles, warning in red
##   tools/shot.sh --view=tiles --grid=2 --wo-course-ids=wo_trapdoor_run   # the third grid
##   tools/shot.sh --view=tour --wo-course-ids=wo_dans_course   # <out>_overview.png and _1 to _3 along the route
##   tools/shot.sh --view=third                     # third person, mid-course
##   tools/shot.sh --view=cover                     # the loading cover, before it lifts
##   tools/shot.sh --view=arena --arena=wo_arena_pit   # an arena, from above
##   tools/shot.sh --view=finale                    # a real final death, from a finisher's eyes
##   tools/shot.sh --view=third --ballot            # the course vote's ballot, mid-vote
##
## Any `--wo-*` is the game's own configuration (see `WoConfig`), because `WoClient` reads it.

const WoClient := preload("../game/wo_client.gd")
const WoGame := preload("../game/wo_game.gd")
const WoVote := preload("../game/wo_vote.gd")
const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")

var _view := "eyes"
var _seconds := 4.0
var _out := "res://screenshots/shot.png"
var _arena := ""
var _client: Node = null

## `--board`: the Tab scoreboard held open over the frame.
var _board: bool = false

## `--console=LINE`: typed at the player's console as the round starts (`net_stat 3`), so
## the frame shows what the line does, through the same path a player's typing takes.
var _console_line := ""

## `--ballot`: the course vote's ballot over the frame, as the client shell draws it — a
## [DotBallotPanel] down the right-hand side — fed the state this game's own [WoVote] builds,
## with a few votes cast.
var _ballot: bool = false

## `--workshop`: a fixture map pack in the shared content index first (solo), so the ballot
## lists it as "Name [Pack]".
var _workshop: bool = false

## `--grid=N`: which grid of tiles the tiles view looks at, counting from 0 along the course.
var _grid := 0

## `--look=x,y,z,tx,ty,tz`: the look view puts a free camera at the first point, facing the second.
var _look := PackedFloat64Array()


## --view=maps: a fixture course pack in the shared [DotContentIndex], as the solo shell leaves
## one after a subscribed pack mounts, so the M menu shows what a player would see. The pack's
## course is the practice course under another name, written to user://.
func _subscribe_fixture() -> void:
	var dir := "user://ws_shot_wo/"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "fixture_hill"
	doc["name"] = "Fixture Hill"
	doc["blurb"] = "From the Workshop."
	var file := FileAccess.open(dir + "hill.json", FileAccess.WRITE)
	file.store_string(WoCourseDoc.to_json(doc))
	file.close()
	var index := DotContentIndex.shared()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var _added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": dir,
		"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
		"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "fixture_hill", "name": "Fixture Hill", "scene": "hill.json", "map_kind": "obstacle"},
			{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "hill.json", "map_kind": "surf"},
		]},
	})


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg == "--board":
			_board = true
		elif arg == "--ballot":
			_ballot = true
		elif arg == "--workshop":
			_workshop = true
		elif arg.begins_with("--arena="):
			_arena = arg.trim_prefix("--arena=")
		elif arg.begins_with("--look="):
			_look = PackedFloat64Array(Array(arg.trim_prefix("--look=").split(",")).map(func(n): return float(n)))
		elif arg.begins_with("--grid="):
			_grid = arg.trim_prefix("--grid=").to_int()
		elif arg.begins_with("--console="):
			_console_line = arg.trim_prefix("--console=")

	if _view == "maps" or _view == "pack":
		_subscribe_fixture()

	_client = WoClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	_client.set("third_person", _view == "third")
	add_child(_client)
	# --view=cover: the loading cover dot-game's DotGameClient puts up first, before it lifts.
	if _view == "cover":
		for _i in 2:
			await RenderingServer.frame_post_draw
		var platform: DotGameClient = _client.get("platform")
		print("cover %s" % ("lifted" if platform.is_shown() else "up"))
		var cover_path := ProjectSettings.globalize_path(_out)
		DirAccess.make_dir_recursive_absolute(cover_path.get_base_dir())
		print("saved %s: %s" % [_out, error_string(_client.get_viewport().get_texture().get_image().save_png(cover_path))])
		get_tree().quit(0)
		return
	_run.call_deferred()


func _run() -> void:
	var game: WoGame = _client.get("game")
	game.config.warmup_seconds = 0.0
	game.config.countdown_seconds = 1.0

	var console: DotConsoleController = _client.get("console")
	if _console_line != "" and console != null:
		var _ran := console.submit(_console_line)

	match _view:
		"arena":
			await _frames(4)
			var doc: Dictionary = game.catalogue.arenas.get(StringName(_arena), {}) if _arena != "" \
				else game.catalogue.pick_arena(game.config.arena_ids, DotRandomStream.new(3))
			if doc.is_empty():
				doc = game.catalogue.pick_arena(PackedStringArray(), DotRandomStream.new(3))
			var _built := game.build_stage(doc)
			await _frames(6)
			_overview(game, 0.9)
		"maps":
			# M: the solo course list, with the Workshop's course among the game's own.
			# Past the load gate's cover, which holds the screen for the first seconds.
			await _seconds_of(6.0)
			var settings: Object = _client.get("settings")
			var menu: Variant = settings.get("menu")
			menu.call(&"open_maps")
			var picker: Variant = menu.get("picker")
			if picker != null:
				# Past the last row and back: the fixture sorts after the shipped ids of its letter.
				var rows := game.course_rows()
				for i in range(rows.size()):
					if str(rows[i]["id"]) == "fixture_hill":
						picker.call(&"turn", 99)
						picker.call(&"turn", i - rows.size() + 1)
			await _seconds_of(_seconds)
		"pack":
			# A subscribed pack's course, chosen the way the M menu does, built and looked at.
			# Past the load gate's cover, which holds the screen for the first seconds.
			await _seconds_of(6.0)
			var chosen := game.change_course_now(&"fixture_hill")
			print("chosen: %s" % chosen.ok)
			await _seconds_of(2.0)
			print("built: %s" % game.stage.id())
			_overview(game, 1.3)
		"finale":
			await _seconds_of(game.config.countdown_seconds + 1.5)
			# Everybody across, so the course closes into a final death the way a real one does.
			for id: StringName in game.players:
				var runner = game.players[id]
				if runner.finished:
					continue
				game._finish_count += 1
				runner.finished = true
				runner.place = game._finish_count
			await _seconds_of(game.config.handover_seconds + 1.5)
		"course":
			await _seconds_of(7.0)
			# Further out than the straight courses needed: a course that turns is as wide as it
			# is long, and at 1.0 the overview of a switchback or a spiral was half of it.
			_overview(game, 1.3)
		"tour":
			# An overview and three frames along the course, written beside `--out` as
			# `<out>_overview.png`, `_1`, `_2`, `_3`. Past the load gate's cover first: the
			# overview of a course used to show nothing but the cover, because it was taken six
			# frames in and the cover holds the screen for the first seconds.
			await _seconds_of(maxf(_seconds, 7.0))
			var base := _out.trim_suffix(".png")
			_overview(game, 1.0)
			await _frames(4)
			_save("%s_overview.png" % base)
			var route: Array = game.stage.route()
			for n in range(1, 4):
				var index := clampi(int(float(route.size()) * float(n) / 4.0), 0, route.size() - 2)
				var here: Vector3 = (route[index] as Dictionary)["at"]
				var ahead: Vector3 = (route[index + 1] as Dictionary)["at"]
				var way := Vector3(ahead.x - here.x, 0.0, ahead.z - here.z)
				way = way.normalized() if way.length() > 0.01 else Vector3(0.0, 0.0, -1.0)
				var camera := _free_camera()
				camera.look_at_from_position(here - way * 8.0 + Vector3(0.0, 5.0, 0.0), here + way * 9.0)
				await _frames(4)
				_save("%s_%d.png" % [base, n])
		"look":
			await _seconds_of(maxf(_seconds, 7.0))
			var camera := _free_camera()
			if _look.size() == 6:
				camera.look_at_from_position(Vector3(_look[0], _look[1], _look[2]), Vector3(_look[3], _look[4], _look[5]))
		"start":
			await _seconds_of(0.6)
			var camera := _free_camera()
			var start: Vector3 = game.course_doc["start"]["at"]
			camera.look_at_from_position(start + Vector3(0, 5.5, 10.0), start + Vector3(0, 0, -14.0))
		"tiles":
			await _seconds_of(_seconds)
			var camera := _free_camera()
			var seen := 0
			for piece in game.stage.pieces:
				if str(piece["kind"]) == "tiles":
					if seen == _grid:
						var at: Vector3 = piece["spec"]["at"]
						camera.look_at_from_position(at + Vector3(6.0, 6.0, 7.0), at)
						break
					seen += 1
		"race":
			# The field mid-race, from over the shoulder of whoever is leading: the stand-ins
			# spread out over the course, the stands and the show round them.
			await _seconds_of(game.config.countdown_seconds + _seconds)
			var order := game.race_order()
			var leader: Node3D = game.players.get(order[mini(1, order.size() - 1)]) if not order.is_empty() else null
			var camera := _free_camera()
			if leader != null:
				# Behind and to the right of the way the runner faces, not of -Z: a course turns.
				var at := leader.global_position
				var facing := Basis(Vector3.UP, deg_to_rad(float(leader.controller.state.yaw)))
				camera.look_at_from_position(at + facing * Vector3(7.0, 6.0, 11.0), at + facing * Vector3(0.0, 0.5, -10.0))
		"duck":
			# The first stand-in ducking under a high arm, close and from the side: proves the
			# person is drawn crouched when the runner is (`WoPlayer.present_body`'s motion).
			# `--seconds` is how long to wait for one.
			await _seconds_of(game.config.countdown_seconds)
			var waited := 0.0
			var ducking: Node3D = null
			while ducking == null and waited < _seconds:
				await _frames(1)
				waited += get_process_delta_time()
				for id: StringName in game.players:
					var runner = game.players[id]
					if runner.controller != null and runner.controller.state.crouch_fraction > 0.9:
						ducking = runner
						break
			var camera := _free_camera()
			if ducking != null:
				await _frames(2)
				var at := ducking.global_position
				var facing := Basis(Vector3.UP, deg_to_rad(float(ducking.controller.state.yaw)))
				camera.look_at_from_position(at + facing * Vector3(3.2, 1.4, -0.6), at + Vector3(0.0, 0.7, 0.0))
				print("duck: %s crouched after %.1f s" % [ducking.name, waited])
			else:
				print("duck: nobody ducked in %.1f s" % waited)
		"crowd":
			# A grandstand and its crowd, from the course: the first stands the course has.
			await _seconds_of(game.config.countdown_seconds + _seconds)
			var camera := _free_camera()
			for item: Dictionary in game.course_doc.get("dressing", []):
				if str(item["kind"]) == "stands":
					var at: Vector3 = item["at"]
					var facing := Basis(Vector3.UP, deg_to_rad(float(item["yaw"]))) * Vector3(0.0, 0.0, -1.0)
					camera.look_at_from_position(at + facing * 9.0 + Vector3(0.0, 2.5, 6.0), at + Vector3(0.0, 2.0, 0.0))
					break
		"falls":
			# The first curtain of water or slime, from the deck in front of it, mid-pour.
			await _seconds_of(_seconds)
			var camera := _free_camera()
			for piece in game.stage.pieces:
				if str(piece["kind"]) == "fall":
					var at: Vector3 = piece["spec"]["at"]
					camera.look_at_from_position(at + Vector3(3.5, 2.6, 7.5), at + Vector3(0.0, 1.6, 0.0))
					break
		"knockout":
			# A stand-in at 5 hp struck by the first spinner: out of the round, and the body
			# goes up as a ragdoll. The frame is a moment into the flight, from the side.
			await _seconds_of(game.config.countdown_seconds + 0.5)
			var victim = null
			for id: StringName in game.players:
				if game.players[id].is_bot:
					victim = game.players[id]
					break
			var hub := _first_hazard(game)
			for piece in game.stage.pieces:
				if str(piece["kind"]) == "spinner":
					hub = piece["spec"]["at"]
					break
			if victim != null:
				victim.health.health = 5.0
				victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
				var waited := 0.0
				while not victim.watching and waited < 6.0:
					await _frames(1)
					waited += get_process_delta_time()
				print("knockout: out=%s death=%s" % [victim.watching, victim.death.describe() if victim.death != null else "none"])
				await _seconds_of(0.35)
			var camera := _free_camera()
			var bodies: Array = (_client.get("ragdolls") as DotPlayerRagdolls).live()
			var focus := hub + Vector3(3.0, 3.0, 0.0)
			if not bodies.is_empty():
				# The ragdoll node itself sits at the origin; its parts are the rigid bodies under it.
				var parts: Array[Node] = (bodies[0] as Node).find_children("*", "RigidBody3D", true, false)
				if not parts.is_empty():
					focus = (parts[0] as Node3D).global_position
			print("knockout: %d ragdolls, flight at %s (spinner %s)" % [bodies.size(), focus, hub])
			camera.look_at_from_position(focus + Vector3(7.0, 3.0, 7.0), focus)
		"hurt":
			# The local player at 60 health, just hit: the health bar and the red flash.
			await _seconds_of(game.config.countdown_seconds + 0.6)
			var me = _client.get("player")
			if me != null:
				me.health.health = 85.0
				await _frames(2)
				me.health.health = 55.0
				await _frames(2)
		"hazard":
			await _seconds_of(_seconds)
			var hazard := _first_hazard(game)
			var camera := _free_camera()
			camera.look_at_from_position(hazard + Vector3(7.0, 5.0, 7.0), hazard + Vector3(0, 0.6, 0))
		_:
			await _seconds_of(_seconds)

	if _board:
		var tab := InputEventKey.new()
		tab.physical_keycode = KEY_TAB
		tab.pressed = true
		_client.settings.menu.handle_event(tab)
	if _ballot:
		_show_ballot(game)
		# The voters' discs slide to the row they chose; a frame too soon catches one between.
		await _seconds_of(1.0)
	await _frames(3)
	var saved := _save(_out)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


func _save(out: String) -> int:
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return image.save_png(path)


## A real ballot from this game's vote: every course the client has, four voters, three of
## whom have voted, drawn the way the client shell's notice overlay draws a `map_ballot`.
func _show_ballot(game: WoGame) -> void:
	var names := {&"1": "you", &"2": "bo", &"3": "quiet_one", &"4": "ana"}
	var states: Array = []
	if _workshop:
		var index := DotContentIndex.shared()
		index.set_session(DotContentIndex.SESSION_SOLO)
		var _added := index.add_pack({
			"content_id": "fixture/hills", "version": "1.0.0", "prefix": "res://fixture/",
			"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
			"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
				{"kind": "map", "id": "fixture_hill", "name": "Fixture Hill", "scene": "hill.tscn", "map_kind": "obstacle"},
			]},
		})
	var vote := WoVote.new()
	vote.config_path = ""
	vote.courses_fn = func() -> Array:
		var out: Array = []
		for id in game.catalogue.playable_courses(PackedStringArray()):
			out.append([id, str((game.catalogue.courses.get(id, {}) as Dictionary).get("name", id))])
		# A ballot shows five at random; with the fixture, three courses leave room for it.
		return out.slice(0, 3) if _workshop else out
	vote.voters_fn = func() -> Array: return names.keys()
	vote.people_fn = func(voter: StringName) -> Dictionary: return {"name": names.get(voter, "?"), "avatar": ""}
	vote.ballot_fn = func(state: Dictionary) -> void: states.append(state)
	add_child(vote)
	var _set := vote.setup()
	vote.note_course(StringName(str(game.course_doc.get("id", ""))))
	var _opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	var options := vote.director.ballot.option_ids()
	var _a := vote.director.cast_one(&"1", options[0])
	var _b := vote.director.cast_one(&"2", options[1 % options.size()])
	var _c := vote.director.cast_one(&"3", options[0])
	vote.feed.poll()

	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var box := VBoxContainer.new()
	box.anchor_left = 1.0
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -376.0
	box.offset_right = -16.0
	box.offset_top = 110.0
	box.offset_bottom = -16.0
	layer.add_child(box)
	var panel := DotBallotPanel.new()
	panel.ui_theme = DotUiTheme.space()
	panel.local_voter = "1"
	box.add_child(panel)
	panel.show_state(states.back() if not states.is_empty() else {})


func _overview(game: WoGame, reach_scale: float) -> void:
	var box: AABB = game.stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 14.0) * reach_scale
	var camera := _free_camera()
	camera.look_at_from_position(centre + Vector3(reach * 0.75, reach * 0.6 + 6.0, reach * 0.35), centre)


func _first_hazard(game: WoGame) -> Vector3:
	for piece in game.stage.pieces:
		if bool(piece["hazard"]):
			var spec: Dictionary = piece["spec"]
			return spec.get("at", spec.get("pivot", Vector3.ZERO))
	return Vector3.ZERO


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	camera.current = true
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
