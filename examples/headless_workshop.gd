extends Node

## What a subscribed map pack does to this game's course list and course vote, against a fixture
## [DotContentIndex] and never the process's shared one.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workshop.tscn
## [/codeblock]
##
## A pack's map is a course document (the JSON `courses/` holds). Solo lists and plays it as
## "Name [Pack]", an online session lists none, a map kind the game does not accept is left out,
## and the game's own ids win.

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")
const WoVote := preload("../game/wo_vote.gd")

const SECTIONS := 6
const MAP := &"fixture_hill"
const OWN := &"wo_practice"
const DIR := "user://ws_fixture_wo/"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-wipeout — Workshop courses")
	_write_fixture()
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids()
	await _test_vote()
	await _test_round()
	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS else 0)


func _write_fixture() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = String(MAP)
	doc["name"] = "Fixture Hill"
	_write("hill.json", WoCourseDoc.to_json(doc))
	_write("broken.json", "{\"kind\": \"course\", \"pieces\": [")
	_write("arena.json", WoCourseDoc.to_json(WoCatalogue.practice_arena()))


func _write(file_name: String, text: String) -> void:
	var file := FileAccess.open(DIR + file_name, FileAccess.WRITE)
	file.store_string(text)
	file.close()


## A pack with a course, a map of a kind the game does not accept, a map that claims the
## built-in's id, and an accepted-kind map whose document is an arena (refused).
func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": DIR,
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Hill", "scene": "hill.json", "map_kind": "obstacle"},
			{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "hill.json", "map_kind": "surf"},
			{"kind": "map", "id": String(OWN), "name": "Not The Practice", "scene": "hill.json", "map_kind": "obstacle"},
			{"kind": "map", "id": "fixture_broken", "name": "Fixture Broken", "scene": "broken.json", "map_kind": "obstacle"},
			{"kind": "map", "id": "fixture_arena", "name": "Fixture Arena", "scene": "arena.json", "map_kind": "race"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


func _catalogue(index: DotContentIndex) -> WoCatalogue:
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	catalogue.follow_content(index, WoCatalogue.accepted_map_kinds())
	return catalogue


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	var kinds := WoCatalogue.accepted_map_kinds()
	_check(kinds == PackedStringArray(["obstacle", "race"]), "provides.json accepts obstacle and race", str(kinds))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "and only maps", str(accepts))
	_completed += 1


func _test_solo() -> void:
	_entered += 1
	print("")
	print("solo")
	var catalogue := _catalogue(_index(DotContentIndex.SESSION_SOLO))
	_check(catalogue.playable_courses(PackedStringArray()).has(MAP), "the accepted map is playable")
	_check(catalogue.label_of(MAP) == "Fixture Hill [Fixture Pack]", "its label names the pack", catalogue.label_of(MAP))
	_check(not catalogue.courses.has(&"fixture_run"), "a map kind the game does not accept is filtered out")
	_check(not catalogue.courses.has(&"fixture_arena") and catalogue.refused.size() == 2,
		"an arena document and a torn one are refused, not played", str(catalogue.refused))
	_check((catalogue.courses[MAP].get("pieces", []) as Array).size() > 0, "and it is a whole document, with its pieces")
	_check("\n".join(catalogue.describe_lines()).contains("Fixture Hill [Fixture Pack]"), "wo_courses lists it as Name [Pack]")
	var next := catalogue.next_course(PackedStringArray([String(MAP)]), false, null, &"")
	_check(next.get("id") == String(MAP), "and it can be drawn as the next course")
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var catalogue := _catalogue(index)
	_check(catalogue.playable_courses(PackedStringArray()).has(MAP), "listed while the index is solo")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(not catalogue.playable_courses(PackedStringArray()).has(MAP), "gone from the same catalogue when the session turns online")
	_check(not catalogue.courses.has(MAP), "and from its documents")
	index.set_session(DotContentIndex.SESSION_SOLO)
	_check(catalogue.playable_courses(PackedStringArray()).has(MAP), "back when it turns solo again")
	var late := _index(DotContentIndex.SESSION_SOLO)
	late.set_session(DotContentIndex.SESSION_ONLINE)
	_check(not _catalogue(late).playable_courses(PackedStringArray()).has(MAP), "a catalogue built online never lists it")
	_completed += 1


func _test_ids() -> void:
	_entered += 1
	print("")
	print("the game's own ids win")
	var catalogue := _catalogue(_index(DotContentIndex.SESSION_SOLO))
	_check(catalogue.courses[OWN].get("name") == "Practice Run" and not catalogue.is_workshop(OWN),
		"a pack map claiming wo_practice does not replace the built-in")
	_completed += 1


func _labels(vote: WoVote) -> PackedStringArray:
	var out := PackedStringArray()
	for choice in vote.source.choices():
		out.append(choice.label())
	return out


func _test_vote() -> void:
	_entered += 1
	print("")
	print("the ballot")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var catalogue := _catalogue(index)
	var vote := WoVote.new()
	vote.config_path = ""
	vote.content_index = index
	vote.courses_fn = func() -> Array:
		var out: Array = []
		for id in catalogue.playable_courses(PackedStringArray()):
			if not catalogue.is_workshop(id):
				out.append([id, str(catalogue.courses[id].get("name", id))])
		return out
	add_child(vote)
	var _set_up := vote.setup()
	var own := ""
	for id in catalogue.playable_courses(PackedStringArray()):
		if not catalogue.is_workshop(id):
			own = str(catalogue.courses[id].get("name", id))
			break
	var labels := _labels(vote)
	_check(labels.has("Fixture Hill [Fixture Pack]"), "the solo ballot lists the pack map as Name [Pack]", str(labels))
	_check(labels.count("Fixture Hill [Fixture Pack]") == 1, "once")
	_check(not labels.has("Fixture Run [Fixture Pack]"), "and not a kind the game does not accept")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	labels = _labels(vote)
	_check(not labels.has("Fixture Hill [Fixture Pack]"), "online the same ballot lists none of it", str(labels))
	_check(labels.has(own), "and still has the game's own", "%s in %s" % [own, str(labels)])
	vote.queue_free()
	await get_tree().process_frame
	_completed += 1


## A solo world chooses the pack course in the M menu's own call and a round starts on it.
func _test_round() -> void:
	_entered += 1
	print("")
	print("a round on the pack course")
	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.courses_per_round = 1
	var game := WoGame.new()
	game.config = config
	game.tick_rate = 30
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	game.catalogue.follow_content(_index(DotContentIndex.SESSION_SOLO), WoCatalogue.accepted_map_kinds())
	var rows: Array = game.course_rows()
	_check(rows.any(func(r: Dictionary) -> bool: return str(r["id"]) == String(MAP) and str(r["name"]).contains("[Fixture Pack]")),
		"the M menu's rows list it as Name [Pack]")
	var refused := game.change_course_now(&"fixture_broken")
	_check(not refused.ok, "a refused document cannot be chosen")
	var chosen := game.change_course_now(MAP)
	_check(chosen.ok, "the pack course can be chosen", str(chosen.error.message) if not chosen.ok else "")
	game.start()
	for _i in range(5):
		game.simulate(1.0 / 30.0)
		await get_tree().physics_frame
	_check(game.stage.id() == MAP, "the round is built on it", str(game.stage.id()))
	_check(game.stage.pieces.size() > 0, "with its pieces in the world")
	game.catalogue.content_index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(not game.change_course_now(MAP).ok, "and online the same choice is refused cleanly")
	game.queue_free()
	await get_tree().process_frame
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s %s" % [what, detail])
		print("  FAIL  %s %s" % [what, detail])
	return condition
