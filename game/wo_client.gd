extends Node

const WoAnnouncer := preload("wo_announcer.gd")
const WoAudio := preload("wo_audio.gd")
const WoBindings := preload("wo_bindings.gd")
const WoFigure := preload("wo_figure.gd")
const WoSettings := preload("wo_settings.gd")
const WoServices := preload("wo_services.gd")
const WoPlayerNet := preload("net/wo_player_net.gd")
const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoNetCommand := preload("net/wo_net_command.gd")
const WoEvents := preload("net/wo_events.gd")

const WoConfig := preload("wo_config.gd")
const WoGame := preload("wo_game.gd")
const WoWeatherView := preload("wo_weather_view.gd")
const WoHud := preload("wo_hud.gd")
const WoPaths := preload("wo_paths.gd")
const WoPlayer := preload("wo_player.gd")

## One local player, a camera and a HUD over an [WoGame] — offline, or against a server.
##
## [b]One client for both, and the offline half is not a demo mode.[/b] It is the same world
## class with `authoritative` true and nothing else different: the same courses, the same
## obstacles, the same rules. What changes is where the answers come from, and the whole of
## that difference is [WoNetBridge]. A separate single-player build would be a second game to
## keep in step, and this family has watched two copies of one thing drift more than once.
##
## [b]Which half runs is decided by whether there is a link in the registry.[/b] A dot-server
## client publishes a [DotClientLink] under `dot_client_link` before the game scene loads; no
## link means nobody connected us to anything, and the honest answer to that is a playable
## course rather than an error. `--offline` forces it.
##
## [b]First person and third, and the motor does not know which.[/b] The camera is
## presentation: the simulation is first-person, command-driven and predictable in both, and
## what changes is where the camera sits. That is the line dot-player-controller draws
## between its motor and its view, drawn again here — and on a course the third person view
## is the one that shows where your feet are against a beam's edge or a ball's top.

const CHANNEL := "wo.client"

## Where the camera sits behind the player in third person, in metres.
const CHASE_BACK := 4.6
const CHASE_UP := 2.1

@export var config_file: String = "user://cfg/wipeout.json"

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many stand-ins an offline course gets, so there is somebody to beat and a final death
## can happen at all. Eight, a full field (the first play test had three); `-- --bots N` at
## launch changes it, and a server's own count is `bot_quota`.
@export_range(0, 16, 1) var offline_bots: int = 8

## Which view the camera starts in.
@export var third_person: bool = false

var game: WoGame = null
var player: WoPlayer = null
var camera: Camera3D = null

## Rain and lightning, drawn. See [WoWeatherView].
var weather: WoWeatherView = null
var hud: WoHud = null

## The Tab board, the menu's. See [method _wire_board].
var board: DotMenuScoreboard = null

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()
var chat: DotGameChatClient = null

## What the game sounds like. See [WoAudio].
var audio: WoAudio = null

## The show's voice: lines, the announcer and the crowd. See [WoAnnouncer].
var announcer: WoAnnouncer = null

## The player's own settings and the screen Escape opens. See [WoSettings].
var settings: WoSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null

## The weapons in this player's own hands, once they have picked one up in a final death.
##
## [b]Drawn, never decided.[/b] `authority` is false and every shot that matters is the
## server's; what this rig is for is a view model that moves — a deploy, a reload, a recoil
## kick — because a weapon that appears fully formed and never animates reads as a texture
## stuck to the screen.
var weapons: ZeeWeaponRig = null
var view_model: ZeeViewModel = null

var net: DotNetManager = null
var bridge: WoNetBridge = null
var link: Node = null

var _offline: bool = true
var _sampler: DotFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## Which session this client is, once the server has said. -1 until then, so nothing matches
## before it does.
var _watch_id: int = -1

## The stage last introduced, and when, so one stage is introduced once. See [method _on_stage].
var _introduced: StringName = &""
var _introduced_msec: int = -1000000

## The course time this frame drew the obstacles at, or a negative before the first.
var _stage_seconds: float = -1.0


## The camera rig, in third person. Null in first.
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null

## How far above the player's feet the camera, or in third person the arm, is hung.
var _rig_height: float = 0.0

## Held buttons, read once a tick rather than sampled from an event queue.
var _firing: bool = false
var _alt: bool = false
var _reloading: bool = false
var _slot: int = 0

## The grab key, held. Picks up or puts down a prop in a final death; see `WoGame._advance_grabs`.
var _grab: bool = false

## pickup id -> the model spinning where a weapon lies. Client side.
var _pickup_nodes: Dictionary = {}

## The knocks this client last saw on its own player, so a new one shakes the screen once.
var _knocks_seen: int = 0

## The last whole second of the countdown a beep was played for.
var _beeped: int = -1


func _ready() -> void:
	# First, before anything can be drawn: the course arrives after this node is in the tree.
	# The platform puts the loading cover up, held until the player exists and the camera is
	# current, and finds the link.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null
	platform.scoreboard_action = WoBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate
	gate.hold(&"map", "Loading the course")

	# [b]zee-dot-weapons' art is this game's copy of it, wherever this game is mounted.[/b]
	# `ZeeWeaponArtTable` names `res://assets/…`, and in a delivered pack that is the one place
	# the art is not: every gun and the arms would load invisible, one WARN each.
	ZeeModelCache.set_asset_root(WoPaths.root())

	var config := WoConfig.new()

	# [b]`load_layered` on the CLIENT too.[/b] The family's `defaults < JSON < env < argv`
	# chain is a convention, and a client that quietly skipped it would be one where every
	# command-line flag worked against a dedicated server and did nothing at all offline.
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = platform.link as Node
	_offline = platform.offline

	game = WoGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = _offline
	# A connected client's world is not what a module looks up, and registering it would mean
	# a client and a server sharing a process fighting over the name — which is what every
	# section of this game's own suite does.
	game.register_service = _offline
	game.tick_rate = int(
		ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64)
	)
	# The sky, the sun and the water: drawn here, never on a server.
	game.draw_world = true
	game.covered = _covered
	add_child(game)
	_wire_gate_to_stages()
	_build_ragdolls()

	# The sampler lives HERE and not on the player, because on a connected client the local
	# player does not exist yet: they arrive in a JOIN, several frames after the keyboard
	# does.
	_sampler = DotFpsSampler.new(WoPlayer.tunables_for(config))
	WoPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	announcer = WoAnnouncer.new(game, audio, hud)
	_build_settings()

	if _offline:
		_start_offline()
	else:
		# [b]Here, in `_ready`, which runs INSIDE `DotClientLink._load_scene`.[/b] The link
		# adds this scene and tells the server it has loaded on the next line, so the netcode
		# is up before the server has been told there is anybody to send to — which is the
		# order that leaves nothing to be missed.
		DotLog.result(CHANNEL, "the netcode", _build_netcode())


