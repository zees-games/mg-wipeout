extends DotGameModule

const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoServices := preload("wo_services.gd")

const WoGame := preload("wo_game.gd")
const WoPlayer := preload("wo_player.gd")
const WoAvatars := preload("wo_avatars.gd")
const WoVote := preload("wo_vote.gd")
const WoCourseCfg := preload("wo_course_cfg.gd")

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the two console commands, and the rule that
## keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/wo_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments. Empty is [DotGameServices]'s own default,
## `user://wipeout_punishments.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run appended the live tools' audit warnings to the real store, 106 of them by the
## time anybody counted.
static var punishments_file: String = ""

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

## The players' vote for the next course; null when it could not be built.
var vote: WoVote = null

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


## The netcode's numbers, which are the game's and not the addon's.
##
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as WoGame).tick_rate
	config.snapshot_rate = WoGame.NET_SNAPSHOT_RATE
	config.world_extent = WoGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# [b]On, and the two callables that make it real are wired by the bridge.[/b] It was off
	# for as long as they were not: a flag reported as enabled with nothing behind it is
	# worse than one that is off, because the first reader to trust it loses an afternoon.
	# See [method WoNetBridge._wire_lag_compensation].
	#
	# The showdown is a fight at range with rifles, which is the ordinary reason to want it.
	# The less obvious one is that this game's hitboxes stand on a floor that was in a
	# different place a hundred milliseconds ago — so rewinding a player rewinds where the
	# platform had carried them to, which nothing else could reconstruct.
	config.enable_lag_compensation = true
	# A dozen platforms, up to a hundred and ten props, a couple of choppers and everybody
	# playing — all of it always relevant, because the map is open air and a player can see
	# the whole of it.
	config.max_entities_per_snapshot = 192
	return config


func _make_bridge() -> Node:
	return WoNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
