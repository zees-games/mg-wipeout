extends GSGameCheckSuite

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoGame := preload("../game/wo_game.gd")

## What a stand-in asks of the course's hazards goes to gs-sim's `GSSimHazards` when the library is there, and it must
## answer as the script does, on every course, with the cull on and off, native_knock off, a rebuilt course and a field
## of stand-ins with knock_verify on; then the saving, timed native and script. [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails without it.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
const SEED := 4417
## Seeded knock asks per course, and path_clear runs.
const ASKS := 3000
const RUNS := 200
## The live round: stand-ins, the course, and its ticks; then the ticks timed each way.
const BOTS := 16
const LIVE_COURSE := "wo_first_splash"
const LIVE_TICKS := 1500
const BENCH_TICKS := 2000

var _entered := 0
var _done := 0
var _world: WoGame = null


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: native hazard knock")
	print("")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var ids: Array = []
	for id: StringName in catalogue.courses:
		if not _runs_entities(catalogue.courses[id]):
			ids.append(id)
	for id: StringName in catalogue.arenas:
		ids.append(id)
	ids.sort()

	_entered += 1
	print("every course and arena, built one after another: the kept spinner and tile indexes answer as the walk")
	await _kinds_section(catalogue, ids)
	_done += 1

	_entered += 1
	print("the library has the hazards")
	if not GSSim.has(&"hazards"):
		print("  gs-sim's hazards module is not loaded: the native half is skipped")
		var required := OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1"
		_check(not required, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_done += 1
		_report_sections(_entered, _done, 2, 4)
		return
	_check(WoCourse.native_knock, "WoCourse.native_knock is on without the game turning it on")
	_check(not WoCourse.knock_verify, "and knock_verify off")
	_done += 1

	_entered += 1
	print("every course and arena: seeded knocks and runs, native against the script")
	await _seeded_section(catalogue, ids)
	_done += 1

	_entered += 1
	print("native_knock off asks the script; a rebuilt course writes its table again")
	var doc: Dictionary = catalogue.courses[StringName(LIVE_COURSE)]
	var game := await _fresh_world(doc)
	var _built := game.build_stage(doc)
	var first: Variant = game.stage.hazards_native()
	WoCourse.native_knock = false
	_check(game.stage.hazards_native() == null, "off, there is no native table")
	WoCourse.native_knock = true
	var _rebuilt := game.build_stage(doc)
	var second: Variant = game.stage.hazards_native()
	_check(first != null and second != null and first != second, "a new build makes a new table")
	_done += 1

	_entered += 1
	print("a field racing with knock_verify: the script beside every live ask")
	game = await _round(doc)
	WoCourse.knock_checked = 0
	WoCourse.knock_differ = 0
	WoCourse.knock_verify = true
	for i in range(LIVE_TICKS):
		game.simulate(TICK)
		if i % 512 == 0:
			await get_tree().process_frame
	WoCourse.knock_verify = false
	print("  %d asks checked, %d differ" % [WoCourse.knock_checked, WoCourse.knock_differ])
	_check(WoCourse.knock_checked > 100, "the stand-ins asked", str(WoCourse.knock_checked))
	_check(WoCourse.knock_differ == 0, "and no ask differs", str(WoCourse.knock_differ))
	_done += 1

	_entered += 1
	print("the cost: a %d-bot round's ticks, native and script alternated" % BOTS)
	await _cost_section(doc)
	_done += 1

	if _world != null:
		remove_child(_world)
		_world.free()
		_world = null
	_report_sections(_entered, _done, 6, 13)


func _seeded_section(catalogue: WoCatalogue, ids: Array) -> void:
	var asked := 0
	var hits := 0
	var runs := 0
	var blocked := 0
	var hazards := 0
	var differ: Array[String] = []
	var tables: Array[String] = []
	for id: StringName in ids:
		var doc: Dictionary = catalogue.courses.get(id, catalogue.arenas.get(id, {}))
		var game := await _fresh_world(doc)
		var _built := game.build_stage(doc)
		var stage: WoCourse = game.stage
		var native: Variant = stage.hazards_native()
		var want := 0
		for piece: Dictionary in stage.pieces:
			want += 1 if bool(piece["hazard"]) else 0
		hazards += want
		if native == null or int(native.count()) != want:
			tables.append("%s: %s of %d" % [id, "none" if native == null else str(native.count()), want])
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(String(id)) ^ SEED
		var spots := _spots(stage)
		for ask in range(ASKS):
			var feet: Vector3 = spots[rng.randi_range(0, spots.size() - 1)] + Vector3(
				rng.randf_range(-6.0, 6.0), rng.randf_range(-1.5, 2.5), rng.randf_range(-6.0, 6.0))
			var tick := rng.randi_range(0, 64 * 120)
			var crouched := rng.randf() < 0.3
			var limits: Vector3 = [Vector3(1.0, 1.0, 1.0), Vector3(8.0, 22.0, 5.5),
				Vector3(rng.randf_range(0.0, 10.0), rng.randf_range(10.0, 40.0), rng.randf_range(0.0, 8.0))][ask % 3]
			for cull in [true, false]:
				stage.cull_hazards = cull
				var script := stage.knock(feet, crouched, tick, limits)
				var got: Vector3 = stage.hazards_native().knock(feet, crouched, tick, limits)
				asked += 1
				hits += 1 if script != Vector3.ZERO else 0
				if got != script and differ.size() < 8:
					differ.append("%s %s tick %d%s cull %s: native %s, script %s" % [
						id, feet, tick, " crouched" if crouched else "", cull, got, script])
		stage.cull_hazards = true
		var route: Array = stage.route() if stage.is_course() else []
		for _run_index in range(RUNS if route.size() >= 2 else 0):
			var a: int = rng.randi_range(0, route.size() - 2)
			var from: Vector3 = (route[a] as Dictionary)["at"]
			var to: Vector3 = (route[mini(a + rng.randi_range(1, 3), route.size() - 1)] as Dictionary)["at"]
			var tick := rng.randi_range(0, 64 * 120)
			var speed := rng.randf_range(3.0, 12.0)
			var margin: float = [0.5, 0.0, rng.randf_range(0.0, 2.0)][_run_index % 3]
			var script := stage.path_clear_script(from, to, tick, speed, margin)
			var got: bool = native.path_clear(from, to, tick, speed, margin)
			runs += 1
			blocked += 0 if script else 1
			if got != script and differ.size() < 8:
				differ.append("%s run %s to %s tick %d speed %.2f: native %s, script %s" % [id, from, to, tick, speed, got, script])
	print("  %d courses, %d hazards; %d knocks asked (%d hit), %d runs (%d blocked)" % [ids.size(), hazards, asked, hits, runs, blocked])
	_check(tables.is_empty(), "every course's hazards are in its native table", "; ".join(tables))
	_check(asked > 0 and hits >= asked / 200, "the asks hit hazards often enough to mean something", "%d of %d" % [hits, asked])
	_check(runs > 0 and blocked > 0 and blocked < runs, "and the runs are both clear and blocked", "%d of %d blocked" % [blocked, runs])
	_check(differ.is_empty(), "the native knock and path_clear answer as the script does", "; ".join(differ))


## [method WoCourse.high_arm_near], [method WoCourse.tile_cell] and [method WoCourse.tile_columns] walk the kept spinners
## and tile grids, not every piece: on every course built in one world, seeded points answer as the walk over every
## piece does. Then the cost of each, kept and walked, alternated.
func _kinds_section(catalogue: WoCatalogue, ids: Array) -> void:
	var game := await _fresh_world(catalogue.courses[StringName(LIVE_COURSE)])
	var asked := 0
	var near := 0
	var on_tiles := 0
	var differ: Array[String] = []
	var spent := {"kept": 0, "walk": 0}
	var timed := {"kept": 0, "walk": 0}
	for id: StringName in ids:
		var doc: Dictionary = catalogue.courses.get(id, catalogue.arenas.get(id, {}))
		var _built := game.build_stage(doc)
		var stage: WoCourse = game.stage
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(String(id)) ^ SEED
		var spots := _spots(stage)
		for piece: Dictionary in stage.pieces:
			var kind := str(piece["kind"])
			if kind == "spinner":
				spots.append((piece["spec"] as Dictionary)["at"])
			elif kind == "tiles":
				spots.append((piece["node"] as Node3D).transform.origin)
		for ask in range(ASKS):
			var at: Vector3 = spots[rng.randi_range(0, spots.size() - 1)] + Vector3(
				rng.randf_range(-8.0, 8.0), rng.randf_range(-3.5, 3.5), rng.randf_range(-8.0, 8.0))
			var radius := rng.randf_range(0.0, 2.0)
			var kept_high := stage.high_arm_near(at, radius)
			var kept_cell := stage.tile_cell(at)
			var kept_columns := stage.tile_columns(at)
			var walk_high := _high_arm_walk(stage, at, radius)
			var walk_cell := _tile_cell_walk(stage, at)
			var walk_columns := _tile_columns_walk(stage, at)
			asked += 1
			near += 1 if walk_high else 0
			on_tiles += 0 if walk_cell.is_empty() else 1
			if (kept_high != walk_high or kept_cell != walk_cell or kept_columns != walk_columns) and differ.size() < 8:
				differ.append("%s %s r %.2f: kept %s %s %s, walk %s %s %s" % [id, at, radius,
					kept_high, kept_cell, kept_columns, walk_high, walk_cell, walk_columns])
			var arm: String = "kept" if ask % 2 == 0 else "walk"
			var started := Time.get_ticks_usec()
			if arm == "kept":
				var _a := stage.high_arm_near(at, radius)
				var _b := stage.tile_cell(at)
			else:
				var _a := _high_arm_walk(stage, at, radius)
				var _b := _tile_cell_walk(stage, at)
			spent[arm] += Time.get_ticks_usec() - started
			timed[arm] += 1
		await get_tree().process_frame
	print("  %d courses; %d points asked (%d by a high arm, %d on tiles)" % [ids.size(), asked, near, on_tiles])
	print("  high_arm_near + tile_cell: kept %.3f us, walk %.3f us a pair" % [
		float(spent["kept"]) / maxi(1, timed["kept"]), float(spent["walk"]) / maxi(1, timed["walk"])])
	_check(near > 0 and on_tiles > 0, "the points are near high arms and on tiles", "%d near, %d on tiles" % [near, on_tiles])
	_check(near < asked and on_tiles < asked, "and off them", "%d near, %d on tiles of %d" % [near, on_tiles, asked])
	_check(differ.is_empty(), "the kept indexes answer as the walk over every piece", "; ".join(differ))


## [method WoCourse.high_arm_near] as it was, over every piece.
func _high_arm_walk(stage: WoCourse, at: Vector3, radius: float) -> bool:
	for piece: Dictionary in stage.pieces:
		if str(piece["kind"]) != "spinner":
			continue
		var spec: Dictionary = piece["spec"]
		if float(spec.get("arm_height", 1.0)) < 1.1:
			continue
		var hub: Vector3 = spec["at"]
		if Vector2(at.x - hub.x, at.z - hub.z).length() <= float(spec["arm_length"]) + radius:
			return true
	return false


## [method WoCourse.tile_cell] as it was, over every piece.
func _tile_cell_walk(stage: WoCourse, point: Vector3) -> Dictionary:
	for index in range(stage.pieces.size()):
		var piece: Dictionary = stage.pieces[index]
		if str(piece["kind"]) != "tiles":
			continue
		var spec: Dictionary = piece["spec"]
		var local := (piece["node"] as Node3D).transform.affine_inverse() * point
		var cols := int(spec["cols"])
		var rows := int(spec["rows"])
		var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
		var col := int(roundf(local.x / pitch + float(cols - 1) * 0.5))
		var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))
		if col >= 0 and col < cols and row >= 0 and row < rows and absf(local.y) < 3.0:
			return {"piece": index, "row": row, "col": col}
	return {}