# --- The load gate ---------------------------------------------------------

## Keeps the screen covered, and the local body, the keys and the clocks still, until the course
## is built, the local player exists and its camera is current.
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null


## [b]Without it the first frames were a half-built world.[/b] Offline the runner stood in a
## course whose pieces were still being posed and the countdown ran behind nothing; connected,
## the client drew from its first frame with no stage, no player and a HUD with nobody to read,
## and a new course (each round) was torn down in front of a body that kept moving. The gate
## (DotGameClient's) does not stop the simulation by itself: [member WoGame.covered] holds every
## clock and every obstacle still but the local body, [method WoPlayer.simulate] skips a frozen
## body, and the keys and the netcode sampling check [method _covered].


## Holds again for each stage rebuild (a new course or the arena) and releases once it stands.
## Offline the first stage is built by `game.start()`, connected by the server's STAGE.
func _wire_gate_to_stages() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the course"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))


## True while the load gate covers the screen: no key, no mouse turn, no clock.
func _covered() -> bool:
	return gate != null and not gate.is_open()


# --- Dead bodies -----------------------------------------------------------

## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.reactions = WoGame.death_reactions()
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


## [param who]'s body falls the way the server picked ([member WoPlayer.death]), copied from the
## figure this client draws; the figure itself stays hidden while they are dead
## ([method WoPlayer.present_body]). Nobody's figure, nothing: a first-person player who never
## had one drawn here.
func _fall(who: WoPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The level is on `world`; a body lands on it and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)


# --- Offline ---------------------------------------------------------------

func _exit_tree() -> void:
	# A static outlives the game: the next one the shell loads must not look for its art here.
	ZeeModelCache.set_asset_root("res://")


func _start_offline() -> void:
	# Stand-ins to race, named as a server names them. Solo by default, so each is a side of
	# their own; with teams they are dealt round the sides the local player is not on first.
	var taken: Array = ["You"]
	var count := offline_bots
	var args := OS.get_cmdline_user_args()
	var at := args.find("--bots")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		count = clampi(args[at + 1].to_int(), 0, 16)
	for i in range(count):
		var side := 0

		if game.config.teams():
			side = (i % maxi(game.config.team_count - 1, 1)) + 2

		var bot_name := DotBotNames.pick(taken, i, WoGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := game.add_player(StringName("u%d" % (WoNetBridge.FIRST_BOT_SESSION + i)), bot_name, side)
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 1 if game.config.teams() else 0, true))
	_hear_the_world()

	# Offline the world counts for the player at this keyboard, so it is the world that says
	# what they earned. Connected, the same line arrives as a notice from the server.
	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	# Offline the world is the authority, so its own word on a hit is the confirmation.
	game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
		if id == &"local":
			_on_hit(point, killed, headshot))
	game.start()

	# No bridge: the box still opens and still echoes, because a chat box that does nothing
	# at all reads as broken rather than as absent.
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## Solo, `bot_difficulty`, every `bot_*` and `wo_bot_*` setting at the console, the names a
## server has; `-- --bot_difficulty hard` at launch. Connected, the server's console holds them
## and a local copy would shadow it.
func _bind_bot_console() -> void:
	if not _offline or console == null or game == null:
		return
	var sources: Array = console.sources()
	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return
	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	if game.racer != null:
		var _racing := game.racer.bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", DotBotSettings.of(game).set_difficulty(args[index + 1]))


# --- Connected -------------------------------------------------------------

func _build_netcode() -> DotResult:
	# The server's `mp_teammate_passthrough`, and every change to it, through the link: this
	# end traces its own shots for tracers and impacts, and on its default 1 against a server
	# on 0 or 2 they ended in (or went through) a team-mate where the server's did the
	# opposite. An older shell's link cannot say, and the manager keeps its default.
	if game.combat != null and link != null:
		var _following := game.combat.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	if link != null:
		var _bodies := game.ragdoll_rules.follow_cvars(link)
		# The server's mp_forceview and mp_solidplayers: this end places its own camera and
		# predicts its own player.
		var _view := game.view_rules.follow_cvars(link)
		var _solid := game.body_rules.follow_cvars(link)
		# And sv_toys*: this end hides the toys the server took away.
		var _toys := game.toy_rules.follow_cvars(link)
		# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
		var _spectate := game.spectate_rules.follow_cvars(link)

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	# [b]Empty, and it is not tidiness.[/b] The manager reads a JSON file by default, so a
	# client with a stale `user://dot_net.json` runs at a tick rate the game did not choose
	# and nothing says so.
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = WoGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	# Off on a client: rewinding is what a server does to resolve somebody's shot, and a
	# client resolves nobody's.
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	# From the game, not written here. Two files holding this number is how another game in
	# this family ended up decoding positions against a range the server never used.
	config.world_extent = WoGame.NET_WORLD_EXTENT
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = WoNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.armed_received.connect(_on_armed)
	bridge.hit_received.connect(_on_hit)
	bridge.stage_received.connect(_on_stage)
	bridge.progress_received.connect(_on_progress)
	bridge.pickup_received.connect(_on_pickup)
	bridge.pickup_gone_received.connect(_on_pickup_gone)
	_hear_the_wire()
	# [b]Where a refusal is drawn.[/b] The server answers a gagged or too-fast line with a
	# notice to that one player, and a notice nothing draws is the server explaining itself
	# to nobody — which is indistinguishable from chat being broken.
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
	)

	# The one thing that writes an RTT sample. dot-net never touches a transport, so nothing
	# in it can; without this the clock's input lead omits the flight time and past about
	# thirty milliseconds every command arrives after its tick and is discarded as late.
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	# READY, and not one byte before the scene exists. dot-server's signon finishes and THEN
	# the client builds this; anything the server sent in between landed on a node that did
	# not exist and was lost, one "Node not found" per call.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(WoNetBridge.player_key(session_id)))


## A player arrived or changed. The one we are waiting for might be us.
##
## [b]Connected before anything can create a player rather than only checked on HELLO.[/b]
## HELLO and JOIN are both reliable and ordered, so HELLO does arrive first — but "the
## ordering happens to save us" is exactly the reasoning that put this bug in another game
## here, and a check that costs nothing is cheaper than depending on it.
func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(WoNetBridge.player_key(session_id)))


func _adopt(candidate: WoPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	# No gate on a client built without `_ready` (a suite adopting a player by hand).
	if gate != null:
		gate.freeze(player)
	_build_camera()
	if platform != null:
		_suspend_input(platform.is_input_blocked())

	# Offline the world samples this player's movement itself, so the buttons go onto that
	# sample (`command_stamp`); stamping `current_command` below only reaches the drawn gun.
	if _offline:
		player.command_stamp = _stamp

	if settings != null:
		settings.bind_camera(camera)
		# Offline the player samples for themselves, from their controller's own tunables.
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)

	if announcer != null:
		announcer.me = player.player_id