##
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := WoServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
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
	var _file_cvar := add_cvar("sv_map_rotation_file", world.config.map_rotation_file,
		"maps.yml: the courses that rotate, in named rotations. Unlisted courses stay installed.")
	_file_cvar.changed.connect(func(_old: String, new_value: String) -> void:
		world.config.map_rotation_file = new_value.strip_edges()
		var _read := world.load_rotation()
		if vote != null:
			vote.refresh_courses())
	add_command("wo_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_armed(world)
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)

	# Whether shots pass through team-mates: `mp_teammate_passthrough` 0 never, 1 a team-mate
	# holding the muzzle (the default), 2 every team-mate in the line. dot-combat's cvar,
	# defined there once for every game; live from the next shot, and a value the operator set
	# first (argv, content.yml) is read back. NOTIFY, because players should know; REPLICATED,
	# because every client's own manager predicts its tracers under it (the client follows it
	# through its link, see the client's _build_netcode).
	if world.combat != null:
		var _passthrough := world.combat.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's reaction
	# from them; REPLICATED, because the clients draw the bodies (see the client's _build_netcode).
	var _ragdolls := world.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules, so spectators
	# free-roam unless an operator says otherwise. REPLICATED, because each client flies its
	# own spectator camera under them (WoClient.toggle_roam).
	for made: Object in world.spectate_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made

	# dot-player-controller's mp_forceview (first or third person: the player's choice, or one
	# held) and mp_solidplayers (players and stand-ins block each other, 1 by default).
	# REPLICATED: the client places its own camera under the first and predicts its own
	# player under the second.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := world.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# The stage's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away.
	var _toys := world.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	_build_vote(world)

	_bots = add_cvar(
		"wo_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# dot-game's "still loading": a seat behind its client's cover is neither hurt, eliminated
	# nor counted across (see WoGame.harm_gate). Asked by player id, resolved to a peer through
	# the bridge.
	world.harm_gate = func(player_id: StringName) -> bool:
		if bridge == null:
			return true
		var peer := int((bridge as WoNetBridge).peer_for_player(WoNetBridge.session_of(player_id)))
		return peer <= 0 or can_peer_be_harmed(peer)

	# [b]How many is dot-server's [DotBotQuota], so `bot_quota` and `bot_quota_mode` mean the
	# same thing on every server in the family.[/b] The default is this game's own minimum
	# (`minimum_players`, from the config file) in fill mode, which is the rule it ran before
	# the policy was shared: stand-ins top the round up to that many players, a person who
	# joins takes a stand-in's place, and the stand-in comes back when they leave. `wo_bots`
	# stays the switch it always was, so a server config that sets it means what it meant.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` lays the field out
	# and puts everybody on it, and a world that did that before the bridge existed would
	# have built a dozen platforms with nothing listening to `world_rebuilt` — a field the
	# server knows about and no client is ever told about. They would be invisible floors:
	# a player stands on nothing and the server says they are fine.
	var _delivered: int = await _add_delivered_courses(world)

	if vote != null:
		vote.refresh_courses()

	world.start()

	log_info("the course is up", world.describe())
	return DotResult.success(null)


## The courses the SERVER names for this game, fetched and added to the catalogue. Returns how
## many documents they held.
##
## [b]The server's list, not this game's.[/b] A course pack used to be a `server_dependencies`
## entry in `game.yml`, which travels in this game's own pack — so a new course meant a release
## of the game, and a server owner could not choose which courses to run. The owner names them
## now in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills
## [member DotGameDescriptor.maps]); [DotGameContent] fetches each pack and hands back its
## `courses/` directory. A server that still names one under `server_dependencies` keeps working,
## because DotGameContent reads those too.
##
## [b]Documents on the wire, meshes in the pack.[/b] The server sends the course it is playing in
## STAGE, so a client needs no course file; `maps_delivery: client` still mounts the pack on it for
## an imported course's `worlds/` mesh. With nothing named, this
## game plays its built-in course.
##
## [b]Called after EVERY catalogue load[/b], not only the first: `load_from` forgets everything
## read before, and a reload that did not come back here dropped every delivered course — which
## is what mg-wipeout and mg-deathrun did until the three were moved onto DotGameContent.
func _add_delivered_courses(world: WoGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "courses"):
		read += world.catalogue.add_directory(root)

	return read


## Who somebody is reaches the world: a face as they are seated, and the real name and
## face once dot-platform has them.
##
## [b]Three events and one path.[/b] Admission finishes AFTER a player is seated — dot-server
## has no stage between authentication and content to hold them in — so the name and face
## a player is seated with are a guest's whenever the profile store is slower than the
## join; `player_admitted` is the moment the real ones exist. A wardrobe change and an
## operator's `platform_name` are the same thing later. All three end in
## [method WoNetBridge.refresh_player], a JOIN everybody already knows how to apply.
func _wire_identity() -> void:
	var link := bridge as WoNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
##
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
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


## The numbers an operator is actually going to want to change, as cvars.
##
## [b]Live, and each one writes through to the configuration the world already reads.[/b]
## The alternative is what most of this family's games still do — a JSON file and a restart
## — and the reason to do better here is the shape of this game: the whole thing is a
## balance between how fast the cannon fires, how stiff the platforms are and how long a
## round lasts, and an operator finds their server's numbers by moving one of them between
## rounds with people watching.
##
## [b]What is NOT here is anything the world has already built.[/b] `wo_columns` changes how
## many platforms the NEXT round is laid out with; it does not put a platform in the air
## now. A cvar that pretended otherwise would be one an admin sets in the middle of a round
## and then reports as broken.
func _add_tunables(world: WoGame) -> void:
	var config := world.config

	_tunable("wo_course_seconds", config.course_seconds,
		"The most seconds a course stays open (a course may ask for less)",
		func(value: float) -> void: config.course_seconds = clampf(value, 10.0, 1200.0))
	_tunable("wo_courses_per_round", float(config.courses_per_round),
		"Courses a round runs before the final death, while more than one side finishes each (1: one course)",
		func(value: float) -> void: config.courses_per_round = clampi(int(value), 1, 12))
	_tunable("wo_health", 1.0 if config.health_enabled else 0.0,
		"Whether the course hurts: knocks, lightning and hard landings cost health (0 turns it all off)",
		func(value: float) -> void: config.health_enabled = value > 0.5)
	_tunable("wo_knock_damage", config.knock_damage_per_speed,
		"Health a knock costs per m/s it threw the player (0: knocks never hurt)",
		func(value: float) -> void: config.knock_damage_per_speed = clampf(value, 0.0, 10.0))
	_tunable("wo_strike_damage", config.strike_damage,
		"Health lightning costs at the least",
		func(value: float) -> void: config.strike_damage = clampf(value, 0.0, 400.0))
	_tunable("wo_fall_safe_height", config.fall_safe_height,
		"Metres a player may drop onto a deck for free",
		func(value: float) -> void: config.fall_safe_height = clampf(value, 0.0, 30.0))
	_tunable("wo_fall_damage", config.fall_damage_per_metre,
		"Health a hard landing costs per metre fallen past wo_fall_safe_height (0: never)",
		func(value: float) -> void: config.fall_damage_per_metre = clampf(value, 0.0, 50.0))
	_tunable("wo_fling_below", config.knockout_fling_below,
		"Health fraction at or below which a knockout flings the body (0: never; the lower, the wilder)",
		func(value: float) -> void: config.knockout_fling_below = clampf(value, 0.0, 1.0))
	_tunable("wo_fling_power", config.knockout_fling_power,
		"How hard a knockout at no health flings the body (the ragdoll caps it at 3)",
		func(value: float) -> void: config.knockout_fling_power = clampf(value, 0.0, 10.0))
	_tunable("wo_finale_seconds", config.finale_seconds,
		"Seconds a final death lasts before it is called on the clock",
		func(value: float) -> void: config.finale_seconds = clampf(value, 10.0, 900.0))
	_tunable("wo_countdown_seconds", config.countdown_seconds,
		"Seconds behind the start gate",
		func(value: float) -> void: config.countdown_seconds = clampf(value, 0.0, 30.0))
	_tunable("wo_teams", float(config.team_count), "Sides: 0 is everybody for themselves, or two to six teams",
		func(value: float) -> void:
			var teams := clampi(int(value), 0, 6)
			config.team_count = 0 if teams == 1 else teams)
	_tunable("wo_props_per_side", float(config.finale_props_per_side),
		"Props dropped into a final death, per side that made it",
		func(value: float) -> void: config.finale_props_per_side = clampi(int(value), 0, 40))
	_tunable("wo_weapons_per_side", float(config.finale_weapons_per_side),
		"Weapons laid out in a final death, per side that made it",
		func(value: float) -> void: config.finale_weapons_per_side = clampi(int(value), 0, 20))
	_tunable("wo_knock_min", config.knock_min_speed, "The least an obstacle throws a player, m/s",
		func(value: float) -> void: config.knock_min_speed = clampf(value, 0.0, config.knock_max_speed))
	_tunable("wo_instant_death", 1.0 if config.instant_death else 0.0,
		"1: a fall into the water, or any death on a course, is out until the round is over (no checkpoint restart)",
		func(value: float) -> void: config.instant_death = value > 0.5)
	_tunable("wo_progress_decides", 1.0 if config.progress_decides else 0.0,
		"Whether whoever got furthest wins a round nobody finished",
		func(value: float) -> void: config.progress_decides = value > 0.5)
	# [b]How the stand-ins race and fight is one word[/b]: dot-bot's `bot_difficulty` (easy,
	# medium, hard, nightmare; medium by default) and every `bot_*` setting it bundles, the
	# names every game in the family uses, for the aim in a final death and the reaction to a
	# window; this game's racing mistakes are `wo_bot_*` on top ([WoRacer]). On the world as
	# metadata, never the registry. `wo_bot_spread` (a fixed aim offset per round) is gone:
	# `bot_aim_error` and its settling replaced it. `wo_bot_fumble` is now the racing preset's.
	var _bot_cvars := DotBotSettings.of(world).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)
	if world.racer != null:
		var _racer_cvars := world.racer.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)
	_tunable("wo_bot_mistakes", config.bot_mistakes,
		"Scales every racing mistake a stand-in makes: 1 the preset's, 0 never wrong",
		func(value: float) -> void: config.bot_mistakes = clampf(value, 0.0, 4.0))
	_tunable("wo_gravity", config.gravity, "Metres per second squared, for everything",
		func(value: float) -> void: config.gravity = value)
	_tunable("wo_spectate_camera", float(config.spectate_camera),
		"Deprecated, sets mp_forcecamera. Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody",
		func(value: float) -> void:
			config.spectate_camera = clampi(int(value), 0, 2)
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _set: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera))
	# [b]Deprecated: the count is `bot_quota` now[/b], and this forwards to it. Kept rather than
	# removed because every shipped server config sets it; left as its own number it would be
	# a second cvar deciding the same count, and whichever was read last would win.
	_tunable("wo_min_players", float(config.minimum_players),
		"Deprecated, sets bot_quota. How many players the server keeps in a round with stand-ins",
		func(value: float) -> void:
			config.minimum_players = clampi(int(value), 0, 24)
			if _quota != null and _quota.quota_cvar != null:
				var _set := _quota.quota_cvar.set_value(str(config.minimum_players)))