## [method WoCourse.tile_columns] as it was, over every piece.
func _tile_columns_walk(stage: WoCourse, point: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for piece: Dictionary in stage.pieces:
		if str(piece["kind"]) != "tiles":
			continue
		var spec: Dictionary = piece["spec"]
		var root: Node3D = piece["node"]
		var local := root.transform.affine_inverse() * point
		var cols := int(spec["cols"])
		var rows := int(spec["rows"])
		var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
		var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))
		if row < 0 or row >= rows or absf(local.y) > 3.0 \
				or absf(local.x) > float(cols) * pitch * 0.5 + 0.5:
			continue
		for col in range(cols):
			var x := (float(col) - float(cols - 1) * 0.5) * pitch
			out.append(root.transform.basis * Vector3(x - local.x, 0.0, 0.0))
		out.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.length() < b.length())
		return out
	return out


func _cost_section(doc: Dictionary) -> void:
	var game := await _round(doc)
	var spent := {"native": [], "script": []}
	for i in range(BENCH_TICKS):
		var mode: String = "native" if (i / 2) % 2 == 0 else "script"
		WoCourse.native_knock = mode == "native"
		var started := Time.get_ticks_usec()
		game.simulate(TICK)
		(spent[mode] as Array).append(Time.get_ticks_usec() - started)
		if i % 512 == 0:
			await get_tree().process_frame
	WoCourse.native_knock = true
	var lines: Array[String] = []
	for mode: String in ["native", "script"]:
		var times: Array = spent[mode]
		times.sort()
		var total := 0
		for t: int in times:
			total += t
		lines.append("%s mean %.3f ms median %.3f ms p95 %.3f ms" % [mode, total / 1000.0 / times.size(),
			times[times.size() / 2] / 1000.0, times[int(times.size() * 0.95)] / 1000.0])
	print("  " + "; ".join(lines))


