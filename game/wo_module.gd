extends "wo_module_commands.gd"

const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoPlayer := preload("wo_player.gd")
const WoAvatars := preload("wo_avatars.gd")
const WoCourseCfg := preload("wo_course_cfg.gd")
const WoMapConfig := preload("wo_map_config.gd")
const WoAmbience := preload("wo_ambience.gd")

## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"

## Older cvar names kept for shipped server configs and course files: alias -> WoConfig field.
const ALIASES := {
	"wo_health": "health_enabled",
	"wo_knock_damage": "knock_damage_per_speed",
	"wo_fall_damage": "fall_damage_per_metre",
	"wo_fling_below": "knockout_fling_below",
	"wo_fling_power": "knockout_fling_power",
	"wo_teams": "team_count",
	"wo_props_per_side": "finale_props_per_side",
	"wo_weapons_per_side": "finale_weapons_per_side",
	"wo_knock_min": "knock_min_speed",
	"wo_min_players": "minimum_players",
	"sv_map_rotation_file": "map_rotation_file",
}

## This game, as a module a dedicated server loads: the cvars, two console commands and the rule that keeps enough
## people in a round; [DotGameModule] holds the rest. No `class_name`: [method DotModuleHost.load_module] constructs
## by PATH, and a mounted pack's globals are not registered in the host.

# No `const CHANNEL` here: [DotGameModule] declares one and a subclass may not redeclare it, which is right, since
# [method DotModule.log_info] stamps the module's name and a second channel would split its records.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments; empty is [DotGameServices]'s default, the real store. Static, because no
## instance exists to set a field on (dot-server constructs from a path); `examples/dedicated.tscn` points it elsewhere.
static var punishments_file: String = ""

## dot-workbench over the config and the block rules; null before the module loads.
var workbench: DotGameWorkbench = null

## `mp_killcam_time`, which follows `wo_killcam_seconds` and the other way round.
var _killcam_cvar: DotConVar = null

## The `wo_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## `mp_forcecamera`, kept so the deprecated `wo_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The last course's own settings, put back when the next course is laid out.
var _course_cfg: WoCourseCfg = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const COURSE_BALLOT_TOPIC := &"map_ballot"


func _module_name() -> String:
	return "wipeout"


