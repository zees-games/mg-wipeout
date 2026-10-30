extends DotGameServices

const WoGame := preload("wo_game.gd")
const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoPlayer := preload("wo_player.gd")

## Chat, voice and moderation, wired to this game's sides ([DotGameServices] holds the rest). Proximity is the channel a
## course is played on: twenty metres reaches the people at the same arm and not the far end, so it is not a second "all".

# No `const CHANNEL`: [DotGameServices] declares one and GDScript refuses a redeclaration,
# which is the right refusal — one layer, one channel an operator can turn up.

const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_NEAR := &"near"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Metres a shout carries: about two obstacles. See the class documentation.
const PROXIMITY_RANGE := 20.0

## The bridge, for the roster lookup [method _position_of] needs. Set before [method setup].
var bridge: WoNetBridge = null


func _services_name() -> String:
	return "wipeout"


func _chat_rules() -> Object:
	return chat_rules()


## The same rules, as a static a CLIENT can ask for without building a services layer. A services layer is a [Node]
## with a moderation store and router; calling `new()` on one leaked it and, inside a delivered pack, failed to
## compile (a script whose base lives in the HOST build cannot hand its return type to a script in the mount).
static func chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()
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


static func chat_channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.make(CH_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Short, because a round is a few minutes: a backlog longer than the round is a
	# conversation from a game the new player was not in.
	everyone.backlog = 10
	everyone.history_limit = 200
	out.append(everyone)

	var team := DotChatChannel.make(CH_TEAM, "Team", DotChatChannel.Scope.TEAM)
	team.prefix = "[team]"
	team.colour = Color(0.55, 0.82, 0.95)
	# [b]No backlog, and the final death is what makes that matter.[/b] A backlog is handed
	# to whoever joins, and a replayed team line in the middle of a fight is one side's plan
	# handed to the people it is about.
	team.backlog = 0
	team.history_limit = 120
	out.append(team)

	var near := DotChatChannel.make(CH_NEAR, "Near", DotChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.82, 0.86, 0.72)
	near.radius = PROXIMITY_RANGE
	near.backlog = 0
	near.history_limit = 80
	out.append(near)

	var admin := DotChatChannel.make(CH_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := DotChatChannel.make(CH_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## The voice format, which both ends must agree on exactly. Static, because the CLIENT builds one too, and a sample
## rate that differs is a stream of packets the router refuses as the wrong length, said to nobody ([method
## DotVoiceConfig.format_fingerprint]).
static func voice_format() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
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
	return DotVoiceRouter.Channel.ALL


## Which side somebody is on, for the team channel and team voice. Read off the game, not cached, because sides change
## between rounds.
func _team_of(peer_id: int) -> int:
	var player := _player_of(peer_id)
	return (game as WoGame).team_of(player.player_id) if player != null else 0


func _position_of(peer_id: int) -> Vector3:
	var player := _player_of(peer_id)

	# The simulated state, not the node: the node is wherever the last frame drew them, between two ticks on an
	# interpolating client, and a range resolved against it is off by a frame of walking.
	return player.controller.state.position if player != null else Vector3.ZERO


func _player_of(peer_id: int) -> WoPlayer:
	if bridge == null or game == null:
		return null

	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return null

	return (game as WoGame).players.get(WoNetBridge.player_key(session_id))


## What the admin set means here, one callable per ability (see `DotGameServices`). Refused: give and strip, because
## the weapons in a final death are the ones on its floor. Blind and beacon are one flag each on [WoPlayer], replicated
## by `WoPlayerNet` (blind to its owner, beacon to everybody) and drawn by the client; the server decides.
func _mod_abilities() -> Dictionary:
	return {
		"noclip": func(id: StringName, args: Dictionary) -> DotResult:
			return _on_foot(id, func(p: WoPlayer) -> DotResult:
				return DotFpsAdminModifiers.set_noclip(p.controller, bool(args["on"]))),
		"freeze": func(id: StringName, args: Dictionary) -> DotResult:
			return _on_foot(id, func(p: WoPlayer) -> DotResult:
				return DotFpsAdminModifiers.set_frozen(p.controller, bool(args["on"]))),
		"speed": func(id: StringName, args: Dictionary) -> DotResult:
			return _on_foot(id, func(p: WoPlayer) -> DotResult:
				return DotFpsAdminModifiers.set_speed(p.controller, float(args["scale"]))),
		"gravity": func(id: StringName, args: Dictionary) -> DotResult:
			return _on_foot(id, func(p: WoPlayer) -> DotResult:
				return DotFpsAdminModifiers.set_gravity(p.controller, float(args["scale"]))),
		"god": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			p.health.invulnerable = bool(args["on"])
			return DotResult.success(p.health.invulnerable),
		"buddha": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			p.health.cannot_die = bool(args["on"])
			return DotResult.success(p.health.cannot_die),
		"health": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null or p.health == null:
				return _mod_absent(id)
			if not p.health.alive:
				return DotResult.fail(DotError.CODE_STATE, "They are out until the next round.")
			p.health.health = minf(float(args["value"]), 2000.0)
			return DotResult.success(p.health.health),
		"slay": func(id: StringName, _args: Dictionary) -> DotResult:
			return _mod_hurt(id, -1.0),
		"slap": func(id: StringName, args: Dictionary) -> DotResult:
			return _mod_hurt(id, float(args.get("damage", 0.0))),
		"rename": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return DotResult.success(p.display_name),
		# The screen and nothing else: a blinded player still moves and can be hit, and a verb that also froze could
		# not be used for only the first.
		"blind": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.blinded = bool(args["on"])
			return DotResult.success(p.blinded),
		"beacon": func(id: StringName, args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			if p == null:
				return _mod_absent(id)
			p.beacon = bool(args["on"])
			return DotResult.success(p.beacon),
		"respawn": func(id: StringName, _args: Dictionary) -> DotResult:
			var p := _mod_player(id)
			var field := game as WoGame
			if p == null or field == null or field.stage == null or not field.stage.is_course():
				return DotResult.fail(DotError.CODE_STATE, "Respawning is for a course, not a final death.")
			var spot: Array = field.stage.lounge_spot(p.place) if p.finished \
				else field.stage.respawn_point(p.checkpoint)
			p.place_at(spot[0], spot[1])
			return DotResult.success(spot[0]),
	}


func _mod_unsupported() -> Dictionary:
	return {
		"give": "the weapons in a final death are the ones on its floor, and who reached which is the fight's fairness",
		"strip": "the weapons in a final death are the ones on its floor, and who reached which is the fight's fairness",
		"burn": "nothing here burns a player",
	}


## Toggles that outlive a new body here, beyond dot-moderation's own god and buddha. Blind and beacon are about the
## person, not the body: noclip or freeze ends with the round (starting frozen behind the gate breaks it), but a
## punished player stays so next round, and a fall is how they would otherwise end it.
const PERSIST_ON_RESPAWN: Array[String] = ["blind", "beacon"]


func _mod_can_teleport() -> bool:
	return true


func _mod_position(id: StringName) -> Variant:
	var p := _mod_player(id)
	return p.controller.state.position if p != null else null


func _mod_teleport(id: StringName, to: Variant) -> void:
	var p := _mod_player(id)

	if p != null and to is Vector3:
		p.place_at(to as Vector3, p.controller.state.yaw)


func _mod_configure_commands(commands: Object) -> void:
	commands.set("alive_fn", func(id: StringName) -> bool:
		var p := _mod_player(id)
		return p != null and p.is_alive())
	commands.set("team_fn", func(id: StringName) -> String:
		var p := _mod_player(id)
		return str(p.team) if p != null else "")


func _mod_player(id: StringName) -> WoPlayer:
	if game == null or not String(id).is_valid_int():
		return null

	return (game as WoGame).players.get(WoNetBridge.player_key(String(id).to_int()))


func _mod_absent(id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Player %s is not on the course." % String(id))


func _on_foot(id: StringName, act: Callable) -> DotResult:
	var p := _mod_player(id)

	if p == null:
		return _mod_absent(id)

	return act.call(p)


## A slay (amount < 0) or a slap, as ordinary damage through the combat manager — so the
## round hears about a slain player exactly as it hears about a fall.
func _mod_hurt(id: StringName, amount: float) -> DotResult:
	var p := _mod_player(id)

	if p == null or p.health == null:
		return _mod_absent(id)

	if not p.health.alive:
		return DotResult.fail(DotError.CODE_STATE, "They are already out.")

	var field := game as WoGame

	if amount < 0.0:
		var was_god := p.health.invulnerable
		var was_buddha := p.health.cannot_die
		p.health.invulnerable = false
		p.health.cannot_die = false
		p.health.invulnerable_until_tick = -1
		var fatal := DotDamage.make(0, p.entity_id, p.health.health + 1000.0, null)
		fatal.context = {"admin": true}
		fatal.weapon_id = &"slay"
		field.combat.apply_damage(fatal)
		p.health.invulnerable = was_god
		p.health.cannot_die = was_buddha
		return DotResult.success(null) if fatal.lethal else DotResult.fail(
			DotError.CODE_STATE, "The slay was refused: %s" % fatal.refusal
		)

	# Into the simulated velocity, which replicates, so the owning client reconciles to the
	# shove. On a beam over water, a slap is a real threat, which is the point.
	p.controller.state.velocity += Vector3(3.0, 4.0, 3.0)
	p.controller.state.mode = DotFpsState.Mode.AIR

	if amount > 0.0:
		var hurt := DotDamage.make(0, p.entity_id, amount, null)
		hurt.context = {"admin": true}
		hurt.weapon_id = &"slap"
		field.combat.apply_damage(hurt)

	return DotResult.success(null)


## A round is everybody's new body: a noclip or freeze from last round ends, god carries. A new course is a new map:
## `return` points are places on some course, so the history is cleared when the course changes and kept when it does
## not (`[modtools-return-1]`).
func _on_round_began_for_tools(_number: int, layout: StringName) -> void:
	for key: StringName in (game as WoGame).players:
		mod_player_respawned(StringName(String(key).trim_prefix("u")))

	if layout != _tools_layout and mod_tools != null:
		mod_tools.clear_history()
	_tools_layout = layout


## The course the last round began on, for [method _on_round_began_for_tools].
var _tools_layout: StringName = &""


## The team seam dot-chat and dot-voice both ask for, which the base cannot wire: [DotGameServices] knows nothing
## about teams, so the two `team_fn` hooks are set here after the base has built each router.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	var ready_now: DotResult = await super.setup(p_server, p_game, p_link)

	if not ready_now.ok:
		return ready_now

	if chat != null:
		chat.set("team_fn", Callable(self, "_team_of"))

	if voice != null:
		voice.set("team_fn", Callable(self, "_team_of"))

	if mod_tools != null:
		# Read, extended and written back: the property is a PackedStringArray, and a packed
		# array read through `get` is a copy — appending to it would change nothing.
		var keep: PackedStringArray = mod_tools.get("persist_on_respawn")
		for action in PERSIST_ON_RESPAWN:
			if not keep.has(action):
				keep.append(action)
		mod_tools.set("persist_on_respawn", keep)

	if game is WoGame and not (game as WoGame).round_began.is_connected(_on_round_began_for_tools):
		(game as WoGame).round_began.connect(_on_round_began_for_tools)

	DotLog.info(CHANNEL, "chat, voice and moderation are up for this game", describe())
	return ready_now
