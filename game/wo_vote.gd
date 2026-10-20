extends Node

## The players choose the next course.
##
## [DotVoteDirector] over a [DotVoteListSource] of this server's courses, and the only thing
## this file decides is WHEN: a ballot opens [member open_after_sec] into every course and is
## applied when the round ends, because in this game a round IS a course — the next round
## starts on whatever was chosen. Everything about the ballot itself (how many options, the
## counting method, the tie-break, rock the vote, nominations, cooldowns) is dot-vote's
## settings and none of it is restated here; [method _rules] only says which of them a
## one-course-per-round game wants by default.
##
## [b]`trigger` is MANUAL, not ROUND_END, and that is the point of this file.[/b] dot-vote's
## ROUND_END opens a ballot at a round's end and applies it at the NEXT round's end, which is
## right for a game that plays several rounds on a map and one course late here. Opening it
## during the round and applying it at the end (`apply: END_OF_ROUND`) puts the choice on
## the very next round.
##
## [b]Server side only.[/b] A client draws the ballot from the notice [member ballot_fn] sends
## (the client shell's [DotBallotPanel]), and never holds a director: a client that applied a
## result would be deciding what it plays.

const WoCatalogue := preload("wo_catalogue.gd")

const CHANNEL := "wipeout.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from —
## [code]metadata: course_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "course_vote"

## The dot-vote API level at which the director opens a rocked vote itself under MANUAL.
const RTV_OPENS_IN_DIRECTOR_LEVEL := 2

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}

## Seconds into a course before its ballot opens. 0 opens it the moment the course is built.
## Late enough that nobody is voting on the start line, early enough that a short round still
## sees it close.
@export var open_after_sec: float = 20.0

## The file a server owner configures the vote in, keyed exactly as [DotVoteRules]. Layered:
## [code]_rules() < game.yml metadata course_vote: < this file < DOT_VOTE_* < --vote-*[/code].
## Empty skips the file. [code]{"enabled": false}[/code] turns the vote off and the rotation
## ([code]shuffle_courses[/code] in the game's config) decides alone.
@export var config_path: String = "user://cfg/wipeout_vote.json"

## [code]func() -> Array[/code] of [code][id, name][/code] pairs: every course a ballot may
## offer. The host's, because which courses a server plays is the world's to say.
var courses_fn: Callable = Callable()

## The Workshop's index; null is the shared one. A suite sets a fixture.
var content_index: DotContentIndex = null

## [code]func(id: StringName) -> DotResult[/code]: play this course next.
var apply_fn: Callable = Callable()

## [code]func() -> Array[/code] of voter ids (StringName): the people who may vote. Stand-ins
## are not voters — a ballot they could swing is not the players' choice.
var voters_fn: Callable = Callable()

## Says a line to everybody.
var announce_fn: Callable = Callable()

## Whether a voter is an admin, for dot-vote's admin bypasses.
var is_admin_fn: Callable = Callable()

## [code]func(state: Dictionary)[/code]: the ballot as a client draws it, sent when it changes.
var ballot_fn: Callable = Callable()

## [code]func(voter: StringName) -> Dictionary[/code]: a voter's name and avatar, for the ballot.
var people_fn: Callable = Callable()

## [code]func() -> bool[/code]: whether a round is being played right now — not warmup, not
## between rounds. Handed to dot-vote so [code]time_up: finish_round[/code] holds a change
## only for a round in progress. The host's, because only the match knows.
var round_in_progress_fn: Callable = Callable()

var director: DotVoteDirector = null
var source: DotVoteListSource = null
var commands: DotVoteCommands = null

## `() -> Dictionary`: maps.yml's `commands:` block. Unset renames nothing.
var commands_spec_fn: Callable = Callable()

## `(id) -> bool`: maps.yml's active rotation, handed to the source so the pack maps dot-vote merges
## are filtered like the game's own (dot-vote API level 12). Unset, every merged map is offered.
var in_rotation_fn: Callable = Callable()
var feed: DotVoteBallotFeed = null

## Seconds since the course in play was built.
var _on_course_sec: float = 0.0

## Whether this course has had its ballot (or been refused one), so it opens once.
var _opened_this_course: bool = false