func _game_service() -> StringName:
	return WoGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an WoGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(WoGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's. Tick rate from the world, so `sv_tickrate` reaches
## it: the world is built after the server and reads the cvar, and a number written here would silently run a rate the
## operator did not choose.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as WoGame).tick_rate
	config.snapshot_rate = WoGame.NET_SNAPSHOT_RATE
	config.world_extent = WoGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# On, and the bridge wires the two callables that make it real ([method WoNetBridge._wire_lag_compensation]); a flag
	# reported enabled with nothing behind it is worse than off. Hitboxes stand on a moving floor, so rewinding a
	# player rewinds where the platform carried them.
	config.enable_lag_compensation = true
	# A dozen platforms, up to a hundred and ten props, a couple of choppers and everybody
	# playing — all of it always relevant, because the map is open air and a player can see
	# the whole of it.
	config.max_entities_per_snapshot = 192
	return config


func _make_bridge() -> Node:
	return WoNetBridge.new()


## Chat, voice and moderation, over [DotGameServices]. The bridge is handed over as the link: `send_chat` and
## `send_voice` use this game's wire, and [DotGameModule] assigns `voice_relay_fn`, checks `check_admission` and makes
## the roster follow this layer.
func _make_services() -> Node:
	var services := WoServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's one-slot schema. Not
## authentication: that is the host's `dot_auth_server`; with it off everybody is a guest with a profile of their own.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = WoAvatars.schema()
	identity_layer.stock_avatar_fn = WoAvatars.stock_avatar
	identity_layer.avatar_translate_fn = WoAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as WoGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an WoGame.")

	add_command("wo_status", _cmd_status, "Show the round, the course and who is where")
	add_command("wo_net", _cmd_net, "Show what the netcode is doing")
	# The game's own map commands are renameable from maps.yml's `commands:` block, like dot-vote's.
	for name in world.command_names("wo_courses"):
		add_command(name, _cmd_courses, "List the courses and arenas, and any refused file")
	for name in world.command_names("wo_reload"):
		add_command(name, _cmd_reload, "Read the course directory again (next round)")
	add_command("wo_rotation", _cmd_rotation,
		"wo_rotation [name]: switch to a rotation in maps.yml, or list them", DotAdminFlags.CHANGEMAP)
	add_command("wo_maps_reload", _cmd_maps_reload, "Re-read maps.yml", DotAdminFlags.CHANGEMAP)
	add_command("wo_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_armed(world)
	_wire_map(world)
	_wire_progress(world)
	# wo_ambient*: REPLICATED (each client plays its own ambience under it); the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)
	_add_tunables(world)

	_bind_rule_cvars(world)

	_build_vote(world)

	_bots = add_cvar(
		"wo_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# dot-game's "still loading": a seat behind its client's cover is neither hurt, eliminated nor counted across.
	world.harm_gate = func(player_id: StringName) -> bool:
		if bridge == null:
			return true
		var peer := int((bridge as WoNetBridge).peer_for_player(WoNetBridge.session_of(player_id)))
		return peer <= 0 or can_peer_be_harmed(peer)

	# dot-server's DotBotQuota: `bot_quota` means the same on every server; the default is this
	# game's `minimum_players` in fill mode, and `wo_bots` stays the switch.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# Started here, not in the world's _ready: a start() before the bridge existed built a field
	# nothing told any client about, invisible floors the server says are fine.
	var _delivered: int = await _add_delivered_courses(world)

	if vote != null:
		vote.refresh_courses()

	world.start()

	log_info("the course is up", world.describe())
	return DotResult.success(null)


## The addons' rule sets as cvars; REPLICATED where the client acts under the value.
func _bind_rule_cvars(world: WoGame) -> void:
	var replicated := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED

	# `mp_teammate_passthrough`: dot-combat's, live from the next shot; the client predicts its
	# tracers under it (see the client's _build_netcode).
	if world.combat != null:
		var _passthrough := world.combat.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	# Dead bodies (sv_ragdoll*): the server picks each death's reaction, the clients draw it.
	var _ragdolls := world.ragdoll_rules.bind_cvars(add_cvar, replicated)

	# REPLICATED: the client plays the killcam and needs the length added to the intermission.
	_killcam_cvar = add_cvar("mp_killcam_time", _number(world.config.killcam_seconds),
		"Seconds the final killcam plays at a round's end, added to the intermission (0 for none)",
		replicated)
	if _killcam_cvar != null:
		_killcam_cvar.changed.connect(func(_old: String, new_value: String) -> void:
			world.set_killcam_seconds(new_value.to_float())
			var field := world.config_binder.cvar_for("killcam_seconds") if world.config_binder != null else null
			if field != null:
				var _set: Variant = field.set_value(new_value))
		world.set_killcam_seconds(_killcam_cvar.get_float())

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: each client flies its own spectator
	# camera under them (WoClient.toggle_roam).
	for made: Object in world.spectate_rules.bind_cvars(add_cvar, replicated):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made

	# mp_forceview and mp_solidplayers: the client places its camera and predicts its player under them.
	var _views := world.view_rules.bind_cvars(add_cvar, replicated)
	var _bodies := world.body_rules.bind_cvars(add_cvar, replicated)

	# sv_toys*: a client hides the toys the server took away.
	var _toys := world.toy_rules.bind_cvars(add_cvar, replicated)


## Who somebody is reaches the world: a face as they are seated, and the real name and face once dot-platform has
## them. Admission finishes AFTER seating (dot-server has no stage to hold them), so `player_admitted` is when the
## real ones exist; wardrobe changes and `platform_name` come later. All end in [method WoNetBridge.refresh_player].
func _wire_identity() -> void:
	var link := bridge as WoNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved, or the stock person. Through the platform module's
## `player_for`, never the hub by a key made here: the hub keys by a scoped profile key only admission knows, so
## `u<session>` finds nobody. Duck-typed (no dot-platform is a configuration).
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(WoNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as WoNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator will want to change, as cvars, live and written through to the configuration the world reads.
## Nothing already built: `wo_columns` changes the NEXT round, and a cvar pretending otherwise would be reported broken.
func _add_tunables(world: WoGame) -> void:
	var config := world.config

	# How the stand-ins race and fight is one word: dot-bot's `bot_difficulty` and the `bot_*` settings it bundles,
	# with this game's racing mistakes as `wo_bot_*` on top ([WoRacer]). On the world as metadata, never the
	# registry.
	var _bot_cvars := DotBotSettings.of(world).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)
	if world.racer != null:
		var _racer_cvars := world.racer.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)
	_bind_config(world)


## Every [WoConfig] field as a `wo_<field>` cvar, a cfg/ yml key and a workbench set. The names shipped server configs and course files already use stay, as aliases of the field.
func _bind_config(world: WoGame) -> void:
	var binder := world.config_binder
	if binder == null:
		return
	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	binder.bind_commands(add_command)
	for alias: String in ALIASES:
		_alias(world, alias, ALIASES[alias])
	binder.field_changed.connect(_on_config_field)
	_start_workbench(world)


## An older cvar name for a config field: it reports the field and writes through the field's own cvar.
func _alias(world: WoGame, alias: String, key: String) -> void:
	var target := world.config_binder.cvar_for(key)
	var cvar := add_cvar(alias, _field_text(world.config.get(key)), "Same as wo_%s" % key)
	if cvar == null or target == null:
		return
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		var value: Variant = world.config.get(key)
		var text := new_value
		if value is bool:
			text = "1" if new_value.to_float() >= 0.5 else "0"
		elif value is int:
			text = str(roundi(new_value.to_float()))
		# One team is not a mode: taken as solo, as it always was.
		if key == "team_count" and text == "1":
			text = "0"
		var _set: Variant = target.set_value(text))


static func _field_text(value: Variant) -> String:
	if value is bool:
		return "1" if value else "0"
	return str(value)


## A field changed from a cvar, the workbench or a file: the aliases follow, and whatever the world cached is told.
func _on_config_field(key: String, _value: Variant, _source: String) -> void:
	var world := game as WoGame
	if world == null:
		return
	var config := world.config
	for alias: String in ALIASES:
		if ALIASES[alias] == key and console != null:
			var _set: Variant = console.set_cvar(alias, _field_text(config.get(key)))
	match key:
		"team_count":
			if config.team_count == 1:
				config.team_count = 0
		"gravity":
			world._apply_gravity()
		"bot_mistakes":
			if world.racer != null:
				world.racer.mistakes = config.bot_mistakes
		"bot_tile_margin_seconds":
			world.stage.tile_margin_seconds = config.bot_tile_margin_seconds
		"friendly_fire":
			if world.combat != null and world.combat.rules != null:
				world.combat.rules.friendly_fire = config.friendly_fire
		"killcam_seconds":
			if _killcam_cvar != null:
				var _set: Variant = _killcam_cvar.set_value(_number(config.killcam_seconds))
		"spectate_camera":
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _set: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera)
		"minimum_players":
			if _quota != null and _quota.quota_cvar != null:
				var _set: Variant = _quota.quota_cvar.set_value(str(config.minimum_players))
		"map_rotation_file":
			config.map_rotation_file = config.map_rotation_file.strip_edges()
			var _read := world.load_rotation()
			if vote != null:
				vote.refresh_courses()