# --- What the server says --------------------------------------------------

func _on_phase(phase: int) -> void:
	_hear_phase(phase)

	match phase:
		WoGame.Phase.COUNTDOWN:
			hud.shout("GET READY", 2.0)
			_disarm_locally()
		WoGame.Phase.COURSE:
			hud.shout("GO", 1.4)
			if announcer != null:
				announcer.on_go()

			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
		WoGame.Phase.HANDOVER:
			if player != null and player.watching:
				hud.shout("THE FINAL DEATH — you are watching", 3.0)
			else:
				hud.shout("THE FINAL DEATH — grab something", 3.0)
		WoGame.Phase.FINALE:
			hud.shout("LAST ONE STANDING", 1.8)
			if announcer != null:
				announcer.on_finale()


## How long the same stage is not introduced again. See [method _on_stage].
const INTRODUCE_AGAIN_MSEC := 5000


## A new course or arena. The name, once, big; the camera re-placed, because the player was
## just moved somewhere that may be eighty metres away.
func _on_stage(stage_id: StringName, is_arena: bool) -> void:
	if ragdolls != null:
		# A body from before would lie on a floor that has been rebuilt or reset.
		ragdolls.clear()
	_clear_pickups()

	# A new course's clock is not the last one's, so its first frame is not a sweep of every arm.
	if audio != null:
		audio.reset_machinery()

	if game.stage == null:
		return

	# The new stage's toys are heard: a beach ball's bounce, one knocked off an arena's edge.
	if game.stage.toys != null and not game.stage.toys.sound.is_connected(_toy_sound):
		var _toys := game.stage.toys.sound.connect(_toy_sound)

	var name_of := str(game.stage.doc.get("name", ""))
	var blurb := str(game.stage.doc.get("blurb", ""))

	# [b]Once, though the world is rebuilt twice for it.[/b] The warmup lays round one's
	# course out and `WoGame.start` builds the same one again (Decision 2), so offline the
	# name was shouted and the blurb written into the chat twice, a frame apart, at every
	# boot. By time rather than by round: the rebuild happens inside one round, and a server
	# with one course plays it again next round, which should be introduced again.
	var now := Time.get_ticks_msec()
	if stage_id == _introduced and now - _introduced_msec < INTRODUCE_AGAIN_MSEC:
		return
	_introduced = stage_id
	_introduced_msec = now

	if not is_arena:
		hud.shout(name_of, 3.0)

	if announcer != null:
		announcer.on_stage(name_of, is_arena)

	if chat != null and name_of != "":
		var author := str(game.stage.doc.get("author", ""))
		chat.say_locally("%s%s — %s" % [name_of, " by %s" % author if author != "" else "", _short(blurb, 90)],
			Color(0.80, 0.90, 1.0))


## [param text] cut at a word to at most [param limit] characters, with an ellipsis; the chat box does not wrap.
static func _short(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	var cut := text.substr(0, limit - 1)
	var space := cut.rfind(" ")
	return (cut.substr(0, space) if space > limit / 2 else cut) + "…"


## Somebody fell in, crossed a checkpoint, or finished. What the feed and the speakers say.
func _on_progress(session_id: int, kind: int, value: int, seconds: float) -> void:
	var who: WoPlayer = game.players.get(WoNetBridge.player_key(session_id))
	var mine := session_id == _watch_id

	match kind:
		WoEvents.Progress.FELL:
			if audio != null and who != null:
				var _heard := audio.on_splash(who.global_position)
			if announcer != null and who != null and camera != null:
				announcer.on_fell(who.player_id, who.global_position.distance_to(camera.global_position) < 30.0)
		WoEvents.Progress.CHECKPOINT:
			if mine and audio != null:
				var _heard := audio.on_checkpoint()
			if mine:
				hud.shout("CHECKPOINT", 1.2)
			if announcer != null and who != null:
				announcer.on_checkpoint(who.player_id)
		WoEvents.Progress.FINISHED:
			if audio != null:
				var _heard := audio.on_finish(mine)
			if mine:
				hud.shout("FINISHED #%d — %.1f s" % [value, seconds], 3.0)
			if announcer != null and who != null:
				announcer.on_finished(who.player_id, value, seconds)
			if chat != null and who != null:
				chat.say_locally("%s finished #%d in %.1f s" % [who.display_name, value, seconds],
					Color(0.98, 0.86, 0.40))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if audio != null:
		var _heard := audio.on_round(began)

	if began:
		hud.shout("ROUND %d" % number, 2.4)
		return

	if announcer != null and player != null:
		announcer.on_round_over(winner != 0 and winner == player.team, winner != 0)

	hud.shout(why if why != "" else "round over", 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_death(session_id: int, _by: int, why: StringName) -> void:
	var id := WoNetBridge.player_key(session_id)
	var who: WoPlayer = game.players.get(id)

	_hear_death(who, why)

	if chat == null:
		return

	var name_of := who.display_name if who != null else String(id)

	var line := "%s was knocked out" % name_of

	match why:
		WoGame.DIED_FELL:
			line = "%s fell out of the arena" % name_of
		WoGame.DIED_THROWN:
			line = "%s took a crate to the face" % name_of
		WoGame.DIED_BLAST:
			line = "%s stood next to a barrel" % name_of
		WoGame.DIED_KNOCKED:
			line = "%s was knocked out of the round" % name_of
		WoGame.DIED_LANDED:
			line = "%s landed too hard" % name_of
		WoGame.DIED_STRUCK:
			line = "%s was struck by lightning" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


# --- What it sounds like -----------------------------------------------------

## The player's settings, applied to everything that reads them. See [WoSettings].
##
## After the audio and the sampler, because both are bound here and a binding applies at
## once. The camera arrives with the player and is bound in [method _adopt].
func _build_settings() -> void:
	settings = WoSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: WoHud is a CanvasLayer and the platform's hud is a Control, so it
	# follows the menu's theme itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the course list. Solo a choice changes the course here at once; connected the server
	# decides, by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead
	# (dot-vote's map menu, wired in [WoModule]).
	platform.maps_rows_fn = func() -> Array: return game.course_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_course_now(id)
	platform.maps_title = "Change course"
	platform.maps_noun = "courses"
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler
	# polls the keyboard, and a player dragging a volume slider with the arrow keys would
	# otherwise walk off whatever they had stopped on.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as WoSettings
	console = platform.console as DotConsoleController
	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)

	_bind_bot_console()
	if hud != null and settings.menu != null:
		hud.follow_menu(settings.menu)
	board = platform.board as DotMenuScoreboard
	_dress_board()


func _build_audio() -> void:
	audio = WoAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		# A game that cannot make a noise still plays; it is the state this one shipped in.
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null
		return


## Offline: the world IS the authority, so its own signals are what happened.
##
## [b]Two sources and one set of sounds.[/b] A connected client hears the same things from
## the bridge's signals instead (see [method _hear_the_wire]); both call the same [WoAudio]
## method with the same arguments, so offline and online can only differ in where a fact
## came from and never in what it sounds like.
func _hear_the_world() -> void:
	if game == null:
		return

	game.world_rebuilt.connect(func() -> void:
		_on_stage(game.stage.id(), game.stage.is_arena()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _course: StringName) -> void:
		_on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void:
		_on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName) -> void:
		_hear_death(game.players.get(id), why))
	game.player_fell.connect(func(id: StringName, _checkpoint: int) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.FELL, 0, 0.0))
	game.checkpoint_reached.connect(func(id: StringName, index: int) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.CHECKPOINT, index, game.course_elapsed))
	game.player_finished.connect(func(id: StringName, place: int, seconds: float) -> void:
		_on_progress(WoNetBridge.session_of(id) if id != &"local" else _watch_id,
			WoEvents.Progress.FINISHED, place, seconds))
	game.pickup_placed.connect(_on_pickup)
	game.pickup_taken.connect(func(pickup_id: int, by: StringName) -> void:
		_on_pickup_gone(pickup_id, 0)
		if by == &"local" and player != null:
			_arm_locally(player.weapons.arsenal.current_id() if player.weapons != null \
				and player.weapons.arsenal.has_method("current_id") else &"")
	)
	game.player_armed.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon)
	)

	if audio == null:
		return

	game.blast.connect(func(at: Vector3, _radius: float) -> void:
		var _heard := audio.on_blast(at))
	# Everybody else's weapons, from each rig as it is built.
	game.player_armed.connect(func(id: StringName, _weapon: StringName) -> void:
		var armed: WoPlayer = game.players.get(id)
		if armed == null or armed == player or armed.weapons == null:
			return
		if armed.weapons.used.is_connected(_on_rig_used.bind(armed)):
			return
		armed.weapons.used.connect(_on_rig_used.bind(armed))
	)