## A number as an operator would type it: `34`, not `34.000000`.
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
##
## [b]The default is the value the world was built with, and that is the whole point.[/b] A
## cvar declared with a literal default is a second copy of a number that
## `defaults < JSON < environment < argv` has already decided — so an operator who set
## `WO_COURSE_SECONDS=240` would see `wo_survival_seconds` report 120 and, worse, would
## reset their own setting the moment anything wrote the value back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	cvar.changed.connect(func(_old: String, _new: String) -> void:
		apply.call(cvar.get_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": cvar.get_string()})
	)


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
func _game_unload() -> void:
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


## Keeps enough people in the round for there to be one.
##
## [b]Two sides with somebody on each, or nothing happens at all.[/b] An elimination round
## ends the moment a side has nobody alive, and a side with nobody AT ALL satisfies that on
## the first tick — so a server with one person on it would start a round, end it, start
## another and end that, several times a second, for as long as nobody else joined. Every
## one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
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

	# People only. A stand-in is not one, and neither is a bot somebody put in by hand through
	# the bridge (a test, an admin): those are never in `_bot_ids` either, so they are left
	# alone and outside the count. A leaver is gone from `players` the moment the bridge
	# removes them, so nobody half-disconnected is counted.
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


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## A round's layout is what a server listing prints as the map.
##
## The layout is this game's map: the field the round is played on, picked per round. Said
## on every round rather than once, because dot-server forgets the map whenever a game
## unloads and a layout changes between rounds.
## The map a server browser shows is the stage: the course, and the arena while a final
## death is on. Reported on every rebuild, because the server forgets it whenever a game
## unloads and a browser showing last round's course is a browser lying.
## The players' vote for the next course, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member WoVote.open_after_sec] into every course and applied when the round ends[/b],
## because a round here is a course; see [code]game/wo_vote.gd[/code]. A server owner turns
## it off or reshapes it in `user://cfg/wipeout_vote.json` or `game.yml`'s
## `metadata: course_vote:`, keyed as dot-vote's [DotVoteRules]. A vote that cannot be built
## is a WARN and the rotation alone, never a server that will not start.
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

	# No note_course for the course already built: start() builds it again, which is a
	# world_rebuilt, and two begin()s for one play is one play counted twice in the cooldowns.
	# Not for a final death's arena either: that is the same round, on the same course's
	# ballot, and a begin() on the arena's id would put an arena in the course history.
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