## dot-workbench over the config and the block rules: the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled` in cfg/server.yml. Admission by dot-auth ticket is [DotGameWorkbench]'s own (`admin_uids` / `admin_groups`), beside the server's admins.
func _start_workbench(world: WoGame) -> void:
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	var admin_permit := Callable()
	if server != null and server.admins != null:
		admin_permit = server.admins.uid_has_permission
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return admin_permit.is_valid() and actor is String and bool(admin_permit.call(actor, flag))
	workbench.account_permit_fn = workbench.permit_fn
	for set: DotProfileSet in world.config_binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, WoAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (wo_ambient*)")
	add_child(workbench)
	var started := workbench.start(world.ensure_runtime())
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if started.ok and net != null:
		var _served := workbench.serve_remote(net)
	if not started.ok:
		log_info("the workbench did not start", {"why": started.error.message})
		return
	if workbench.api != null:
		var rt := workbench.api.runtime as DotProfileRuntime
		if rt != null:
			world.config_binder.attach(rt)
			if ambient_set != null:
				var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, rt, console)
	add_command("workbench", func(ctx: DotCmdContext) -> void: ctx.reply_lines(_workbench_lines()),
		"Show the admin workbench's state", DotAdminFlags.CVAR)


## The workbench's runtime, so the `noblock` kind is listed beside the game settings.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## Team-mates pass each other under `mp_teamblock 0`; the world's sides, not a numeric userid.
func _noblock_side(id: Variant) -> Variant:
	return (game as WoGame).team_of_side(id)


