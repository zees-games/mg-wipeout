extends Node

## What a subscribed map pack does to this game's course vote, against a fixture
## [DotContentIndex] and never the process's shared one.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workshop.tscn
## [/codeblock]
##
## Solo lists a pack's map as "Name [Pack]", an online session lists none, a map kind the
## game does not accept is left out, and the game's own ids win. Listed, not playable: a
## course here is a document (docs/not-yet.md).

const WoVote := preload("../game/wo_vote.gd")

const SECTIONS := 4
const MAP := &"fixture_hill"
const OTHER_KIND := &"fixture_run"
const OWN := &"wo_first_splash"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-wipeout — Workshop maps")
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids()
	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS else 0)


func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": "res://fixture/",
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Hill", "scene": "hill.tscn", "map_kind": "obstacle"},
			{"kind": "map", "id": String(OTHER_KIND), "name": "Fixture Run", "scene": "run.tscn", "map_kind": "surf"},
			{"kind": "map", "id": String(OWN), "name": "Not The Splash", "scene": "box.tscn", "map_kind": "obstacle"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


## A vote the way [WoModule] builds one, over [param index]; the shared index is swapped out
## of the way by following the fixture afterwards.
func _labels(index: DotContentIndex) -> PackedStringArray:
	var vote := WoVote.new()
	vote.config_path = ""
	vote.courses_fn = func() -> Array: return [[String(OWN), "First Splash"], ["wo_other", "Other"]]
	add_child(vote)
	var _set := vote.setup()
	vote.source.follow_content(index, WoVote.accepted_map_kinds())
	var out := PackedStringArray()
	for choice in vote.source.choices():
		out.append(choice.label())
	vote.queue_free()
	return out


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	var kinds := WoVote.accepted_map_kinds()
	_check(kinds == PackedStringArray(["obstacle", "race"]), "provides.json accepts obstacle and race", str(kinds))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "and only maps", str(accepts))
	_completed += 1


func _test_solo() -> void:
	_entered += 1
	print("")
	print("solo")
	var labels := _labels(_index(DotContentIndex.SESSION_SOLO))
	_check(labels.has("Fixture Hill [Fixture Pack]"), "the ballot lists the pack's map as Name [Pack]", str(labels))
	_check(not labels.has("Fixture Run [Fixture Pack]"), "a map kind the game does not accept is filtered out")
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var index := _index(DotContentIndex.SESSION_SOLO)
	_check(_labels(index).has("Fixture Hill [Fixture Pack]"), "listed while the index is solo")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	var labels := _labels(index)
	_check(not labels.has("Fixture Hill [Fixture Pack]"), "an online session lists none of it", str(labels))
	_check(labels.has("First Splash"), "and still lists the game's own courses")
	_completed += 1


func _test_ids() -> void:
	_entered += 1
	print("")
	print("the game's own ids win")
	var labels := _labels(_index(DotContentIndex.SESSION_SOLO))
	_check(labels.has("First Splash") and not labels.has("Not The Splash [Fixture Pack]"),
		"a pack map claiming a course's id does not replace it", str(labels))
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append("%s %s" % [what, detail])
		print("  FAIL  %s %s" % [what, detail])