## And the one game event the bridge cannot see for itself.
##
## `_arm` happens inside the world and the bridge is not listening to the world's weapons,
## because a weapon is not a replicated entity here — it is a fact about a player that a
## watcher's HUD wants to name. One signal is cheaper than a behaviour.
func _wire_armed(world: WoGame) -> void:
	if bridge == null:
		return

	world.player_armed.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		bridge.call("announce_armed", player_id, weapon_id)
	)


## An achievement is told to the one person who earned it.
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [WoProgress] does not count them.
func _wire_progress(world: WoGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [WoProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(WoNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", WoNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, WoServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_courses(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.course_doc.get("id", "-")))


func _cmd_rotation(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null or not world.catalogue.has_rotation_file():
		ctx.reply("There is no maps.yml; every course rotates.")
		return

	var file := world.catalogue.rotation_file

	if ctx.argc() == 0:
		ctx.reply("Rotations: %s (active: %s)" % [", ".join(file.rotation_names()), file.active_name()])
		return

	var wanted := ctx.arg(0)
	var switched := world.catalogue.switch_rotation(wanted)

	if not switched.ok:
		ctx.reply(switched.error.message)
		return

	if vote != null:
		vote.refresh_courses()

	ctx.reply("Rotation: %s" % wanted)


func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var read := world.load_rotation()

	if vote != null:
		vote.refresh_courses()

	ctx.reply("maps.yml read." if read.ok else read.error.message)


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.course_directory)
	loaded += await _add_delivered_courses(world)
	world.catalogue.apply_rotation(world.config.course_ids)

	if vote != null:
		vote.refresh_courses()

	ctx.reply("%d documents read; %d refused. The next round draws from them." % [
		loaded, world.catalogue.refused.size()])


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as WoGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