func _on_rig_used(outcome: DotWeaponOutcome, armed: WoPlayer) -> void:
	if audio != null and is_instance_valid(armed):
		var _heard := audio.on_weapon(armed.global_position, ZeeWeaponNet.kind_number(outcome.kind))


## Connected: the same sounds, from what the server said.
func _hear_the_wire() -> void:
	if audio == null or bridge == null:
		return

	bridge.blast_received.connect(func(at: Vector3, _radius: float) -> void:
		var _heard := audio.on_blast(at))
	bridge.weapon_used_by.connect(func(session_id: int, _times: int, kind: int) -> void:
		# Your own is heard from your own rig, a round trip sooner. See `_arm_locally`.
		if session_id == _watch_id:
			return
		var who: WoPlayer = game.players.get(WoNetBridge.player_key(session_id))
		if who != null:
			var _heard := audio.on_weapon(who.global_position, kind))
	bridge.notice_received.connect(func(_text: String) -> void:
		var _heard := audio.deny())


func _hear_phase(phase: int) -> void:
	if audio == null:
		return

	match phase:
		WoGame.Phase.COURSE:
			var _heard := audio.on_gate()
		WoGame.Phase.HANDOVER:
			var _heard := audio.on_handover()
		WoGame.Phase.FINALE:
			var _heard := audio.on_finale()


func _hear_death(who: WoPlayer, why: StringName) -> void:
	if who == null:
		return

	# Knocked to pieces by a blow or a blast is this game's own look; anything less, what is
	# left of the body falls as a ragdoll, the way the server picked.
	# A flung body (a knockout at low health) is the flight itself: not broken up on the way.
	var flung := who.death != null and who.death.reaction == WoGame.FLING
	if flung or not _break(who, why):
		_fall(who)

	if audio == null:
		return

	var _heard := audio.on_death(who.global_position, who == player)


## The body comes apart, and how depends on what did it: lightning and a hard knock blow it
## to pieces, anything else takes a limb or two, seeded from who died and how often they
## have, so every client breaks it the same way. Mended a moment later, because on the
## course a knocked-out player is alive again at once, watching from the lounge.
## Breaks [param who]'s body apart. True when it went to pieces entirely (nothing left to fall).
func _break(who: WoPlayer, why: StringName) -> bool:
	if who.figure == null or who == player:
		return false

	var rules := DotPlayerBreakRules.new()
	rules.criticals_only = false
	var seed_value := hash(String(who.player_id)) + who.falls * 31 + who.knocks
	if why == WoGame.DIED_STRUCK or why == WoGame.DIED_BLAST or (seed_value % 3 == 0):
		rules.mode = DotPlayerBreakRules.Mode.EXPLODE
	else:
		rules.mode = DotPlayerBreakRules.Mode.LIMBS
		rules.limbs = 1 + seed_value % 3
	rules.lifetime = 2.5

	var before := DotPlayerBodyBreak.visible_meshes(who.figure)
	var made := DotPlayerBodyBreak.break_apart(
		who.figure, game, rules, who.global_position, Vector3.UP, seed_value
	)
	if made == null:
		return false

	var mend := get_tree().create_timer(1.2)
	mend.timeout.connect(func() -> void:
		if not is_instance_valid(who) or who.figure == null:
			return
		who.figure.visible = true
		for mesh in before:
			if is_instance_valid(mesh):
				mesh.visible = true
	)
	return rules.mode == DotPlayerBreakRules.Mode.EXPLODE


## Somebody got a weapon. If it was us, the gun comes up in our hands, on its own slot.
func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id:
		return

	_arm_locally(weapon_id)

	if chat != null:
		chat.say_locally("You picked up a %s." % String(weapon_id).replace("_", " "),
			Color(0.86, 0.92, 0.80))


# --- Weapons on the floor -------------------------------------------------------

## A weapon lying in the arena: its own model, spinning a little over the floor. Drawn only.
func _on_pickup(pickup_id: int, weapon_id: StringName, at: Vector3) -> void:
	if _pickup_nodes.has(pickup_id):
		return

	var holder := Node3D.new()
	holder.name = "Pickup_%d" % pickup_id
	add_child(holder)
	holder.global_position = at + Vector3(0.0, 0.3, 0.0)

	var art := ZeeWeaponArtTable.get_art(weapon_id)
	var model: Node3D = ZeeModelCache.instantiate(art.model_path) if art != null and art.model_path != "" else null

	if model == null:
		# A weapon with no art (fists, or a pack whose art did not load) is still a thing to
		# pick up, so something has to stand there.
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.5, 0.2, 0.2)
		box.mesh = mesh
		model = box

	model.scale = Vector3.ONE * 1.6
	holder.add_child(model)

	# A light under it, so a weapon on a grey floor reads from across the arena.
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.4)
	glow.light_energy = 0.8
	glow.omni_range = 2.2
	holder.add_child(glow)
	_pickup_nodes[pickup_id] = holder