## Builds the director. Fails when the rules do not validate, never because there are too few
## courses: a server whose catalogue grows on [code]wo_reload[/code] gets a ballot from then on.
func setup() -> DotResult:
	source = DotVoteListSource.new()
	source.label = "courses"
	source.apply_fn = func(id: StringName) -> DotResult:
		return apply_fn.call(id) if apply_fn.is_valid() else DotResult.success(id)
	# The Workshop's maps, solo only (the index is solo or online as its host set it, so a
	# server lists none). The game's own ids are in the entries and win.
	source.entries_fn = _own_choices
	source.follow_content(
		content_index if content_index != null else DotContentIndex.shared(), accepted_map_kinds())
	# By name, only where it exists: a delivered pack may run on an older shell dot-vote.
	if "in_rotation_fn" in source:
		source.set(&"in_rotation_fn", in_rotation_fn)
	refresh_courses()

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = configured_rules()
	director.source = source
	director.auto_apply = true
	# The host calls begin() whenever a course is built, which a vote's change is one cause of
	# and an operator's wo_reload or a rotation another; both firing would put one play in the
	# history twice. See DotVoteDirector.begin_on_apply.
	director.begin_on_apply = false
	# The server's tick drives it, not the frame clock.
	director.self_advance = false
	director.round_based = true
	# [b]Set by name, and only where it exists.[/b] A delivered pack runs on the shell's
	# dot-vote, and one older than API 3 has no `round_in_progress_fn`: naming it would fail
	# the pack's parse. There, a finish_round limit in warmup waits out finish_round_max_sec,
	# which is what it did before. Read through this node's own field, so the order the host
	# sets it in does not matter.
	if "round_in_progress_fn" in director:
		director.set(&"round_in_progress_fn", func() -> bool:
			return not round_in_progress_fn.is_valid() or bool(round_in_progress_fn.call()))

	director.player_count_fn = func() -> int:
		return _voters().size()
	director.voters_fn = _voters
	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))
	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	# [b]Rock the vote opens its own ballot from dot-vote API level 2 on[/b]: the director's
	# _on_vote_due opens a rocked vote under MANUAL as under any trigger, and a second
	# start_vote here would only be refused. Below level 2 (an older shell dot-vote under a
	# delivered pack) MANUAL dropped it: the clock expired with reason rtv, the director did
	# nothing, and `!rtv` answered "Rocked. 1 of 1." and nothing happened. Only there does
	# this game open it, connected after the director's own handler.
	if DotAddonApi.build_level("dot_vote") < RTV_OPENS_IN_DIRECTOR_LEVEL:
		director.clock.expired.connect(func(reason: StringName) -> void:
			if reason != DotVoteClock.REASON_RTV or director.is_voting():
				return

			_opened_this_course = true
			var opened := director.start_vote(DotVoteClock.REASON_RTV)

			if not opened.ok:
				DotLog.debug(CHANNEL, "the rocked vote could not open", {"why": opened.error.message})
		)

	director.vote_closed.connect(func(result: DotVoteResult) -> void:
		DotLog.info(CHANNEL, "the course vote closed", {"winner": String(result.winner_id), "votes": result.votes_cast})
	)

	feed = DotVoteBallotFeed.of(director, func(state: Dictionary) -> void:
		if ballot_fn.is_valid():
			ballot_fn.call(state)
	)
	feed.title = "Vote for the next course"
	feed.command = COMMAND_NAMES["vote"]
	feed.people_fn = func(voter: StringName) -> Dictionary:
		return people_fn.call(voter) if people_fn.is_valid() else {}

	return DotResult.success(self)


## [method _rules] under the server owner's layers. A layer that does not validate is refused
## whole, with the reason logged, and the defaults stand.
func configured_rules() -> DotVoteRules:
	var rules := _rules()
	var loaded := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)
	DotLog.result(CHANNEL, "the course vote's rules", loaded)
	return rules


## What a one-course-per-round game wants from dot-vote by default. Every line is a default an
## operator overrides in [member config_path].
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	# See the class note: opened here, applied at the round's end.
	rules.trigger = DotVoteRules.Trigger.MANUAL
	rules.apply = DotVoteRules.Apply.END_OF_ROUND
	# A rocked vote changes the NEXT course too. Immediately would pull the course from under a
	# round in progress and drop everybody on it in the water, checkpoints and all.
	rules.rtv_apply = DotVoteRules.Apply.END_OF_ROUND
	# No time limit: a course lasts one round, and dot-vote's 45-minute default would, on a
	# course somebody kept voting for, expire and change it under a round in progress.
	rules.duration_sec = 0.0
	# There is no clock to extend, and "this course again" is a fair thing to want when a
	# server has two.
	rules.include_extend = false
	# Rock the vote from the start line. dot-vote's two minutes keep a long map from being
	# rocked the moment it loads; here a course is shorter than that, and its own ballot opens
	# at open_after_sec anyway, so the delay would make `!rtv` a command that never works.
	rules.rtv_delay_sec = 0.0
	rules.include_current = true
	# Plays, not minutes: two courses with a cooldown of five would offer nothing at all.
	rules.cooldown = 0
	rules.max_options = 5
	rules.vote_duration_sec = 25.0
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.RANDOM
	return rules


