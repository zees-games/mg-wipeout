extends GSPlayerGameServices

const WoGame := preload("wo_game.gd")

## Chat, voice and moderation, wired to this game's sides ([GSGameServices] holds the rest). Proximity is the channel a
## course is played on: twenty metres reaches the people at the same arm and not the far end, so it is not a second "all".

# No `const CHANNEL`: [GSGameServices] declares one and GDScript refuses a redeclaration,
# which is the right refusal — one layer, one channel an operator can turn up.

const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_NEAR := &"near"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Metres a shout carries: about two obstacles. See the class documentation.
const PROXIMITY_RANGE := 20.0

func _services_name() -> String:
	return "wipeout"


func _chat_rules() -> Object:
	return chat_rules()


## The same rules, as a static a CLIENT can ask for without building a services layer. A services layer is a [Node]
## with a moderation store and router; calling `new()` on one leaked it and, inside a delivered pack, failed to
## compile (a script whose base lives in the HOST build cannot hand its return type to a script in the mount).
static func chat_rules() -> GSChatRules:
	var rules := GSChatRules.new()
	rules.max_length = 140
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 22
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to everybody, which is worse than nothing
	# happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	return chat_channels()


static func chat_channels() -> Array[GSChatChannel]:
	var out: Array[GSChatChannel] = []

	var everyone := GSChatChannel.make(CH_ALL, "All", GSChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Short, because a round is a few minutes: a backlog longer than the round is a
	# conversation from a game the new player was not in.
	everyone.backlog = 10
	everyone.history_limit = 200
	out.append(everyone)

	var team := GSChatChannel.make(CH_TEAM, "Team", GSChatChannel.Scope.TEAM)
	team.prefix = "[team]"
	team.colour = Color(0.55, 0.82, 0.95)
	# [b]No backlog, and the final death is what makes that matter.[/b] A backlog is handed
	# to whoever joins, and a replayed team line in the middle of a fight is one side's plan
	# handed to the people it is about.
	team.backlog = 0
	team.history_limit = 120
	out.append(team)

	var near := GSChatChannel.make(CH_NEAR, "Near", GSChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.82, 0.86, 0.72)
	near.radius = PROXIMITY_RANGE
	near.backlog = 0
	near.history_limit = 80
	out.append(near)

	var admin := GSChatChannel.make(CH_ADMIN, "Admin", GSChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := GSChatChannel.make(CH_WHISPER, "Whisper", GSChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## The voice format, which both ends must agree on exactly. Static, because the CLIENT builds one too, and a sample
## rate that differs is a stream of packets the router refuses as the wrong length, said to nobody ([method
## GSVoiceConfig.format_fingerprint]).
static func voice_format() -> GSVoiceConfig:
	var config := GSVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	# Push to talk, because a course is three minutes of people shouting: open-mic on a full server is twenty people
	# reacting to twenty different splashes.
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


func _voice_config() -> Object:
	return voice_format()


## Voice goes to the whole server: everybody has the same problem on the same course, and half the fun is hearing
## somebody else find out the arm was faster than it looked. Team voice is a key away.
func _voice_default_channel() -> int:
	return GSVoiceRouter.Channel.ALL


## Where a body starts again is the game's; the rest of the admin set is [GSPlayerGameServices]'s.
func _mod_extra_abilities() -> Dictionary:
	return {
		"respawn": func(id: StringName, _args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			var field := game as WoGame
			if p == null or field == null or field.stage == null or not field.stage.is_course():
				return GSResult.fail(GSError.CODE_STATE, "Respawning is for a course, not a final death.")
			var spot: Array = field.stage.lounge_spot(p.place) if p.finished \
				else field.stage.respawn_point(p.checkpoint)
			p.place_at(spot[0], spot[1])
			return GSResult.success(spot[0]),
	}


func _mod_unsupported() -> Dictionary:
	return {
		"give": "the weapons in a final death are the ones on its floor, and who reached which is the fight's fairness",
		"strip": "the weapons in a final death are the ones on its floor, and who reached which is the fight's fairness",
		"burn": "nothing here burns a player",
	}