## Where to ask from: every route point and every hazard's centre.
func _spots(stage: WoCourse) -> Array:
	var out: Array = []
	if stage.is_course():
		for point: Dictionary in stage.route():
			out.append(point["at"])
	for piece: Dictionary in stage.pieces:
		if bool(piece["hazard"]):
			out.append(stage._hazard_centre(piece))
	if out.is_empty():
		out.append(Vector3.ZERO)
	return out


func _runs_entities(doc: Dictionary) -> bool:
	for piece: Dictionary in doc.get("pieces", []):
		if bool(piece.get("io", false)):
			return true
	return false


func _round(doc: Dictionary) -> WoGame:
	var game := await _fresh_world(doc)
	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900100 + i)), "Bot %d" % (i + 1))
		bot.is_bot = true
	game.start()
	return game


func _fresh_world(doc: Dictionary) -> WoGame:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := WoConfig.new()
	config.knock_damage_per_speed = 0.0
	config.fall_damage_per_metre = 0.0
	config.courses_per_round = 1
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray([str(doc["id"])]) if str(doc["kind"]) == "course" \
		else PackedStringArray(["wo_practice"])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	game.draw_world = false
	add_child(game)
	game.set_physics_process(false)
	_world = game
	await get_tree().physics_frame
	return game
