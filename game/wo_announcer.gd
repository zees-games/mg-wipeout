extends RefCounted

const WoAudio := preload("wo_audio.gd")
const WoGame := preload("wo_game.gd")
const WoPlayer := preload("wo_player.gd")

## The show's voice: what the announcer says and the crowd does about what just happened.
##
## [b]A course is a show, and the play test said it felt like a time trial.[/b] Nothing told a
## runner that the bot in front of them had just gone in, that somebody had taken the lead, or
## that ten seconds were left; the stands were empty water. This turns the facts the client
## already hears (a fall, a checkpoint, a finish, the gate, the clock) into a line under the
## course name ([WoHud] `announce`), a voice (Kenney's Voiceover Pack) and the crowd: a gasp, a
## cheer, a roar, and the people in the stands jumping ([WoCourse] `cheer`).
##
## [b]Client only and cosmetic[/b]: it decides nothing, so its choice of words may use a local
## random number; two players may hear different lines about the same splash, and that is fine.
## It is rate-limited, because eight stand-ins fall a lot: one line every [constant LINE_GAP]
## seconds unless it is about you, the leader or the winner.

# No log channel: it decides nothing worth a log line.

## The least time between two ordinary lines, seconds.
const LINE_GAP := 2.2

## When the clock is this low, the announcer hurries everybody once.
const HURRY_SECONDS := 10.0

const FELL_LINES := [
	"WIPEOUT! %s takes a swim",
	"Into the drink goes %s!",
	"%s is in the water!",
	"SPLASH! That's %s",
	"Oh, %s! Back to the checkpoint",
	"%s did not see that coming",
]

const LEAD_LINES := [
	"%s takes the lead!",
	"%s is out in front!",
	"New leader: %s!",
]

var game: WoGame = null
var audio: WoAudio = null

## The HUD (anything with `announce(text, seconds)`), and who this client is.
var hud: Object = null
var me: StringName = &""

var _leader: StringName = &""
var _first_home: bool = false
var _hurried: bool = false
var _last_line_msec: int = -100000
var _rng := RandomNumberGenerator.new()
var _screen_msec: int = -100000


func _init(p_game: WoGame = null, p_audio: WoAudio = null, p_hud: Object = null) -> void:
	game = p_game
	audio = p_audio
	hud = p_hud
	_rng.randomize()


## A new course: nobody leads, nobody is home, nobody has been hurried.
func on_stage(course_name: String, is_arena: bool) -> void:
	_leader = &""
	_first_home = false
	_hurried = false
	if not is_arena and course_name != "":
		_say("Welcome to %s!" % course_name, true)


func on_count(second: int) -> void:
	if audio != null:
		var _heard := audio.on_count(second)


func on_go() -> void:
	if audio != null:
		var _heard := audio.on_go()
	_cheer(1.0)
	_say("AND THEY'RE OFF!", true)


func on_fell(id: StringName, near_camera: bool) -> void:
	var who := _name(id)
	var important := id == me or id == _leader

	if audio != null and (near_camera or important):
		var _heard := audio.crowd(&"gasp")

	_cheer(0.5 if near_camera or important else 0.2)

	if who != "":
		_say(FELL_LINES[_rng.randi() % FELL_LINES.size()] % ("you" if id == me else who), important)


func on_knock(mine: bool) -> void:
	if mine and audio != null:
		var _heard := audio.crowd(&"gasp")
	_cheer(0.4 if mine else 0.15)


## A checkpoint crossed: a leader change is worth a line and a cheer.
func on_checkpoint(id: StringName) -> void:
	var order := game.race_order() if game != null else []
	var leader: StringName = order[0] if not order.is_empty() else &""

	if leader == id and leader != _leader:
		_leader = leader
		if audio != null:
			var _heard := audio.crowd(&"cheer")
		_cheer(0.7)
		_say(LEAD_LINES[_rng.randi() % LEAD_LINES.size()] % ("You" if id == me else _name(id)), true)
	elif id == me:
		_cheer(0.3)


func on_finished(id: StringName, place: int, seconds: float) -> void:
	var mine := id == me
	var who := "You" if mine else _name(id)

	if place == 1 and not _first_home:
		_first_home = true
		if audio != null:
			var _crowd := audio.crowd(&"roar")
			var _said := audio.say(WoAudio.VOICE_CONGRATULATIONS if mine else WoAudio.VOICE_WINNER)
		_cheer(1.0)
		_say("%s WIN%s THE COURSE in %.1f s!" % [who.to_upper(), "" if mine else "S", seconds], true)
		return

	if audio != null:
		var _crowd := audio.crowd(&"cheer")
		if mine:
			var _said := audio.say(WoAudio.VOICE_CONGRATULATIONS)
	_cheer(0.6)
	_say("%s %s home, %s in %.1f s" % [who, "are" if mine else "is", _ordinal(place), seconds], mine)


func on_finale() -> void:
	if audio != null:
		var _said := audio.say(WoAudio.VOICE_FINAL)
		var _crowd := audio.crowd(&"roar")
	_cheer(1.0)
	_say("THE FINAL DEATH!", true)


func on_course_closed() -> void:
	if audio != null:
		var _said := audio.say(WoAudio.VOICE_TIME_OVER)


## The round is over; [param won] is whether this client's side won it.
func on_round_over(won: bool, decided: bool) -> void:
	if audio != null and decided:
		var _said := audio.say(WoAudio.VOICE_YOU_WIN if won else WoAudio.VOICE_YOU_LOSE)
	_cheer(0.8)


## Once a frame: the clock running down, and the leaders on the big screens.
func tick() -> void:
	if game == null or game.phase != WoGame.Phase.COURSE:
		return

	var now := Time.get_ticks_msec()
	if now - _screen_msec > 500 and game.stage != null and game.stage.has_method(&"screen_count") \
			and int(game.stage.call(&"screen_count")) > 0:
		_screen_msec = now
		game.stage.call(&"show_on_screens", screen_text())

	var left := game.seconds_left()

	if not _hurried and left <= HURRY_SECONDS and left > 0.0:
		_hurried = true
		if audio != null:
			var _said := audio.say(WoAudio.VOICE_HURRY)
		_say("TEN SECONDS LEFT!", true)


## What the big screens show: LIVE, the course's clock and the first three in the race.
func screen_text() -> String:
	var lines := PackedStringArray(["LIVE  %d:%02d" % [int(game.course_elapsed) / 60, int(game.course_elapsed) % 60]])
	var order := game.race_order()

	for place in range(mini(order.size(), 3)):
		var who := _name(order[place])
		lines.append("%d  %s" % [place + 1, "YOU" if order[place] == me else who.to_upper()])

	return "\n".join(lines)


func _say(text: String, important: bool = false) -> void:
	var now := Time.get_ticks_msec()

	if not important and now - _last_line_msec < int(LINE_GAP * 1000.0):
		return

	_last_line_msec = now

	if hud != null and hud.has_method(&"announce"):
		hud.call(&"announce", text, 3.0)


func _cheer(amount: float) -> void:
	if game != null and game.stage != null and game.stage.has_method(&"cheer"):
		game.stage.call(&"cheer", amount)


func _name(id: StringName) -> String:
	if game == null:
		return ""
	var who: WoPlayer = game.players.get(id)
	return who.display_name if who != null else ""


static func _ordinal(n: int) -> String:
	var tail := "th"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1:
				tail = "st"
			2:
				tail = "nd"
			3:
				tail = "rd"
	return "%d%s" % [n, tail]