## Reads the course list again: on boot, after the delivered courses arrive, and after
## [code]wo_reload[/code]. The module calls it after [code]_add_delivered_courses[/code]: built
## before them, the list held only the built-in practice course, and a list of one never
## opens a ballot.
func refresh_courses() -> void:
	if source == null:
		return

	source.entries.clear()
	for choice in _own_choices():
		var _added := source.add(choice)


## The game's own courses as choices; [member DotVoteListSource.entries_fn].
func _own_choices() -> Array:
	var out: Array = []
	if not courses_fn.is_valid():
		return out
	for pair: Variant in courses_fn.call():
		var row: Array = pair
		out.append(DotVoteChoice.of(StringName(str(row[0])), str(row[1])))
	return out


## The `map_kind`s of subscribed maps this game lists: `accepts.map_kinds` in `provides.json`,
## read from there because the site offers a pack by that same file and a second list drifts.
static func accepted_map_kinds() -> PackedStringArray:
	return WoCatalogue.accepted_map_kinds()


## A course was built: the director starts over on it and the ballot timer restarts. Never
## called for a final death's arena: that is the same round, and the ballot already open on
## the course stays open through it.
func note_course(id: StringName) -> void:
	if director == null:
		return

	source.current = id
	director.begin(id)
	_on_course_sec = 0.0
	_opened_this_course = false


## The server woke from hibernation: the course ballot is owed again, from the top.
##
## The director restarts itself ([member DotVoteRules.wake_restart]); this is the half that is
## this game's — the seconds into the course at which the ballot opens.
func note_woke() -> void:
	_on_course_sec = 0.0
	_opened_this_course = false


## A round ended: a decided course is applied now, so the next round starts on it.
func note_round_end() -> void:
	if director != null:
		var _over := director.note_round_end()


## One tick.
func advance(delta: float) -> void:
	if director == null:
		return

	director.advance(delta)

	if feed != null:
		feed.poll()

	# The ballot's own timer waits with the director's clock while the server hibernates
	# (DotGameModule hands the director the server's hibernation). Counted on, it ran past
	# open_after_sec over an empty room, the ballot was refused for want of voters, and the
	# first player in never got one on this course.
	if director.hibernating:
		return

	_on_course_sec += delta

	if _opened_this_course or _on_course_sec < open_after_sec:
		return

	_opened_this_course = true

	# Nothing to choose between: one course, or one course and itself.
	if source.entries.size() < 2:
		return

	var opened := director.start_vote(DotVoteClock.REASON_MANUAL)

	if not opened.ok:
		DotLog.debug(CHANNEL, "no course vote this round", {"why": opened.error.message})


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


func is_voting() -> bool:
	return director != null and director.is_voting()


## dot-vote's commands on [param host]: `vote`, `rtv`, `nominate` and the operator's. Voters
## are the bare session id, the same spelling [member voters_fn] lists — dot-vote's default is
## `u<userid>`, and two spellings of one voter is a player who rocks the vote twice.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES.duplicate()
	# maps.yml's `commands:` block, read on every bind, so an operator renames vote and rtv.
	commands.spec_fn = commands_spec_fn
	commands.voter_fn = func(ctx: Object) -> StringName:
		var session: Variant = ctx.get("session")

		if session is Object and (session as Object).get("userid") != null:
			return StringName(str((session as Object).get("userid")))

		return &"console"

	var bound := commands.bind(host)

	if feed != null:
		feed.command = commands.command_name("vote")

	return bound


func _voters() -> Array:
	return voters_fn.call() if voters_fn.is_valid() else []


func describe() -> Dictionary:
	return {
		"courses": source.entries.size() if source != null else 0,
		"open_after_sec": open_after_sec,
		"on_course_sec": snappedf(_on_course_sec, 0.1),
		"director": director.describe() if director != null else {},
	}


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()