func _on_pickup_gone(pickup_id: int, _by: int) -> void:
	var holder: Node3D = _pickup_nodes.get(pickup_id)
	_pickup_nodes.erase(pickup_id)

	if holder != null and is_instance_valid(holder):
		if audio != null:
			var _heard := audio.on_pickup(holder.global_position)
		holder.queue_free()


func _clear_pickups() -> void:
	for pickup_id: int in _pickup_nodes.keys():
		var holder: Node3D = _pickup_nodes[pickup_id]

		if is_instance_valid(holder):
			holder.queue_free()

	_pickup_nodes.clear()


# --- The weapons, drawn ----------------------------------------------------

## Builds a view model for this player's own hands when they pick a weapon up.
##
## [b]Drawn, never decided, and `authority` is false for exactly that reason.[/b] The server
## owns every shot; what this is for is a gun that moves. A player whose weapon never
## deploys, never reloads and never kicks is a player who cannot tell a weapon that is ready
## from one that is not.
func _arm_locally(weapon_id: StringName = &"") -> void:
	if player == null:
		return

	if weapons != null:
		_give_locally(weapon_id)
		_select_locally(weapon_id)
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.tick_rate = game.tick_rate
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {
			"why": ready_now.error.message,
		})
		_disarm_locally()
		return

	# [b]Only what the server armed, one weapon as each is armed[/b] (`player_armed` / ARMED),
	# never the whole pack. `give_everything` put all of it in five slots, so a slot held
	# whichever weapon was given last and the drawn gun was not the one the server fired
	# (mg-prop-hunt's play test: "weapons appear with no slot logic").
	_give_locally(weapon_id)

	# Your own shots, from your own rig: a predicted use, heard the tick it happens rather
	# than when the server's snapshot says it did. At the camera, so it is at full volume.
	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(
				camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)
			)
	)

	_select_locally(weapon_id)


## Puts the weapon just picked up in hand, on its own slot, here and in what is sent.
func _select_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return

	var def := weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		_slot = def.slot


func _give_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return
	if weapons.arsenal != null and weapons.arsenal.carries(weapon_id):
		return
	var given := weapons.give(weapon_id)
	if not given.ok:
		DotLog.warn(CHANNEL, "the drawn rig refused a weapon", {"weapon": String(weapon_id), "why": given.error.message})


func _disarm_locally() -> void:
	if weapons != null:
		player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


# --- The camera ------------------------------------------------------------

func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 92.0
	camera.current = true

	# Other players and stand-ins: hidden when one is at the lens, faded in third person when
	# one stands between the camera and you. It rides the camera wherever the camera goes.
	# Handed the figures rather than found by a query: a player's hull is off while
	# mp_solidplayers is 0, and a body walking through you is exactly when it is needed.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)

	_place_camera()

	# The weather's look: rain on a stormy course, each strike drawn on its tick.
	if weather == null and game != null:
		weather = WoWeatherView.new()
		weather.name = "Weather"
		weather.stage = game.stage
		weather.camera = camera
		weather.tick_fn = game.current_tick
		add_child(weather)