func _workbench_lines() -> PackedStringArray:
	if workbench == null:
		return PackedStringArray(["workbench    off"])
	if workbench.running_http:
		return PackedStringArray(["workbench    http " + JSON.stringify(workbench.http.call("describe"))])
	return PackedStringArray(["workbench    off (workbench.enabled in cfg/server.yml)"])


## A number as an operator would type it: `34`, not `34.000000`. Not `%g`, which GDScript formats parse but fail at
## RUNTIME inside `_game_load`, unwinding the module sequence.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice: a literal default is a second copy of
## what `defaults < JSON < environment < argv` decided, and would reset an operator's own setting when written back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	# The handler must not capture `cvar`: it would be a reference cycle the engine never frees.
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		apply.call(new_value.to_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": new_value})
	)


## Nothing to undo: the commands are the module's and [DotModule] removes them; netcode, bridge and roster are
## [DotGameModule]'s. The world is NOT this module's to free, so a module reload does not take the map away.
func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null
	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)
	_bot_ids.clear()

	if _course_cfg != null:
		_course_cfg.revert(console)

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the course ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one: two sides with somebody on each, because a side with nobody
## ends an elimination round on the first tick (a one-person server would cycle rounds several times a second).
## A stand-in is removed the moment a person takes their place.
func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as WoGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: WoPlayer = world.players.get(WoNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as WoGame

	if world == null or bridge == null or _quota == null:
		return

	# People only. Stand-ins and bots put in by hand (a test, an admin) are never in `_bot_ids` and stay outside the
	# count. A leaver is gone from `players` once the bridge removes them.
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as WoPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	# `wo_bots 0` takes the stand-ins out as well as not adding more: a switch that left the
	# ones already in until a map change would be an operator with no way to empty a server.
	var wanted := 0

	if _bots == null or _bots.get_bool():
		var slots: int = server.config.max_players if server != null and server.config != null else -1
		wanted = _quota.wanted(humans, slots)

	for _i in range(maxi(wanted - _bot_ids.size(), 0)):
		var bot: WoPlayer = bridge.call("add_bot", _bot_name(world))

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	# Newest first, so the stand-in a person replaces is the one that arrived last and the
	# ones that have been playing longest keep playing.
	while _bot_ids.size() > wanted:
		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", WoNetBridge.session_of(leaving))


## Names for the stand-ins, so a scoreboard of four of them is readable: one nobody in
## [param world] has yet (drawn at random, two could share one).
static func _bot_name(world: WoGame) -> String:
	var taken: Array = []
	for id: StringName in world.players:
		taken.append((world.players[id] as WoPlayer).display_name)
	return DotBotNames.pick(taken, world.players.size(), WoGame.BOT_NAMES)


## Joins the bridge's chat seam to the services layer's router. Here, because this is the only object that holds both:
## the bridge knows the wire, the services the rules, so a client cannot send a line with somebody else's name (only a
## channel id and a string cross).
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## The players' vote for the next course, over dot-vote (`!vote`, `!rtv`, `!nominate`); see `game/wo_vote.gd`.
## Configured in `user://cfg/wipeout_vote.json` or `game.yml` `metadata: course_vote:`. A vote that cannot be built is
## a WARN, never a server that will not start.
func _build_vote(world: WoGame) -> void:
	if world.catalogue == null:
		return

	vote = WoVote.new()
	vote.name = "CourseVote"
	vote.commands_spec_fn = world.rotation_commands
	vote.in_rotation_fn = func(id: StringName) -> bool: return world.catalogue.in_rotation(id)
	vote.courses_fn = func() -> Array:
		var out: Array = []

		# The game's own courses only: the Workshop's come from the source's own follow, which
		# reads the index on every ballot and so shows none of them online.
		for id in world.catalogue.rotating(world.config.course_ids):
			if not world.catalogue.is_workshop(id):
				out.append([id, str((world.catalogue.courses.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_course_id = id
		return DotResult.success(id)
	# People only: a stand-in is not a voter, and a ballot it could swing is not the players'.
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: WoPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := WoNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, WoServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), COURSE_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the course vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the course vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# course now, not next round, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_course_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.course_rows())

	_tunable("wo_vote_after", vote.open_after_sec,
		"Seconds into a course before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	_vote_follows_world(world)

## The ballot's clock: note each course and round end, drop a leaver's ballot.
func _vote_follows_world(world: WoGame) -> void:
	# Not the course already built (start() rebuilds it: two begin()s for one play), nor a final
	# death's arena (the same round, on the same ballot).
	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.stage != null and not world.stage.is_arena():
			vote.note_course(world.stage.id())
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


## Per-map settings (`cfg/game/mg-wipeout/dot_map/map/<course id>.yml`): the rules a course may bend. Server-only rules, so no client hook; movement is the game's pinned profile and is not a map's to change.
func _map_config_keys() -> Dictionary:
	return WoMapConfig.KEYS


func _wire_map(world: WoGame) -> void:
	if world.stage != null and not world.stage.doc.is_empty():
		report_map(String(world.stage.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.stage.id()))
		apply_course_cfg(world)
	)


## The course's own `cfg/<id>.cfg`, if it has one, over the settings in force; the last
## course's put back first, so a course that wants one life does not leave it on for the next.
func apply_course_cfg(world: WoGame) -> int:
	var text := ""

	if world.catalogue != null and world.stage != null:
		var path := str(world.catalogue.course_cfg.get(world.stage.id(), ""))

		if path != "":
			text = FileAccess.get_file_as_string(path)

	if _course_cfg == null:
		_course_cfg = WoCourseCfg.new()

	return _course_cfg.apply(console, text)


## And the one game event the bridge cannot see for itself: `_arm` happens inside the world, and a weapon is a fact
## about a player for a watcher's HUD, not a replicated entity.
func _wire_armed(world: WoGame) -> void:
	if bridge == null:
		return

	world.player_armed.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		bridge.call("announce_armed", player_id, weapon_id)
	)


## An achievement is told to the one person who earned it, as a notice (which a client already draws in chat) rather
## than a new event kind. A stand-in never earns one.
func _wire_progress(world: WoGame) -> void:
	if bridge == null:
		return

	# Filed under dot-game's stable per-server key (guests too), so it outlives the connection
	# and a restart; see [WoProgress].
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(WoNetBridge.session_of(id)) \
				if server != null else null
			return String(stats_feed.key_for(session)) if session != null and stats_feed != null else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", WoNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as WoGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
