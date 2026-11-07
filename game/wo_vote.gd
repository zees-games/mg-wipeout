extends DotVoteRoundGame

## The players choose the next course: dot-vote's [DotVoteRoundGame] with Wipeout's names. A course lasts one round, so a ballot opens
## [member open_after_sec] into every course and applies at its end; the rest is dot-vote's settings (`user://cfg/wipeout_vote.json`,
## `game.yml` metadata `course_vote:`). The host calls [method note_map] per built course (never for a final death's arena: the same
## round, and the ballot already open stays open) and [member maps_fn] lists the game's own courses.

const WoCatalogue := preload("wo_catalogue.gd")

const CHANNEL := "wipeout.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from, [code]metadata: course_vote:[/code].
const METADATA_KEY := "course_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "course"
	config_path = "user://cfg/wipeout_vote.json"


func _default_kinds() -> PackedStringArray:
	return accepted_map_kinds()


## The `map_kind`s of subscribed maps this game lists: `accepts.map_kinds` in `provides.json`,
## read from there because the site offers a pack by that same file and a second list drifts.
static func accepted_map_kinds() -> PackedStringArray:
	return WoCatalogue.accepted_map_kinds()