## Puts the camera where this view mode wants it, rebuilding the rig if the mode changed.
##
## [b]A boom in third person and nothing in first.[/b] dot-core's [DotCameraBoom] sweeps a
## sphere from the eye and eases in ahead of a wall or a gantry; the spring arm it replaced
## cast a ray from a pivot above the head and snapped to whatever it hit.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	var eye := WoPlayer.EYE_HEIGHT

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	if not third_person:
		player.add_child(camera)
		_rig_height = eye
		camera.position = Vector3(0.0, eye, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# The level, never players: they are faded instead (a stand-in behind you would pull the
	# camera into your head).
	_arm.collision_mask = _level_mask()
	_arm.add_excluded_object(player.get_rid())
	# Swept from the eye, the height above it added in the world's up: a pivot above the
	# head can itself be inside a gantry, and a sweep that starts inside does not see it.
	_rig_height = eye
	_arm.lift = CHASE_UP - eye
	_arm.position = Vector3(0.0, _rig_height, 0.0)
	player.add_child(_arm)

	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Swaps the view, where the server's `mp_forceview` allows. Presentation only: the
## simulation does not know which one is on.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera()

	if audio != null:
		var _heard := audio.click()

	if hud != null:
		hud.shout("third person" if third_person else "first person", 1.2)


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## What the third-person and spectator cameras stop against: the course and the props.
func _level_mask() -> int:
	return game.physics.mask_of([&"world", &"prop"]) if game.physics != null else 1


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


func _build_hud() -> void:
	hud = WoHud.new()
	# The counter reads the gun this player sees (corrected from the server's by correct_drawn).
	hud.weapons_fn = func() -> ZeeWeaponRig: return weapons
	hud.name = "Hud"
	add_child(hud)



## The Tab board: dot-menu's, with this game's columns. Built once the menu exists (see
## [method _build_settings]); the platform feeds it and holds it on Tab.
##
## [b]Online it is the server's roster with this game's numbers merged in.[/b] Names, pings
## and how long each player has been on come from dot-server, which is the only thing that
## knows them for everybody; points, the round's place, the face and the side are already
## replicated here, so they are joined in by id rather than sent twice. Offline there is no
## server and the board is [method board_snapshot], all local.
func _dress_board() -> void:
	if board == null:
		return
	board.title_text = "Wipeout"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"place", "title": "Place", "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_with = func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("points", 0)) != int(b.get("points", 0)):
			return int(a.get("points", 0)) > int(b.get("points", 0))
		return str(a.get("name", "")) < str(b.get("name", ""))
	board.decorate = _decorate_row
	board.prepare = _prepare_board


## This game's numbers onto a row of the server's roster, by id.
func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var who: WoPlayer = game.players.get(WoNetBridge.player_key(int(row.get("id", 0))))
	if who == null:
		who = game.players.get(StringName(str(row.get("id", ""))))
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["place"] = str(who.place) if who.finished else ("out" if who.watching else "-")
	row["team"] = who.team
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The course in the header, and the sides when the round has them.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Course": str(game.course_doc.get("name", ""))}
	if game.config.teams():
		var sides: Array = []
		for side in range(1, game.config.team_count + 1):
			sides.append({"id": side, "name": game.side_name(side), "color": game.side_colour(side)})
		snap["teams"] = sides


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var players: Array = []
	if game != null:
		for id in game.players:
			var who: WoPlayer = game.players[id]
			players.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Wipeout", "game": "offline"}, "players": players}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


## The player's face for the board: their figure's head, rendered once per skin.
##
## [b]Per skin, not per player, because that is what differs.[/b] Every Blocky Character is
## the same mesh and the six people `WoFigure` can draw are six atlases, so six portraits
## cover every player there will ever be; the side is a torso tint and does not reach the
## head. Each is a 64-pixel SubViewport with its own world, an unshaded figure and a camera
## at its eyes, rendered once and kept: the board asks every frame it is open, and a render
## per ask would be a viewport per player per frame for a picture that never changes.
##
## Until 2026-10-08 this was a square in a colour hashed from the id, which is what the brief
## meant by "their avatar picture" only in the sense that it was in the right column.
var _portraits: Dictionary = {}

func _face(who: WoPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := WoFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# In front of the face (a figure looks down -Z) and a touch above it, looking back.
	eye.look_at_from_position(Vector3(0.0, 1.55, -1.6), Vector3(0.0, 1.45, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


## The chat box, before the netcode and before any player exists.
##
## [b]Built in both halves and attached to the bridge afterwards.[/b] A box built after the
## first line arrived would miss it — the backlog a joining player is sent is the first thing
## the server says.
func _build_chat() -> void:
	chat = new_chat()
	add_child(chat)


## Walking off and on: typing, or the settings screen up. Both samplers, because offline the
## player samples for themselves and connected the client does.
func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


# --- The frame -------------------------------------------------------------

## The sampled command, on a connected client, once per tick the clock says has passed.
##
## [b]Offline this does nothing and the world ticks itself.[/b] The player samples inside
## [method WoPlayer.simulate] there, which is the shape a single process wants; a connected
## client cannot use it, because its local player has to be simulated by the PREDICTOR from
## the same command that was sent, and a second sample would predict something different from
## what the server was told.
func _physics_process(delta: float) -> void:
	if _offline:
		_drive_offline(delta)
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# Covered: the clock below still advances, only the sampling waits, so the mouse does not
	# pile up a turn behind the cover and the server sees an idle body until it lifts.
	var move := _sampler.sample(delta) if _sampler != null and not _covered() else DotFpsCommand.new()
	_stamp(move)

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about.
		move.move = Vector2.ZERO
		move.buttons = 0

	# The clock says how many ticks this frame is worth, which on a client whose engine runs
	# at the server's rate is almost always exactly one.
	var ticks := net.clock.advance(delta)

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move, _slot, _grab)

	_drive_view_model(move)


## Offline the world samples for itself; what is left is the buttons this file owns.
func _drive_offline(_delta: float) -> void:
	if player == null or player.sampler == null:
		return

	var pending := player.controller.current_command

	if pending != null:
		_stamp(pending)
		player.wanted_slot = _slot

	player.wants_grab = _grab

	_drive_view_model(pending)


## Puts this game's three buttons and the slot onto a command.
func _stamp(command: DotFpsCommand) -> void:
	if command == null:
		return

	command.set_button(WoNetCommand.BUTTON_FIRE, _firing)
	command.set_button(WoNetCommand.BUTTON_ALT, _alt)
	command.set_button(WoNetCommand.BUTTON_RELOAD, _reloading)


func _drive_view_model(command: DotFpsCommand) -> void:
	if weapons == null or player == null:
		return

	var weapon_command := DotWeaponCommand.new()

	if command != null:
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ATTACK, command.is_pressed(WoNetCommand.BUTTON_FIRE)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ALT, command.is_pressed(WoNetCommand.BUTTON_ALT)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_RELOAD, command.is_pressed(WoNetCommand.BUTTON_RELOAD)
		)
		weapon_command.yaw = command.yaw
		weapon_command.pitch = command.pitch

	weapon_command.slot = _slot

	var _outcome := weapons.simulate_tick(weapon_command, game.round_number * 100000 + Engine.get_physics_frames())

	var busy := weapon_command.is_pressed(DotWeaponCommand.BUTTON_ATTACK) \
		or weapon_command.is_pressed(DotWeaponCommand.BUTTON_RELOAD) \
		or weapons.arsenal.is_reloading() or weapons.arsenal.is_switching()
	_drawn_quiet = 0.0 if busy else _drawn_quiet + 1.0 / float(maxi(game.tick_rate, 1))
	var _corrected := correct_drawn()


## Seconds the drawn gun must be quiet before the server's count may overwrite it: longer than a
## shot's trip to the server and its snapshot back, so no shot still in flight is undone.
const DRAWN_SETTLE_SEC := 0.6

## Simulated seconds the drawn gun has gone without a trigger, a reload or a switch.
var _drawn_quiet: float = 0.0


## Brings the drawn gun's magazine and reserve (what the HUD counts) to the server's once it has
## been quiet [constant DRAWN_SETTLE_SEC]: online from this player's owner-only snapshot fields,
## offline from the world's own rig. True when it changed anything.
##
## [b]The drawn gun predicts, so it can be wrong, and nothing else puts it right.[/b] A shot the
## server refused or a fresh round's refill leaves the counter on the client's own sum otherwise
## (mg-prop-hunt's `correct_drawn`, game-zombie-zone's 15 / 105).
func correct_drawn() -> bool:
	if weapons == null or weapons.arsenal == null or _drawn_quiet < DRAWN_SETTLE_SEC:
		return false

	var source := _server_count()

	if source.is_empty() or bool(source.busy):
		return false

	var arsenal := weapons.arsenal
	var held := arsenal.current()

	if held == null or int(source.slot) != arsenal.current_slot() or arsenal.is_reloading() or arsenal.is_switching():
		return false

	var changed := false

	if held.def.uses_magazine() and held.magazine != int(source.magazine):
		held.magazine = clampi(int(source.magazine), 0, held.def.magazine)
		changed = true

	if held.def.ammo_type != &"" and not held.def.infinite_reserve \
			and arsenal.ammo().count(held.def.ammo_type) != int(source.reserve):
		arsenal.ammo().set_count(held.def.ammo_type, maxi(int(source.reserve), 0))
		changed = true

	return changed


## The server's count for this player's gun: `{magazine, reserve, slot, busy}`, or empty.
func _server_count() -> Dictionary:
	if _offline:
		var world: ZeeWeaponRig = player.weapons if player != null else null
		if world == null or world == weapons or world.arsenal == null or world.arsenal.current() == null:
			return {}
		var def := world.current_def()
		return {
			"magazine": world.arsenal.current().magazine,
			"reserve": world.arsenal.ammo().count(def.ammo_type) if def.ammo_type != &"" else 0,
			"slot": world.arsenal.current_slot(),
			"busy": world.arsenal.is_reloading() or world.arsenal.is_switching(),
		}

	var mine: Variant = bridge._behaviours.get(_watch_id) if bridge != null else null
	if not (mine is WoPlayerNet):
		return {}
	var behaviour := mine as WoPlayerNet
	return {
		"magazine": behaviour.net_magazine, "reserve": behaviour.net_reserve, "slot": behaviour.net_slot,
		"busy": behaviour.net_reloading or behaviour.net_switching,
	}


## A hit the server confirmed for this player's shot: the marker, and zee's red burst on the body
## at the server's point (`ZeeShotFx.play_body_hit`, by `has_method` for an older shell's zee;
## it skips a burst its own presentation ray already drew).
func _on_hit(point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(killed, headshot)
	if weapons == null or not is_instance_valid(weapons) or not weapons.has_method(&"shot_fx"):
		return
	var fx: Object = weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = camera.global_position if camera != null else point + Vector3.UP
	fx.call(&"play_body_hit", point, point - from)


func _process(delta: float) -> void:
	_pose_stage()

	var _shown := present_frame(
		net, game, player, not third_person, delta, -1.0, _watched_through_eyes()
	)

	_present_course(delta)

	if announcer != null:
		announcer.tick()

	if camera == null or player == null:
		return

	# [b]Before the rig, and instead of it.[/b] The rig below hangs the camera off the
	# player's own node, and a player who is out is a body at the kill height.
	if _drive_spectator_camera():
		_present_effects(delta)
		return

	# Drawn every FRAME from the controller's own interpolated view, not once per tick.
	# Another game in this family measured what the other way costs: a client stepping physics
	# at one rate and drawing at another advances the camera in bursts, which is a 47% change
	# in apparent speed several times a second and reads as "the game is jittery" with every
	# simulated number correct.
	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)

	var rig: Node3D = camera

	if _arm != null and is_instance_valid(_arm):
		rig = _arm

	# The camera's half of the weapon's recoil. Added here rather than by the weapon,
	# because this line writes the angles from scratch every frame and would undo it; and
	# only here, never to the command — the shot already went where the command pointed.
	if weapons != null:
		var punch := weapons.view_punch()
		pitch += deg_to_rad(punch.x)
		yaw += deg_to_rad(punch.y)

	rig.rotation = Vector3(pitch, yaw, 0.0)

	# [b]And the position from between the last two ticks, which the angles above never
	# needed.[/b] The rig hangs off the player's node and the node only moves on a tick, so
	# a camera left there advances in steps: measured offline at 64 ticks and 144 frames,
	# 160 frames in 288 did not move at all while the player ran, and the per-frame step
	# varied by 112%. `render_state` blends the last two ticks by the engine's own physics
	# fraction, which this client makes a fraction through a tick by running the engine at
	# the world's rate. Written globally rather than by moving the node, because the tick
	# writes the node and prediction reads it back.
	#
	var drawn := player.controller.render_state()
	rig.global_position = drawn.position + Vector3(0.0, _rig_height, 0.0)

	if weapons != null:
		var speed := Vector2(state.velocity.x, state.velocity.z).length()
		weapons.drive_view(
			Vector2(state.yaw, state.pitch),
			speed,
			state.mode != DotFpsState.Mode.AIR,
			state.crouch_fraction > 0.5
		)

	_present_effects(delta)


## Poses the course for this FRAME, between two ticks.
##
## [b]A frame, not a tick: the obstacles are drawn at the time the frame shows.[/b] The arms
## and the movers are a function of time, so the client can draw them at the exact fraction
## through a tick this frame is — which no snapshot could give it. The local player's own
## prediction poses the course back at its tick before every simulated tick (see
## [WoController]), so drawing it between them never moves what a tick is swept against.
func _pose_stage() -> void:
	if game == null or game.stage == null or game.stage.doc.is_empty():
		return

	var tick := float(game.current_tick())
	var alpha := Engine.get_physics_interpolation_fraction()

	if net != null and net.is_running():
		tick = float(net.clock.tick)
		# At the alpha your own player is drawn at (see `present_frame`), so a clock slip
		# moves the course and the player on it together; at the engine's fraction a rider
		# on a mover slid a tick against it for a moment after each. By name, for an older
		# shell's dot-net.
		if net.clock.has_method(&"render_alpha"):
			alpha = float(net.clock.call(&"render_alpha"))

	_stage_seconds = (tick + alpha) / float(maxi(game.tick_rate, 1))
	game.stage.pose_at_time(_stage_seconds)


## What a frame on a course adds: the countdown's beeps, the shake of a knock, the spin of a
## weapon on the floor.
func _present_course(delta: float) -> void:
	for pickup_id: int in _pickup_nodes:
		var holder: Node3D = _pickup_nodes[pickup_id]

		if is_instance_valid(holder):
			holder.rotate_y(delta * 1.6)

	if game == null:
		return

	if game.phase == WoGame.Phase.COUNTDOWN:
		var second := int(ceilf(game.seconds_left()))

		if second != _beeped and second <= 3 and second > 0:
			_beeped = second

			if audio != null:
				var _heard := audio.on_countdown()

			if announcer != null:
				announcer.on_count(second)

			if hud != null:
				hud.shout("%d" % second, 0.9)
	else:
		_beeped = -1

	if player == null:
		return

	# Every knock this client's own player took — predicted, so it is felt the tick it
	# happens. A knock is the one moment on a course the screen should move by itself.
	if player.knocks < _knocks_seen:
		_knocks_seen = player.knocks

	if player.knocks > _knocks_seen:
		_knocks_seen = player.knocks

		if audio != null:
			var _heard := audio.on_knock(player.global_position)

		if announcer != null:
			announcer.on_knock(true)

		if game.effects != null and camera != null:
			game.effects.viewer_position = camera.global_position
			game.effects.shake_at(&"knock", player.global_position, 10.0)


func _present_effects(delta: float) -> void:
	# The ears are wherever the eyes are, which for somebody who is out is the spectator
	# camera — so a player watching a team-mate hears what that team-mate hears.
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

		# The machinery, from the time the course was drawn at this frame.
		if game.stage != null and not game.stage.doc.is_empty() and _stage_seconds >= 0.0:
			var _machines := audio.present_machinery(game.stage, _stage_seconds, camera.global_position)

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


# --- Watching, once out -----------------------------------------------------

## Whether this client's own player is out and watching somebody.
func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


## The player whose eyes this camera is behind, so their body is not drawn around it.
func _watched_through_eyes() -> WoPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


## Puts the camera where [WoSpectate] says, and takes it back when a round starts.
##
## [b]The camera leaves the player's node while they watch.[/b] Setting a global transform
## on a camera hung under the chase arm is undone by the arm on its next frame, and one hung
## under the body is under a body that is not where anything worth seeing is. So it is moved
## to this node for as long as the player is out and handed back by `_place_camera` — the
## same call a view swap uses — the moment they are not.
##
## Once a FRAME, like the rig: the target's pose is the drawn one, so a camera moved on the
## tick would step at the tick rate however smoothly the target is drawn.
func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

			if view_model != null and is_instance_valid(view_model):
				view_model.visible = true

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# A view model left on is somebody else's gun drawn in front of the camera.
	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false

	# Chase and death cameras pulled out of the course by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(player.player_id)

	if game.spectate.is_roaming(player.player_id):
		where = _fly_free_camera()
	else:
		_free_cam = null

	# Identity is dot-spectate's "no answer" — a target it could not find. Holding the last
	# frame is better than a camera at the world origin.
	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		game.spectate.roam_key = _key(WoBindings.ROAM)
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


## The free-roam key: into a free camera while out, and back onto a player from it. On a
## connected client the server decides (it owns the mode, and says no with a notice when
## `mp_freeroam 0` or `mp_forcecamera` forbids it); offline the local world is the server.
func toggle_roam() -> void:
	if not is_spectating():
		return

	_free_cam = null
	_roam_look = Vector2.ZERO

	if bridge != null:
		bridge.ask_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded
## from where the camera was on the first frame of a roam, so it starts where the spectator
## looked. The pose is kept in the manager too, so a later hand-over starts from it.
func _fly_free_camera() -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(camera.global_transform)

	var sens := deg_to_rad(_sampler.tunables.mouse_sensitivity) if _sampler != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if _pointer_ours() and not _covered():
		move = Vector3(
			_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
			_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
			_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
		)

	var pose := _free_cam.step(
		move, _held(&"dot_fps_sprint"), _held(&"dot_fps_walk"), get_process_delta_time()
	)
	var _kept := game.spectate.manager.move_free(String(player.player_id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := WoBindings.make().row_for_action(action)
	return str(row.get("default", action))


## Asks for the next or previous person to watch, or the other camera.
func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)

		if audio != null:
			var _denied := audio.deny()


## Everything a frame draws that a tick does not, in this order: the netcode's
## interpolation, then every player's body, then every beacon. Returns how many bodies are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [b]The interpolation was never called in this game, and a comment here said it was.[/b]
## `present_beacons`, which this replaces, read a remote player's node on the grounds that
## "everybody else's node is written by the interpolator once a frame already" — and nothing
## anywhere called `DotNetManager.interpolate_frame`, so nothing wrote it. The
## `_net_interpolated` hooks on `WoPlayerNet` and `WoPropNet` were written, documented and
## reached by nothing, and every remote player and prop moved only when a snapshot landed —
## mg-smash-copter's finding, the render-jitter class. The other half was that a remote player had no body to move
## ([WoFigure]).
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which is what
## hides their own body. [param alpha] is the fraction through the current tick; -1 derives it
## from the engine, which is what a real frame wants. A suite passes it, because a suite's
## frames are not an engine's.
static func present_frame(
	p_net: DotNetManager,
	p_game: WoGame,
	own: WoPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: WoPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0

	for key: StringName in p_game.players:
		var body: WoPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.side_colour(p_game.team_of(key))

		# And whoever a spectator is looking out of: a camera inside somebody's head draws the
		# inside of their head.
		if body.present_body((mine and first_person) or body == watched, at, colour):
			shown += 1

		# Every player's beacon, this client's own included — somebody who has been beaconed
		# sees their ring and hears their ping too. After the interpolation, so a ring is
		# placed where this frame draws them rather than where the last one did.
		var _pinged := body.present_beacon(delta, at, mine)

	return shown


## Where this frame draws [param body].
##
## [b]Two sources, and which one is not a detail.[/b] A player somebody else simulates — any
## [param remote] player on a connected client — is placed by the interpolator, which writes
## their node once a frame; their controller never ticks here, so its render state is a blend
## of two ticks that never happened. A player THIS process simulates — the local player, and
## every offline stand-in — has a node that moves once a tick, and `render_state` is the
## blend between the last two, which is what the camera is drawn from too.
static func drawn_position(body: WoPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		# Opens the settings when the menu left this Escape alone, because a released pointer
		# with nothing on screen to click was a key that did half a job. A second Escape never reaches here: dot-ui's stack
		# sits deeper in the tree, sees it first, and closes the screen.
		if settings != null:
			settings.open()
		return

	# The game's keys, each a row of [WoBindings] read through its action, so a key moved on
	# the Controls page moves what it does here.
	if event is InputEventKey:
		if event.is_action_pressed(WoBindings.ROAM) and is_spectating():
			toggle_roam()
			return

		if event.is_action_pressed(WoBindings.VIEW):
			# Out, the key swaps the SPECTATOR's camera, which the server decides.
			if is_spectating():
				spectate_step(0)
			else:
				toggle_view()
			return

		# The slots. One to five, which is what the pack uses.
		for i in range(WoBindings.SLOTS.size()):
			if event.is_action_pressed(WoBindings.SLOTS[i]):
				_slot = i + 1
				return

		if event.is_action(WoBindings.RELOAD):
			_reloading = event.is_pressed()
			return

		if event.is_action(WoBindings.GRAB):
			# Held, and sent every tick in this game's own input message; the server makes the
			# edge. A request instead would be a pick-up resolved a round trip after the key,
			# against a prop that has moved.
			_grab = event.is_pressed()
			return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		# Out, the buttons step through who to watch. Nobody out has a weapon, and a click
		# that fired nothing and moved nothing is reported as the game having frozen.
		if is_spectating():
			_firing = false
			_alt = false

			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

		# The wheel goes through the weapons held, and does nothing with fewer than two:
		# never a jump some of the time. Spectating returned above, so this is alive only.
		if button.pressed and _pointer_ours():
			if event.is_action_pressed(&"dot_menu_weapon_next"):
				_wanted_cycle(1)
			elif event.is_action_pressed(&"dot_menu_weapon_previous"):
				_wanted_cycle(-1)

		if button.button_index == MOUSE_BUTTON_LEFT:
			_firing = button.pressed
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_alt = button.pressed

	if player == null:
		return

	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	# Every event, not only motion: the sampler also reads the wheel (dot-player-controller 5).
	# Motion still waits for the captured pointer.
	if event is InputEventMouseMotion and not _pointer_ours():
		return

	if _offline and player.sampler != null:
		player.sampler.handle_event(event)
	elif _sampler != null:
		_sampler.handle_event(event)


## Steps the wanted slot through the slots held, skipping empty ones.
func _wanted_cycle(step: int) -> void:
	if weapons == null or weapons.arsenal == null:
		return

	var carried := weapons.arsenal.slots()

	if carried.size() < 2:
		return

	var at := carried.find(weapons.arsenal.current_slot())
	_slot = carried[posmod(at + step, carried.size())]


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
		"armed": weapons != null,
		"watching": String(game.spectate.watching(player.player_id))
			if is_spectating() else "-",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out


## dot-game's chat box and microphone, with this game's channels and voice format. It also
## draws dot-server's own lines (the vote between games, joins, an admin's `say`), which arrive
## on the shell's client link rather than on this game's bridge. Static so a suite can build
## the same box the client does.
static func new_chat() -> DotGameChatClient:
	var box := DotGameChatClient.new()
	box.name = "Chat"
	box.channels = [
		{"id": WoServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": WoServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": WoServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	box.max_length = WoServices.chat_rules().max_length
	box.voice_config = WoServices.voice_format()
	return box


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: WoPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
