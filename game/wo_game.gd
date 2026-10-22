extends Node3D

const WoCatalogue := preload("wo_catalogue.gd")
const WoConfig := preload("wo_config.gd")
const WoContent := preload("wo_content.gd")
const WoCourse := preload("wo_course.gd")
const WoCourseDoc := preload("wo_course_doc.gd")
const WoPlayer := preload("wo_player.gd")
const WoProgress := preload("wo_progress.gd")
const WoRacer := preload("wo_racer.gd")
const WoRules := preload("wo_rules.gd")
const WoSpectate := preload("wo_spectate.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is a course and, sometimes, a fight.[/b] Everybody runs the same course from
## the same start. Falling in costs time — you are put back at the last checkpoint you
## crossed — and never the round. When everybody is across, or the clock runs out, the round
## is decided by who finished: nobody (whoever got furthest wins), one side (it wins), or two
## or more — and then everybody who finished is thrown into an arena they have never seen,
## with props to pick up and throw and weapons lying about, for a last-side-standing final
## death. Everybody who did not finish watches it from the gallery.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [WoRules]); health and damage are dot-combat's; the props
## and the hand that carries them are dot-props'; the weapons are zee-dot-weapons'. The
## course and everything on it are [WoCourse], and are this game's own.

const CHANNEL := "wo.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"wo_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

## Snapshots a second. Thirty, like mg-smash-copter: what a player reads continuously here is
## other people on moving ground, and at twenty a rider on a turntable steps.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire.
##
## [b]Five hundred and twelve, against mg-smash-copter's two hundred and fifty-six,[/b] because
## a course is long: the longest in mg-wipeout-maps runs two hundred metres from the start.
## Both ends read it from here; game-arena once had two numbers in two files and drew sky in
## every direction.
const NET_WORLD_EXTENT := 512.0

const TEAM_COLOURS: Array[Color] = [
	Color(0.85, 0.27, 0.26),
	Color(0.29, 0.53, 0.86),
	Color(0.35, 0.72, 0.38),
	Color(0.92, 0.78, 0.22),
	Color(0.66, 0.42, 0.82),
	Color(0.91, 0.55, 0.20),
]

## What the stand-ins are called, solo and on a server, through dot-bot's [DotBotNames]
## (never doubled up, and numbered only past the end of the list). Not "Stand-in 2": a board of
## numbered stand-ins tells a player they are alone.
const BOT_NAMES := [
	"Splash", "Tumble", "Wobble", "Dunk", "Belly Flop", "Soggy", "Bounce", "Skid",
	"Cannonball", "Flipper", "Squelch", "Ripple", "Puddle", "Noodle", "Slick", "Drip",
]

const TEAM_NAMES: Array[String] = [
	"Red", "Blue", "Green", "Yellow", "Violet", "Orange",
]

## Where the first solo side starts. A side id above any team id, so "is this a team" is a
## comparison and a solo side can never be mistaken for red.
const SOLO_SIDE_BASE := 100

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people to start one.
	IDLE,
	## Everybody on the start pad behind the gate.
	COUNTDOWN,
	## The gate is down and the course is open.
	COURSE,
	## The finishers are in the arena, unhurtable, while the props land.
	HANDOVER,
	## The final death.
	FINALE,
}

const DIED_SHOT := &"shot"
const DIED_THROWN := &"thrown"
const DIED_FELL := &"fell"
const DIED_BLAST := &"blast"
## Knocked out on the course by an obstacle, or by lightning.
const DIED_KNOCKED := &"knocked"
const DIED_STRUCK := &"struck"
## Landed too hard on the course: [member WoConfig.fall_damage_per_metre].
const DIED_LANDED := &"landed"

## The ragdoll reaction a knockout at low health gets: a flight, not a fall. This game's own
## entry on dot-player-char's stock set, on the server (which picks it) and on the client (which
## looks it up by this id). Weight 0 so a roll never picks it; only [method decide_death] names it.
const FLING := &"wipeout_fling"

## Metres within which a player standing over a weapon picks it up.
const PICKUP_REACH := 1.3

## How far a prop may be from somebody's eyes to be picked up, in metres.
const GRAB_REACH := 3.5

## Seconds a thrown prop is "thrown" — dangerous, and credited to whoever threw it.
const THROWN_SECONDS := 3.0

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began, on [param course_id].
signal round_began(number: int, course_id: StringName)

## The stage is about to be taken down and rebuilt. Before, for the bridge's sake.
signal world_clearing()

## The stage has just been rebuilt: a course at the top of a round, an arena at a handover.
signal world_rebuilt()

## A round ended. [param winner] is a side (0 for a draw); [param winner_name] says who.
signal round_over(number: int, winner: int, winner_name: String)

signal phase_changed(phase: int)

signal player_died(player_id: StringName, by: StringName, why: StringName)

## Somebody fell in and was put back. Not a death: the course goes on.
signal player_fell(player_id: StringName, checkpoint: int)

signal checkpoint_reached(player_id: StringName, index: int)

## Somebody crossed the finish, [param place] first, in [param seconds].
signal player_finished(player_id: StringName, place: int, seconds: float)

signal achievement_earned(player_id: StringName, title: String, points: int)

## Somebody was handed, or picked up, a weapon.
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

## A weapon was laid out in the arena, or picked up off the floor.
signal pickup_placed(pickup_id: int, weapon_id: StringName, at: Vector3)
signal pickup_taken(pickup_id: int, by: StringName)

signal blast(at: Vector3, radius: float)

@export var config: WoConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick: the bridge, on both ends. See mg-smash-copter.
@export var external_tick: bool = false

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

## Whether the stage draws its sky and water. A client sets it.
@export var draw_world: bool = false

## The course, or during a final death the arena. One node, rebuilt. See [method _begin_handover].
var stage: WoCourse = null

var catalogue: WoCatalogue = null

## The course the next round plays, set by the players' vote ([code]game/wo_vote.gd[/code]) or
## an operator, and used once. Empty lets the rotation choose.
var next_course_id: StringName = &""
var props: DotPropSpawner = null
var prop_damage: DotPropDamage = null
var combat: DotCombatManager = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from dot-game's `can_peer_be_harmed`. Unset offline, and a bot is never loading.
var harm_gate: Callable = Callable()
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## dot-props' `sv_toys*` (whether a stage's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. The game's, not the map's.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players and stand-ins block each other). Bound by the module
## (REPLICATED) and followed by a client through its link: the client places its camera
## under the first and predicts its own player under the second.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}
var effects: DotFxManager = null
var spectate: WoSpectate = null
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. One object for the life of the
## game, shared with [WoSpectate]'s manager, so a cvar change reaches the rules in use. Bound
## by the module (REPLICATED) and followed by a client, which is the end that flies the camera.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()
var progress: WoProgress = null

## player id -> WoPlayer.
var players: Dictionary = {}

## player id -> side. A team id with teams, a side of one's own (100+) without.
var sides: Dictionary = {}

var round_number: int = 0

## Seconds into the current phase. Simulated, never a wall clock.
var phase_elapsed: float = 0.0

## Seconds into the course, from the gate dropping. What a finish time is.
var course_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The course this round is being run on, and the arena if the round reached one.
var course_doc: Dictionary = {}
var arena_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_finished: int = -1
var remote_alive: int = -1
var remote_playable: bool = false

## The pickups lying in an arena: id -> {weapon, at}.
var pickups: Dictionary = {}

var _tick: int = 0
var _round_seed: int = 0
var _finish_count: int = 0

## Which course of the round is running, from 1. See [member WoConfig.courses_per_round].
var _courses_run: int = 1
var _next_solo_side: int = SOLO_SIDE_BASE
var _next_pickup: int = 1

## Whether the course standing now has not been raced yet: the warmup's, until round one.
var _course_unplayed: bool = false

## Whether the round has been decided, and who won. What [WoRules] reads.
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## prop instance id -> {by, until}: who threw it and when it stops being dangerous.
var _thrown: Dictionary = {}

## player id -> the last tick a thrown prop hurt them, so one prop is one hit.
var _thrown_hit: Dictionary = {}

## A hop from stone to stone covers about this many metres a second, landing to landing.
const SPAN_HOP_SPEED := 4.8
## How early or late a runner may be against the timing of [method _span_clear], in seconds.
const SPAN_SLACK := 0.25

## Bots: player id -> the route point they are heading for.
var _bot_route: Dictionary = {}
var _bot_wait: Dictionary = {}

## Bots: player id -> how this stand-in is racing this round: the plan for the route point it
## is heading for (fumble, early or late, rash), when a window was seen, a pause after a fall,
## its own skill factor, and its dot-bot [DotBotAim] for a final death. See [method _racer_of].
var _bot_racer: Dictionary = {}

## How the stand-ins race: mistake rates by dot-bot's `bot_difficulty`. See [WoRacer].
var racer: WoRacer = null

## Bots: player id -> ticks spent getting up to speed on a top before jumping off it.
var _bot_runup: Dictionary = {}

## Bots: player id -> `[position, tick]` a second ago, for [method _bot_unstick].
var _bot_stuck: Dictionary = {}


func _ready() -> void:
	if config == null:
		config = WoConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved for "the process cannot continue", and a configuration that
		# contradicts itself is not that: say so loudly and refuse to run a round.
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value
	racer = WoRacer.new(DotBotSettings.of(self))
	racer.mistakes = config.bot_mistakes

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_stage()
	_build_props()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = WoCatalogue.new()
		var _loaded := catalogue.load_from(config.course_directory)
		# Solo in the client shell: the map packs it mounted for this game, which a server
		# would have named. See [method solo_map_dirs].
		for root in solo_map_dirs("courses"):
			var _added := catalogue.add_directory(root)
		# The Workshop's courses, solo only by the index's own session (an online session lists none).
		catalogue.follow_content(DotContentIndex.shared(), WoCatalogue.accepted_map_kinds())
		var _rotation := load_rotation()
		# Laid out now, not on the first round: dot-match runs a warmup first, and an empty
		# world through the warmup is indistinguishable from a map that failed to load.
		_lay_out_course()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The player's motor mask under `mp_solidplayers`, and the players' layer as one they may
## walk out of (`apply_to`; through `set_collision_mask`, which a style does not undo).
##
## [b]Stand-ins are on a layer of their own, and pass through each other.[/b] A person stops at
## a stand-in's shoulder and a stand-in at a person's (the camera rule `mp_solidplayers` is
## for); two stand-ins never meet. Eight of them racing as one solid crowd shoved each other
## off every edge and queued at every run of tops, and a field of eight took four times as
## long over five balls as two did, which is a crowd of bots, not a race.
func _apply_body_mask(player: WoPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	var others := physics.layer_mask(&"player") | (0 if player.is_bot else physics.layer_mask(&"bot"))
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), others)
	# The capsule the others stop at: a player's body has no shape of its own.
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## A player became (or stopped being) a stand-in: its layer and mask follow.
func _on_bot_changed(player: WoPlayer) -> void:
	if physics == null or not is_instance_valid(player):
		return
	var _applied := physics.apply_to(player, &"bot" if player.is_bot else &"player")
	_apply_body_mask(player)


## `mp_solidplayers` changed: every player's mask now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as WoPlayer)


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (dot-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([DotGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The named collision layers. Three kinds of thing here: the world, players and props.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"wipeout", [&"world", &"player", &"bot", &"prop", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player", &"bot":
				# Not other players in the layout. `mp_solidplayers` (1 since the first play
				# test, where stand-ins walked into the camera at the start line) adds them to
				# each player's motor mask and gives each a hull; a server that would rather
				# have the race fair sets 0, because a shove on a narrow beam is decided by who
				# walked into whom, and the other player is drawn in the past on every client.
				layer.collides_with = [&"world", &"prop"]
			&"prop":
				layer.collides_with = [&"world", &"player", &"bot", &"prop", &"toy"]
			# A stage's loose toy (dot-props'): the course, its machinery, a thrown prop and the
			# other toys, never a person, who walks through it and pushes it (`_advance_toys`).
			&"toy":
				layer.collides_with = [&"world", &"prop", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player", &"bot", &"prop"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the course is tuned against, on this world's own physics SPACE. A project
## setting does not travel with a delivered pack; see [member WoConfig.gravity].
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		DotLog.warn(CHANNEL, "no world to set gravity on", {})
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	# Off: a registry name is process-wide, and two worlds in one process is every suite.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_stage() -> void:
	stage = WoCourse.new()
	stage.name = "Stage"
	stage.physics = physics
	stage.tick_rate = tick_rate
	stage.draw_world = draw_world
	stage.authoritative = authoritative
	stage.toy_rules = toy_rules
	stage.gravity = config.gravity
	add_child(stage)


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.catalogue = WoContent.props(config)
	props.limits = DotPropLimits.new()
	# The world puts these out, not a player: the per-player budget and cooldown are the wrong
	# shape, and the world cap has to be above what an arena asks for or the last few silently
	# never appear.
	props.limits.spawn_interval = 0.0
	props.limits.per_player_budget = config.prop_budget + 10
	props.limits.world_budget = config.prop_budget + 10
	props.limits.clean_up_on_leave = false
	props.authoritative = authoritative
	add_child(props)

	prop_damage = DotPropDamage.new()
	prop_damage.name = "PropDamage"
	prop_damage.authoritative = authoritative
	props.add_child(prop_damage)
	prop_damage.exploded.connect(_on_prop_exploded)

	props.removed.connect(func(prop: DotPropInstance, _reason: StringName) -> void:
		_thrown.erase(prop.instance_id)
	)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

	# Lag compensation OFF here and turned on by the bridge with the callables that make it
	# real — mg-smash-copter's finding: left on, a delivered server logged "no rewind
	# function" at every boot about a server where it works.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A trace, or every shot goes through the arena's walls. Before `setup`, which warns.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# Which side an entity is on, or friendly fire is ON in a team game whose rules say off —
	# and in a solo game every player is their own side, so `team_of` answering 0 for all of
	# them would make everybody everybody's team mate and nobody could hurt anybody.
	combat.resolver = DotDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# dot-game's "still loading": the one place every hurt passes (a knock, a landing, a blast,
	# a thrown prop, a shot, the arena's water), so a covered seat is neither hurt nor
	# eliminated, and the final death counts the living from health. An admin's slay or slap is
	# the operator's word and passes.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if damage.context.get("admin", false):
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

	# `add_child` IS the setup; calling it again doubled every boot line. See mg-smash-copter.
	add_child(combat)


## A shake for a knock and a flash for the gate, and nothing else. Client side.
func _build_effects() -> void:
	if authoritative:
		return

	var catalogue_fx := DotFxCatalogue.new()

	var knock := DotFxDef.new()
	knock.id = &"knock"
	knock.kind = DotFxDef.Kind.SHAKE
	knock.shake_trauma = 0.45
	knock.max_distance = 12.0
	catalogue_fx.add(knock)

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.22
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	catalogue_fx.add(go)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue_fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	match_node.config = match_config

	var rules: DotMatchRules = WoRules.make()
	rules.intermission_sec = config.intermission_seconds
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.team_based = config.teams()
	# Two: one person alone on a course has nobody to beat and no final death to reach, and a
	# server holding one person would start a round, decide it and start another. The bots
	# (`minimum_players`) are what makes an empty server playable.
	rules.min_players = 2
	rules.set(&"decision_fn", _decision)
	rules.time_limit_sec = _round_time_limit()
	match_node.rules = rules

	# Scoped to the match node, which finds nothing: this game places its own players, and an
	# unset `spawns_ref` walks the whole scene and finds another world's. See mg-smash-copter.
	match_node.spawns_ref = DotNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = []

	for index in range(config.team_count if config.teams() else 0):
		teams.append(DotTeam.make(index + 1, TEAM_NAMES[index], TEAM_COLOURS[index]))

	match_node.teams.teams = teams
	match_node.teams.force_balance = config.autobalance
	match_node.teams.allow_choice = config.allow_team_choice
	# Off: `sides` decides a team and dot-match is told. Its default of 1 refused joins and
	# left stand-ins on no team in two games before this one.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = WoSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	spectate.in_showdown_fn = func(p: int) -> bool:
		return p == Phase.HANDOVER or p == Phase.FINALE
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = WoProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


func _refresh_overviews() -> void:
	if spectate == null or stage == null:
		return

	var box := stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 12.0)
	var eye := centre + Vector3(reach * 0.6, reach * 0.55 + 10.0, reach * 0.6)
	var view := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)
	spectate.set_overviews(view, view)


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_team] is a team id, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_team: int = 0,
	samples_input: bool = false
) -> WoPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := _side_for_new_player(wanted_team)

	var player := WoPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.stage = stage
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"bot" if player.is_bot else &"player")
		player.bot_changed.connect(_on_bot_changed.bind(player))

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which defaults to 1. A controller left on the default
		# sweeps against layer one only, which is a player falling through the course. With
		# `mp_solidplayers` on, other players are in it too: a stand-in at the start line
		# stops at your shoulder instead of walking through your face (the first play test).
		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(
			String(player_id), display_name, _tick, side if config.teams() else 0
		)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {
				"id": String(player_id), "side": side, "why": seated.error.message,
			})

	# Placed NOW, not only at the top of a round: a joiner left at the origin is a joiner in
	# the water, and mg-smash-copter's version of that ended rounds.
	place_one(player)

	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})

	# Last, after the health and the side: the bridge answers this by replicating the player.
	player_added.emit(player_id)
	return player


## Somewhere on a player a shot can land. Without it nobody can be shot and nothing says so.
func _give_hitboxes(player: WoPlayer) -> void:
	var boxes := DotHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = DotNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := DotHitbox.new()
	body.name = "Chest"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, WoPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can be, for the phase it is.
##
## A joiner in the middle of a course starts at the start, behind everybody, which is honest;
## a joiner during a final death they did not reach watches it from the gallery.
func place_one(player: WoPlayer) -> void:
	if stage == null or stage.doc.is_empty():
		return

	if stage.is_arena():
		player.watching = true
		var spot := stage.gallery_spot(players.size())
		player.place_at(spot[0], spot[1])
		return

	# Full rows, not centred on how many there are: a joiner's seat must not move the seats
	# of the people already standing there, or the second joiner lands on the first.
	var spot := stage.start_spot(players.size() - 1, 1000)
	player.place_at(spot[0], spot[1])

	if spectate != null:
		spectate.on_spawned(player.player_id)


## Which side somebody new goes on.
##
## With teams, the smallest one, ties to the lower id — explicitly, because a server and a
## client that disagree about somebody's side disagree about friendly fire. Without, a side
## of their own, numbered from [constant SOLO_SIDE_BASE] in join order.
func _side_for_new_player(wanted: int) -> int:
	if not config.teams():
		_next_solo_side += 1
		return _next_solo_side - 1

	if wanted >= 1 and wanted <= config.team_count:
		return wanted

	var counts: Array[int] = []
	counts.resize(config.team_count)
	counts.fill(0)

	for id: StringName in sides:
		var side := int(sides[id])

		if side >= 1 and side <= config.team_count:
			counts[side - 1] += 1

	var smallest := 0

	for index in range(config.team_count):
		if counts[index] < counts[smallest]:
			smallest = index

	return smallest + 1


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: WoPlayer = players[player_id]

	if player.grab != null:
		var _dropped := player.grab.drop()

	# Before the node goes: dot-combat keyed a health on this entity, and a stale record has
	# no symptom until the process runs out of memory.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	_bot_route.erase(player_id)
	_bot_racer.erase(player_id)
	_bot_wait.erase(player_id)
	_bot_runup.erase(player_id)
	_bot_stuck.erase(player_id)
	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


## A side's name: a team's colour, or the one player on a solo side.
func side_name(side: int) -> String:
	if side >= 1 and side <= TEAM_NAMES.size() and config.teams():
		return TEAM_NAMES[side - 1]

	for id: StringName in sides:
		if int(sides[id]) == side and players.has(id):
			return (players[id] as WoPlayer).display_name

	return "nobody"


func side_colour(side: int) -> Color:
	if side >= 1 and side <= TEAM_COLOURS.size() and config.teams():
		return TEAM_COLOURS[side - 1]

	# A solo side's colour, from its number, so every client paints the same person the same.
	return Color.from_hsv(fposmod(float(side) * 0.137, 1.0), 0.55, 0.85)


func players_on(side: int) -> Array[WoPlayer]:
	var out: Array[WoPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many people are up and in the arena, or on the course.
func alive_count() -> int:
	if not authoritative and remote_alive >= 0:
		return remote_alive

	var total := 0

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.is_alive() and not player.watching:
			total += 1

	return total


## Whether [param player_id] may be damaged, eliminated or counted as across now: false while
## their client is behind its loading cover. True for anybody the gate does not know (bots,
## offline).
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


func finished_count() -> int:
	if not authoritative and remote_finished >= 0:
		return remote_finished

	return _finish_count


## Whether there are enough people for a round. Two, of anybody.
func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here, not only in `_ready`: the world furnishes itself when it opens, but on
	# a server nothing is listening then — the module builds the bridge that answers
	# `world_rebuilt` — and a course built before it is a course no client is ever sent. A
	# player joining during the warmup would stand in an empty sky. The SAME course: the one
	# the warmup shows is the one the first round plays.
	#
	# Unless it is no longer one this server plays: on a delivered server the courses arrive
	# with the module, after the world opened on the only course it had then — the built-in
	# practice one, which drops out of the rotation once there is anything else.
	var id := StringName(str(course_doc.get("id", "")))

	if not course_doc.is_empty() and catalogue != null \
			and catalogue.playable_courses(config.course_ids).has(id):
		var _rebuilt := build_stage(course_doc)
		_place_on_start()
	else:
		_lay_out_course()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# Everybody is back in: instant death lasts until the round is over, not longer.
	for id: StringName in players:
		(players[id] as WoPlayer).out_for_round = false

	# The course the warmup showed, for the first round; the next one after that. Drawing a new
	# course here every time put a player who had spent the warmup reading one course on a
	# different one the moment the round began.
	if _course_unplayed and not course_doc.is_empty():
		var _rebuilt := build_stage(course_doc)
		_place_on_start()
	else:
		_lay_out_course()

	_course_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	_finish_count = 0
	_courses_run = 1

	if match_node != null and match_node.rules != null:
		match_node.rules.time_limit_sec = _round_time_limit()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.COUNTDOWN)
	round_began.emit(number, stage.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "course": String(stage.id()), "seed": _round_seed,
		"players": players.size(),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## The next course, built, and everybody on its start pad.
func _lay_out_course() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	# What the players voted for, once, if it is still a course this server plays (a
	# wo_reload between the vote and the round can take it away). The rotation otherwise.
	if next_course_id != &"" and catalogue.playable_courses(config.course_ids).has(next_course_id):
		doc = catalogue.courses[next_course_id]

	next_course_id = &""

	if doc.is_empty():
		doc = catalogue.next_course(
			config.course_ids, config.shuffle_courses, random.stream(&"course"),
			StringName(str(course_doc.get("id", "")))
		)

	# The round's weather, drawn here and sent inside the document, so every machine reads
	# the same gusts and strikes and nothing more travels per tick.
	if authoritative and not doc.is_empty():
		doc = doc.duplicate(true)
		doc["weather"] = draw_weather(doc, random.stream(&"weather"), _tick)

	catalogue.note_played(StringName(str(doc.get("id", ""))))
	build_stage(doc)
	_place_on_start()
	_course_unplayed = true


## Every course this server plays, as the map menu (M) lists them: `{id, name, detail,
## current}`, the blurb under the name. Solo the client's list, online the
## server's (the module hands it to dot-vote's map menu), so both say the same.
func course_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(course_doc.get("id", "")))
	for id in catalogue.playable_courses(config.course_ids):
		var doc: Dictionary = catalogue.courses.get(id, {})
		# The blurb under the name ("Everything once, and gently"): a course has no mode, and its
		# `theme` is the sky's colours, not a word.
		var rotates := catalogue.in_rotation(id)
		var row := {"id": String(id),
			"name": catalogue.label_of(id) + ("" if rotates else " (not in rotation)"),
			"in_rotation": rotates, "current": id == now,
			"detail": str(doc.get("blurb", ""))}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


## The map menu's change: [param id] now, not after this round. The next course is set and a
## fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running yet it is simply built. Authority only.
func change_course_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the course.")
	if catalogue == null or not catalogue.playable_courses(config.course_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no course called '%s' here." % id)
	next_course_id = id
	# The warmup's course is not the one to keep: the next round is the chosen one.
	_course_unplayed = false
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_course()
	DotLog.info(CHANNEL, "course changed from the map menu", {"course": String(id)})
	return DotResult.success(id)


## Reads maps.yml (the `--config` directory first) and applies it. Called at boot and by
## `sv_map_rotation_file`. A file that is present and unreadable is an ERROR and changes nothing:
## rotating every course is a better failure than rotating none.
func load_rotation() -> DotResult:
	if catalogue == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no catalogue to rotate.")

	var stem := config.map_rotation_file
	var dir := DotMapRotationFile.config_dir_arg()
	DotAddonConfig.game = "mg-wipeout"
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != WoConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every course rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()

	if found != "":
		# The layers that apply (an operator file replaces the shipped one unless it says merge: true); a named file or the legacy file stands alone.
		var layers := DotMapRotationFile.find_layers(dir, "mg-wipeout")
		paths = layers if layers.has(found) else PackedStringArray([found])

	var read := DotMapRotationFile.load_files(paths, "mg-wipeout")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every course rotates", {
			"why": read.error.message,
		})
		catalogue.rotation_file = null
		catalogue.apply_rotation(config.course_ids)
		return read

	catalogue.rotation_file = read.value
	catalogue.apply_rotation(config.course_ids)

	if catalogue.has_rotation_file():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(catalogue.rotation_file.sources),
			"active": catalogue.rotation_file.active_name(),
		})

	return read


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	if catalogue == null or catalogue.rotation_file == null:
		return {}

	return catalogue.rotation_file.commands()


## Every name a role of this game's own answers to (the first is the one help shows), from
## maps.yml's `commands:` block; the role's own name with no file.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return DotCommandNames.all_of("", names, {}, role)


## Gusts and lightning for one course, from the round's own stream. Ticks are game ticks
## from [param start]: the countdown and the whole course clock are covered.
func draw_weather(doc: Dictionary, rng: DotRandomStream, start: int) -> Dictionary:
	var out := {"gusts": [], "strikes": []}
	var rate := float(maxi(tick_rate, 1))
	var span := (config.countdown_seconds + course_limit_for(doc)) * rate

	if config.wind_strength > 0.0 and rng.next_unit() < config.wind_chance:
		for i in range(rng.next_range_i(2, 5)):
			var from := start + int(rng.next_range_f(config.countdown_seconds * rate, span * 0.9))
			var angle := rng.next_range_f(0.0, TAU)
			out["gusts"].append({
				"from": from, "to": from + int(rng.next_range_f(2.0, 6.0) * rate),
				"dx": cos(angle), "dz": sin(angle),
				"strength": rng.next_range_f(0.4, 1.0) * config.wind_strength,
			})

	if config.storm_strikes > 0 and rng.next_unit() < config.storm_chance:
		var route := _weather_route(doc)
		for i in range(config.storm_strikes):
			var spot: Vector3 = route[rng.next_range_i(0, route.size() - 1)] if not route.is_empty() else Vector3.ZERO
			out["strikes"].append({
				"tick": start + int(rng.next_range_f(config.countdown_seconds * rate, span * 0.95)),
				"x": spot.x + rng.next_range_f(-3.0, 3.0), "y": spot.y, "z": spot.z + rng.next_range_f(-3.0, 3.0),
				"radius": config.strike_radius,
			})

	return out


## Where on a course lightning can land: the start, every checkpoint and the finish.
func _weather_route(doc: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for key in ["start", "finish"]:
		var spot: Variant = doc.get(key, {})
		if typeof(spot) == TYPE_DICTIONARY and (spot as Dictionary).has("at"):
			out.append(_vec(spot["at"]))
	for checkpoint in doc.get("checkpoints", []):
		if typeof(checkpoint) == TYPE_DICTIONARY and (checkpoint as Dictionary).has("at"):
			out.append(_vec(checkpoint["at"]))
	return out


static func _vec(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


## Builds [param doc] as the stage. What the server does at a round start and a handover,
## and what a client does when it is sent one.
func build_stage(doc: Dictionary) -> DotResult:
	world_clearing.emit()
	_clear_props()

	var built := stage.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a stage would not build", {
			"id": str(doc.get("id", "?")), "why": built.error.message,
		})
		return built

	if stage.is_course():
		course_doc = stage.doc
		arena_doc = {}
	else:
		arena_doc = stage.doc

	stage.gate_closed = phase == Phase.COUNTDOWN or stage.is_course()
	_refresh_overviews()

	# Last, once it is all standing: the bridge answers this by sending the document.
	world_rebuilt.emit()
	return built


func _place_on_start() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	for seat in range(ids.size()):
		var player: WoPlayer = players[ids[seat]]
		player.reset_progress()
		_disarm(player)

		if player.out_for_round:
			# Out until the round is over: the next course of it is watched from the lounge.
			if player.health != null:
				player.health.health = config.player_health
				player.health.alive = true
				player.health.invulnerable = true
			var lounge := stage.lounge_spot(20 + ids.size() + seat)
			player.place_at(lounge[0], lounge[1])
			continue

		if player.health != null:
			player.health.health = config.player_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot := stage.start_spot(seat, ids.size())
		player.place_at(spot[0], spot[1])
		_bot_route[player.player_id] = 0
		_bot_racer.erase(player.player_id)

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	if stage != null and stage.is_course():
		stage.gate_closed = to == Phase.COUNTDOWN or to == Phase.IDLE

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## The clock, and every decision it makes.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.COUNTDOWN:
			if phase_elapsed >= config.countdown_seconds:
				course_elapsed = 0.0
				_set_phase(Phase.COURSE)
		Phase.COURSE:
			course_elapsed += delta

			if _course_is_over():
				_close_course()
		Phase.HANDOVER:
			if phase_elapsed >= config.handover_seconds:
				_begin_finale()
		Phase.FINALE:
			_check_finale()


## The course's own clock: the document's, under the server's ceiling.
## [method course_limit] for a document not yet built, for drawing its weather.
func course_limit_for(doc: Dictionary) -> float:
	var asked := float(doc.get("course_seconds", 0.0))
	return minf(asked, config.course_seconds) if asked > 0.0 else config.course_seconds


func course_limit() -> float:
	var asked := float(course_doc.get("course_seconds", 0.0))
	return minf(asked, config.course_seconds) if asked > 0.0 else config.course_seconds


func _course_is_over() -> bool:
	if course_elapsed >= course_limit():
		return true

	# Everybody across. "Nobody left on the course" is the same thing here: there is no way
	# off a course but the finish, and a leaver is not on it.
	for id: StringName in players:
		var player := players[id] as WoPlayer
		# Knocked out of the round is off the course too, or a round with an elimination in
		# it always runs its clock out.
		if not player.finished and not player.watching:
			return false

	return not players.is_empty()


## Which course of the round is running, from 1, for the HUD's "Course 2 of 3".
func course_number() -> int:
	return _courses_run


## dot-match's backstop for a round: every course it may run, then the final death.
func _round_time_limit() -> float:
	return float(config.courses_per_round) * (config.countdown_seconds + config.course_seconds) \
		+ config.handover_seconds + config.finale_seconds + 60.0


## The next course of the same round: everybody back on a start pad, healed, with their points
## kept. Nobody is told "round began" again; the new STAGE and the phase say it.
func _begin_next_course() -> void:
	_courses_run += 1
	_finish_count = 0
	_lay_out_course()
	_place_on_start()
	_set_phase(Phase.COUNTDOWN)
	DotLog.info(CHANNEL, "the next course of the round", {
		"course": String(stage.id()), "number": _courses_run, "of": config.courses_per_round,
	})


## The course is closed. Who finished decides what happens next.
func _close_course() -> void:
	var through := finishing_sides()

	DotLog.info(CHANNEL, "the course closed", {
		"finished": _finish_count, "sides_through": through.size(),
		"seconds": "%.1f" % course_elapsed,
	})

	if through.size() >= 2:
		if _courses_run < config.courses_per_round:
			_begin_next_course()
			return
		_begin_handover(through)
		return

	if through.size() == 1:
		_decide(through[0], "%s finished the course" % side_name(through[0]))
		return

	if config.progress_decides:
		var furthest := _furthest_side()

		if furthest != 0:
			_decide(furthest, "%s got furthest" % side_name(furthest))
			return

	_decide(0, "nobody finished")


## Every side with somebody across the line, in the order they first got there.
func finishing_sides() -> Array[int]:
	var firsts: Dictionary = {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.finished:
			continue

		var side := int(sides.get(id, 0))

		if not firsts.has(side) or player.place < int(firsts[side]):
			firsts[side] = player.place

	var out: Array[int] = []

	for side: int in firsts:
		out.append(side)

	out.sort_custom(func(a: int, b: int) -> bool: return int(firsts[a]) < int(firsts[b]))
	return out


## The side whose best runner reached the furthest checkpoint; 0 on a tie or nobody.
func _furthest_side() -> int:
	var best := -1
	var best_side := 0
	var tied := false

	for id: StringName in players:
		var player: WoPlayer = players[id]
		var side := int(sides.get(id, 0))

		if player.checkpoint > best:
			best = player.checkpoint
			best_side = side
			tied = false
		elif player.checkpoint == best and side != best_side:
			tied = true

	return 0 if tied or best < 0 else best_side


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative and winner != 0:
		for id: StringName in players:
			if team_of(id) == winner:
				(players[id] as WoPlayer).points += config.winner_points
	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- The final death ---------------------------------------------------------

## The finishers into an arena, everybody else into its gallery, and the floor laid out.
##
## [b]A different arena, a different arrangement, a different floor every time[/b] — all of
## it drawn from the round's own seed, so a server and a replay of it agree. Which arena; which
## of its spawn areas each side is given (shuffled, so the same two sides are not always in
## the same two corners); where in its area each person stands; and where every prop and
## weapon lands inside the drop areas.
func _begin_handover(through: Array[int]) -> void:
	var stream := random.stream(&"finale")
	var doc := catalogue.pick_arena(config.arena_ids, stream) if catalogue != null \
		else WoCatalogue.practice_arena()

	_set_phase(Phase.HANDOVER)
	build_stage(doc)

	var areas: Array = stage.spawn_areas().duplicate()
	_shuffle(areas, stream)

	var watching_seat := 0

	for slot in range(through.size()):
		var side: int = through[slot]
		var area: Dictionary = areas[slot % areas.size()]
		var runners: Array[WoPlayer] = []

		for player in players_on(side):
			if player.finished:
				runners.append(player)

		for seat in range(runners.size()):
			var player: WoPlayer = runners[seat]
			var size: Vector2 = area["size"]
			var at := (area["at"] as Vector3) + Vector3(
				stream.next_range_f(-size.x * 0.4, size.x * 0.4),
				0.3,
				stream.next_range_f(-size.y * 0.4, size.y * 0.4)
			)
			# Facing the middle of the arena, the one direction that is never immediately a
			# wall or the drop.
			var inward := stage.bounds().get_center() - at
			player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))
			player.watching = false

			if player.health != null:
				player.health.health = config.player_health
				player.health.alive = true
				player.health.invulnerable = true

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if through.has(int(sides.get(id, 0))) and player.finished:
			continue

		# Everybody else watches. Not dead — nothing can reach them in the gallery — and not
		# on any side the final death counts.
		player.watching = true
		var spot := stage.gallery_spot(watching_seat)
		watching_seat += 1
		player.place_at(spot[0], spot[1])

		if player.health != null:
			player.health.invulnerable = true

	_drop_props(through.size(), stream)
	_lay_out_weapons(through.size(), stream)

	if progress != null:
		progress.on_handover()

	DotLog.info(CHANNEL, "the final death", {
		"arena": String(stage.id()), "sides": through.size(), "props": props.world_count(),
		"weapons": pickups.size(),
	})


func _begin_finale() -> void:
	_set_phase(Phase.FINALE)

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.health != null and not player.watching:
			player.health.invulnerable = false


## Last side standing, or the clock.
func _check_finale() -> void:
	var standing: Dictionary = {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		var side := int(sides.get(id, 0))
		standing[side] = int(standing.get(side, 0)) + 1

	if standing.size() == 1:
		var side: int = standing.keys()[0]
		_decide(side, "%s won the final death" % side_name(side))
		return

	if standing.is_empty():
		_decide(0, "nobody survived the final death")
		return

	if phase_elapsed >= config.finale_seconds:
		# The clock: the side with the most people up wins; a tie is a draw. Health would
		# break more ties and would also reward hiding, which is the one thing the clock is
		# there to stop.
		var best := 0
		var best_count := 0
		var tied := false

		for side: int in standing:
			if int(standing[side]) > best_count:
				best_count = int(standing[side])
				best = side
				tied = false
			elif int(standing[side]) == best_count:
				tied = true

		_decide(0 if tied else best, "time" if tied else "%s outlasted everybody" % side_name(best))


func _drop_props(sides_in: int, stream: DotRandomStream) -> void:
	var areas := stage.drop_areas()

	if areas.is_empty():
		return

	var ids := [WoContent.CRATE, WoContent.CRATE, WoContent.TYRE, WoContent.CONE,
		WoContent.BARREL, WoContent.BOULDER, WoContent.CRATE, WoContent.TYRE]
	var count := mini(config.finale_props_per_side * maxi(sides_in, 2), config.prop_budget)

	for i in range(count):
		var area: Dictionary = areas[stream.next_range_i(0, areas.size() - 1)]
		var size: Vector2 = area["size"]
		var at := (area["at"] as Vector3) + Vector3(
			stream.next_range_f(-size.x * 0.5, size.x * 0.5),
			2.5 + float(i % 4) * 1.2,
			stream.next_range_f(-size.y * 0.5, size.y * 0.5)
		)
		var id: StringName = ids[stream.next_range_i(0, ids.size() - 1)]
		var prop := props.spawn(id, WoContent.WORLD_OWNER, at)

		if prop != null and physics != null and prop.body() != null:
			var _applied := physics.apply_to(prop.body(), &"prop")


func _lay_out_weapons(sides_in: int, stream: DotRandomStream) -> void:
	pickups.clear()
	var areas := stage.drop_areas()
	var pool := _weapon_pool()

	if areas.is_empty() or pool.is_empty():
		return

	for i in range(config.finale_weapons_per_side * maxi(sides_in, 2)):
		var area: Dictionary = areas[stream.next_range_i(0, areas.size() - 1)]
		var size: Vector2 = area["size"]
		var at := (area["at"] as Vector3) + Vector3(
			stream.next_range_f(-size.x * 0.45, size.x * 0.45),
			0.7,
			stream.next_range_f(-size.y * 0.45, size.y * 0.45)
		)
		var weapon: StringName = pool[stream.next_range_i(0, pool.size() - 1)]
		var pickup_id := _next_pickup
		_next_pickup += 1
		pickups[pickup_id] = {"weapon": weapon, "at": at}
		pickup_placed.emit(pickup_id, weapon, at)


## Which weapons lie about. The set where every entry can win a fight, as in mg-smash-copter,
## plus the two melee weapons, because a prop and a hammer are this round's whole idea.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))
		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER, ZeeWeaponIds.SMG, ZeeWeaponIds.CARBINE, ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.DRUM_SHOTGUN, ZeeWeaponIds.MARKSMAN,
		ZeeWeaponIds.LAUNCHER, ZeeWeaponIds.HATCHET, ZeeWeaponIds.MALLET,
	])
	return out


static func _shuffle(items: Array, stream: DotRandomStream) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var held: Variant = items[i]
		items[i] = items[j]
		items[j] = held


func _clear_props() -> void:
	if props == null:
		return

	for player: WoPlayer in players.values():
		if player.grab != null:
			var _dropped := player.grab.drop()

	for prop in props.all_props():
		var _gone := props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

	_thrown.clear()

	for pickup_id: int in pickups.keys():
		pickup_taken.emit(pickup_id, &"")

	pickups.clear()


# --- Weapons -----------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: WoPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.name = "Weapons"
		# SERVER on a server: the role only decides what is DRAWN, and a headless process has
		# no art to draw a view model from.
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.player_ref = DotNodeRef.of_path(player.get_path())
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			DotLog.warn(CHANNEL, "a weapon rig would not set up", {
				"player": String(player.player_id), "why": ready_now.error.message,
			})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	var def := player.weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		var _selected := player.weapons.arsenal.select(def.slot, _tick)

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: WoPlayer) -> void:
	if player.grab != null:
		var _dropped := player.grab.drop()

	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


func _advance_pickups() -> void:
	if pickups.is_empty():
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		for pickup_id: int in pickups.keys():
			var pickup: Dictionary = pickups[pickup_id]

			if player.controller.state.position.distance_to(pickup["at"]) > PICKUP_REACH + 0.7:
				continue

			if arm(player, pickup["weapon"]):
				pickups.erase(pickup_id)
				pickup_taken.emit(pickup_id, player.player_id)
				break


func _advance_weapons() -> void:
	if phase != Phase.FINALE or combat == null:
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching:
			continue

		# Carrying something is both hands: the trigger throws it, and the gun stays down.
		if player.grab != null and player.grab.is_carrying():
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)


## A player's movement command as a weapon command: fire, alt-fire and reload are the
## movement command's three spare buttons; the slot is this game's own input message.
func weapon_command_for(player: WoPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0))
	command.set_button(DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1))
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2))
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- Picking things up and throwing them ----------------------------------------

## Each player's hand: pick up what they are looking at, carry it, throw it on the trigger.
##
## [b]dot-props' gravity gun, one per player, and the server's alone.[/b] A prop is not
## predicted anywhere in this family (two solvers diverge), so neither is carrying one: the
## client presses the key, the server moves the prop, and the prop arrives in a snapshot like
## every other. The grab is an edge — the key's state rides in [WoNetCommand] — so holding it
## is one pick-up rather than a pick-up and a drop every other tick.
func _advance_grabs(delta: float) -> void:
	if phase != Phase.FINALE and phase != Phase.HANDOVER:
		return

	var space := get_world_3d().direct_space_state if get_world_3d() != null else null

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		if player.grab == null:
			player.grab = DotGravGun.new()
			player.grab.spawner = props
			player.grab.wielder = player.player_id
			player.grab.reach = GRAB_REACH
			player.grab.carry_distance = 2.2
			player.grab.punt_impulse = config.throw_impulse

		var pressed := player.wants_grab and not bool(player.get_meta(&"grab_held", false))
		player.set_meta(&"grab_held", player.wants_grab)

		var eyes := player.eye_position()
		var aim := player.aim_direction()

		if pressed:
			if player.grab.is_carrying():
				var _put := player.grab.drop()
			elif space != null:
				var _took := player.grab.pull(space, eyes, aim)

		if not player.grab.is_carrying():
			continue

		player.grab.carry(eyes, aim, delta)

		var pending := player.controller.current_command

		if pending != null and pending.is_pressed(DotFpsCommand.BUTTON_USER_0) and phase == Phase.FINALE:
			var thrown := player.grab.punt(space, eyes, aim)

			if thrown != null:
				_thrown[thrown.instance_id] = {"by": player.player_id, "until": _tick + int(THROWN_SECONDS * tick_rate)}


## A thrown prop that meets somebody hurts them, by its momentum, and knocks them back.
func _watch_thrown() -> void:
	if _thrown.is_empty() or combat == null:
		return

	for instance_id: int in _thrown.keys():
		var entry: Dictionary = _thrown[instance_id]
		var prop := props.get_prop(instance_id)

		if prop == null or not prop.is_alive() or _tick > int(entry["until"]):
			_thrown.erase(instance_id)
			continue

		var body := prop.body()

		if body == null:
			continue

		var speed := body.linear_velocity.length()

		if speed < config.throw_hurt_speed:
			continue

		for id: StringName in players:
			var player: WoPlayer = players[id]

			if player.watching or not player.is_alive() or id == StringName(entry["by"]):
				continue

			var middle := player.controller.state.position + Vector3(0.0, 0.9, 0.0)

			if middle.distance_to(body.global_position) > 1.3:
				continue

			if int(_thrown_hit.get(id, -1000)) > _tick - 20:
				continue

			_thrown_hit[id] = _tick
			var thrower: WoPlayer = players.get(StringName(entry["by"]))
			var damage := DotDamage.make(
				thrower.entity_id if thrower != null else 0, player.entity_id,
				prop.def.mass * speed * config.throw_damage_per_impulse, null
			)
			damage.point = middle
			damage.direction = body.linear_velocity.normalized()
			damage.tick = _tick
			damage.context = {"why": DIED_THROWN}
			var _applied := combat.apply_damage(damage)

			var shove := body.linear_velocity
			shove.y = 0.0
			player.controller.state.velocity += shove.normalized() * minf(speed * 0.6, 12.0) \
				+ Vector3.UP * 4.0
			player.controller.state.mode = DotFpsState.Mode.AIR


func _on_prop_exploded(
	at: Vector3, radius: float, damage_amount: float, force: float, by: StringName
) -> void:
	blast.emit(at, radius)

	# The arena's balls are thrown by it too.
	if authoritative and stage != null and stage.toys != null:
		var _thrown := stage.toys.blast(at, maxf(radius, 2.0), TOY_BLAST_SPEED)

	if combat == null:
		return

	var attacker := 0

	if players.has(by):
		attacker = (players[by] as WoPlayer).entity_id

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		var offset := player.controller.state.position - at
		var distance := offset.length()

		if distance > radius:
			continue

		var falloff := 1.0 - (distance / radius)
		var damage := DotDamage.make(attacker, player.entity_id, damage_amount * falloff, null)
		damage.point = player.controller.state.position
		damage.direction = offset.normalized() if distance > 0.01 else Vector3.UP
		damage.tick = _tick
		damage.context = {"why": DIED_BLAST}
		var _applied := combat.apply_damage(damage)
		player.controller.state.velocity += damage.direction * force * falloff * 0.0035 \
			+ Vector3.UP * falloff * 4.5


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses. The step is still a fixed
## `1 / tick_rate`; a simulation stepped by a frame's delta runs differently on a bad second.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


## Asked once a tick: true while the client's load gate holds the world still. Set only by a
## client; a server and every suite leave it empty, so nothing here waits for a cover that does
## not exist.
var covered: Callable = Callable()


func is_covered() -> bool:
	return covered.is_valid() and bool(covered.call())


func current_tick() -> int:
	return _tick


func _step(delta: float) -> void:
	# [b]Under the client's load cover only the local body moves[/b], and only while the gate
	# settles it onto the floor. The phase clock, the stage, the stand-ins, pickups and combat
	# wait: a countdown that ran, or a fall that was counted, behind the cover would be a race
	# the player never saw.
	if is_covered():
		for id: StringName in players:
			var body: WoPlayer = players[id]
			if body.sampler != null:
				body.simulate(_tick, delta)
		return

	_advance_phase(delta)

	if stage != null:
		stage.pose_at(_tick)

	_drive_bots()

	for id: StringName in players:
		(players[id] as WoPlayer).simulate(_tick, delta)

	_watch_progress()
	_advance_pickups()
	_advance_grabs(delta)
	_watch_thrown()
	_advance_weapons()

	if authoritative:
		_advance_toys(delta)

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


# --- Toys ------------------------------------------------------------------------

## A barrel's blast at its centre, m/s to a toy (dot-props' `blast`).
const TOY_BLAST_SPEED := 12.0


## Everybody against the stage's toys, after they moved: a walk into a ball sends it on, and a
## runner is never slowed by one (people are not on the toys' layer). Then the box's own tick
## (the awake cap, a ball in the water sent home). Server side.
func _advance_toys(delta: float) -> void:
	if stage == null or stage.toys == null or stage.toys.count() == 0:
		return
	for id: StringName in players:
		var player: WoPlayer = players[id]
		if not player.is_alive() or player.watching:
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := stage.toys.push_from(state.position, state.velocity, radius, height)
	stage.toys.advance(delta)


## A finale shot against the toys: the first one on its ray, nearer than the arena, is pushed
## (dot-props' `shot_along`). The shot goes on to the combat, whose trace never sees a toy, so a
## ball is never cover. Server side.
func _shoot_toys(shot: DotShot) -> void:
	if not authoritative or stage == null or stage.toys == null or stage.toys.count() == 0 or physics == null:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := stage.toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world"))


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client being told what the server runs at: this world, every
## player's controller and the stage, or the client walks at the wrong speed and is
## corrected for it on every snapshot.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	if stage != null:
		stage.tick_rate = rate

	for id: StringName in players:
		(players[id] as WoPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


## Falls, checkpoints and the finish: everything about a runner that is the server's to say.
##
## [b]A height comparison, not a trigger volume,[/b] for the fall: something falling fast
## crosses a thin trigger between two ticks without ever being inside it, which is dot-timer's
## own note and mg-smash-copter's floor.
func _watch_progress() -> void:
	if stage == null or stage.doc.is_empty():
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]
		var feet := player.controller.state.position

		# The knock happens inside the player's own tick (see [WoPlayer]); this is where the
		# server notices one happened, for the numbers.
		if player.knocks > int(player.get_meta(&"knocks_seen", 0)):
			player.set_meta(&"knocks_seen", player.knocks)

			if progress != null:
				progress.on_knocked(id)

			# What the knock costs. On the course only, on the authority only: the throw was
			# predicted, the health is decided.
			# Once a second at the most: a ram holding somebody against its stop re-throws them
			# every few ticks, and charged each time it killed a stand-in pinned there in a
			# second — half of a field of eight was knocked out of Punch Alley that way.
			var hurt_since := _tick - int(player.get_meta(&"knock_hurt_tick", -100000))
			if hurt_since >= tick_rate:
				var amount := player.last_knock_speed * config.knock_damage_per_speed
				if player.last_knock_struck:
					amount = maxf(amount, config.strike_damage)
				if _hurt_on_course(
						player, amount, DIED_STRUCK if player.last_knock_struck else DIED_KNOCKED,
						player.last_knock_direction):
					player.set_meta(&"knock_hurt_tick", _tick)

		_watch_landing(player, feet)

		if feet.y < stage.water_height() or stage.in_kill(feet):
			_fell(player)
			continue

		if not stage.is_course() or player.finished or phase != Phase.COURSE:
			continue

		# A teleport pad moves whoever is on it, course in play only. The destination is not on
		# a pad, so nobody is sent twice.
		var sent := stage.teleport_at(feet)

		if not sent.is_empty():
			player.place_at(sent[0] as Vector3, float(sent[1]))

			# A stand-in carries on from the route point nearest where it was sent, not the pad's
			# own point (which is a long way behind it now).
			if player.is_bot:
				_bot_route[player.player_id] = _route_after(sent[0] as Vector3)

			continue

		var crossed := stage.checkpoint_at(feet)

		if crossed > player.checkpoint:
			player.checkpoint = crossed
			checkpoint_reached.emit(id, crossed)
			if config.checkpoint_heals and authoritative and player.health != null:
				var _healed := player.health.heal(player.health.max_health)

		# A covered seat is not counted across: its client cannot see or move, so a carrier
		# that took it over the line would give it a place (and points) it did not race for.
		if stage.in_finish(feet) and can_be_harmed(player.player_id):
			_finish(player)


## Takes [param amount] of a player's health on the course, once the checks every course hit
## shares have passed: the authority, a course in play, health switched on, somebody alive and
## not yet across. The health they had BEFORE rides in the damage's context, because the death
## the blow may cause is decided from it ([method decide_death]). True when it was charged.
func _hurt_on_course(player: WoPlayer, amount: float, why: StringName, direction: Vector3) -> bool:
	if not authoritative or not config.health_enabled or amount <= 0.0 or stage == null \
			or not stage.is_course() or phase != Phase.COURSE or combat == null \
			or player.health == null or not player.is_alive() or player.finished:
		return false

	var hurt := DotDamage.make(0, player.entity_id, amount, null)
	hurt.point = player.controller.state.position
	hurt.direction = direction
	hurt.tick = _tick
	hurt.context = {"why": why, "health_before": player.health.health}
	var _applied := combat.apply_damage(hurt)
	return true


## Hard landings: the height a player fell from before their feet found a deck, past
## [member WoConfig.fall_safe_height], costs [member WoConfig.fall_damage_per_metre] a metre. The peak
## is kept while in the air and forgotten on a fall into the water, which has its own rule.
func _watch_landing(player: WoPlayer, feet: Vector3) -> void:
	if not authoritative or player.controller == null:
		return

	var airborne := player.controller.state.mode != DotFpsState.Mode.GROUND

	if airborne:
		var peak := float(player.get_meta(&"air_peak", feet.y))
		player.set_meta(&"air_peak", maxf(peak, feet.y))
		return

	if not player.has_meta(&"air_peak"):
		return

	var dropped := float(player.get_meta(&"air_peak")) - feet.y
	player.remove_meta(&"air_peak")
	var over := dropped - config.fall_safe_height

	if over > 0.0 and config.fall_damage_per_metre > 0.0 and feet.y >= stage.water_height():
		var _charged := _hurt_on_course(player, over * config.fall_damage_per_metre, DIED_LANDED, Vector3.ZERO)


func _fell(player: WoPlayer) -> void:
	if stage.is_arena():
		if player.watching:
			var spot := stage.gallery_spot(0)
			player.place_at(spot[0], spot[1])
			return

		if player.is_alive() and combat != null:
			var damage := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
			damage.point = player.controller.state.position
			damage.direction = Vector3.DOWN
			damage.tick = _tick
			damage.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(damage)
		return

	# On a course a fall costs time and nothing else: back to the last checkpoint crossed,
	# or the start, or — for somebody already finished — the lounge.
	#
	# A seat still behind its loading cover is put back all the same (it cannot be left under
	# the water), but the fall is not counted and the checkpoint is not lost: it did not
	# choose to be there. The course clock is shared and does not wait for it; a late loader
	# runs the rest of the course against a clock already going, as it always did.
	if not can_be_harmed(player.player_id):
		var home := stage.respawn_point(player.checkpoint, 0)
		player.place_at(home[0], home[1])
		return

	# Instant death: the water is fatal and the round is over for them. Through the damage
	# path, so the body falls, the kill is counted and `_on_player_died` seats them in the lounge.
	if config.instant_death and authoritative and not player.finished and combat != null \
			and player.health != null and player.is_alive():
		player.remove_meta(&"air_peak")
		var lethal := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
		lethal.point = player.controller.state.position
		lethal.direction = Vector3.DOWN
		lethal.tick = _tick
		lethal.context = {"why": DIED_FELL}
		var _killed := combat.apply_damage(lethal)
		return

	player.falls += 1
	player.remove_meta(&"air_peak")

	if player.finished:
		var spot := stage.lounge_spot(player.place)
		player.place_at(spot[0], spot[1])
	else:
		var spot := stage.respawn_point(player.checkpoint, player.falls % 5)
		player.place_at(spot[0], spot[1])

		# [b]Back at the checkpoint healed, as crossing it heals.[/b] A knock that throws you in
		# has already cost the time back to the checkpoint; on the longer courses the health it
		# also cost added up over a dozen restarts, and a field of eight stand-ins was knocked
		# OUT of the round, not just off the course, on every hammer and ram course (two of
		# eight finished Hammer Gauntlet). Knocks along a deck that do not end in the water
		# still add up, so `course_deaths_eliminate` still means something.
		if config.checkpoint_heals and authoritative and player.health != null and player.is_alive():
			var _healed := player.health.heal(player.health.max_health)

	if player.is_bot:
		_bot_route[player.player_id] = _route_after(player.controller.state.position)
		var put_on := int((stage.route()[_bot_route[player.player_id]] as Dictionary).get("branch", 0)) \
			if int(_bot_route[player.player_id]) < stage.route().size() else 0
		if put_on != 0:
			_racer_of(player)["branch"] = put_on
		# Shaking it off: a person back on the deck looks round before running again.
		var racing := _racer_of(player)
		racing["pause_until"] = _tick + int(racer.value("recover") * float(racing["factor"]) * float(tick_rate))
		racing["plan_index"] = -1
		racing["backed_up"] = -1
		racing["backup_until"] = 0

	if progress != null:
		progress.on_fell(player.player_id)

	player_fell.emit(player.player_id, player.checkpoint)


func _finish(player: WoPlayer) -> void:
	_finish_count += 1
	player.finished = true
	player.place = _finish_count
	player.finish_seconds = course_elapsed
	if authoritative:
		var table := config.finish_points
		player.points += table[player.place - 1] if player.place <= table.size() else config.finish_points_rest

	if progress != null:
		progress.on_finished(player.player_id, player.place, course_elapsed)

	player_finished.emit(player.player_id, player.place, course_elapsed)
	DotLog.debug(CHANNEL, "somebody finished", {
		"id": String(player.player_id), "place": player.place, "seconds": "%.2f" % course_elapsed,
	})


# --- Bots -------------------------------------------------------------------

## Whether the run from [param from] through the next [param span] route points meets no hazard,
## timed at a run to a jump point and at a hop's pace from one, early and late by [constant SPAN_SLACK].
func _span_clear(from: Vector3, index: int, span: int) -> bool:
	var route := stage.route()

	if span <= 1 and index + 1 < route.size():
		return stage.path_clear(from, (route[index + 1] as Dictionary)["at"], _tick, config.run_speed)

	for slack in [-SPAN_SLACK, 0.0, SPAN_SLACK]:
		var offset: float = slack
		var here := from

		for i in range(index + 1, mini(index + 1 + span, route.size())):
			var there: Vector3 = (route[i] as Dictionary)["at"]
			var from_jump := i - 1 >= 0 and bool((route[i - 1] as Dictionary)["jump"])
			var speed := SPAN_HOP_SPEED if from_jump else config.run_speed
			var length := Vector2(there.x - here.x, there.z - here.z).length()

			if not stage.path_clear(here, there, _tick + int(maxf(offset, 0.0) * float(tick_rate)), speed / 0.8, 0.0):
				return false

			offset += length / speed
			here = there

	return true


## What a stand-in does. On a course: follow the document's route, jump where it says, and
## sometimes get it wrong. In a final death: get something in its hands and use it.
func _drive_bots() -> void:
	racer.mistakes = config.bot_mistakes

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.is_bot or not player.is_alive():
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		(_racer_of(player)["aim"] as DotBotAim).view_from(command.yaw, command.pitch)

		if player.watching or phase == Phase.IDLE or phase == Phase.COUNTDOWN:
			pass
		elif stage.is_course() and not player.finished:
			_bot_run(player, command)
		elif phase == Phase.FINALE:
			_bot_fight(player, command)

		player.controller.apply_command(command)


## How [param player], a stand-in, is racing this round; made on first use.
##
## `factor` is this bot's own share of the preset's mistakes, drawn once per bot and round
## (so eight medium bots are eight different runners, and a different eight next round);
## `plan_*` is what it will get wrong at the route point it is heading for, drawn once per
## point and ATTEMPT (`falls`), never once per point and round: a jump fumbled on every
## attempt was a bot that never got past it.
func _racer_of(player: WoPlayer) -> Dictionary:
	var held: Variant = _bot_racer.get(player.player_id)

	if held != null:
		return held

	var draw := random.stream_for(&"bot_skill", round_number * 8192 + int(player.entity_id % 8192))
	var racing := {
		"factor": WoRacer.factor(racer.value("variety"), draw.next_range_f(-1.0, 1.0)),
		"plan_index": -1,
		"plan_falls": -1,
		"fumble": false,
		"late": 0,
		"early": 0.0,
		"rash": false,
		"window": -1,
		"pause_until": 0,
		"aim": DotBotAim.new(int(player.entity_id), DotBotSettings.of(self)),
	}
	_bot_racer[player.player_id] = racing
	return racing


## A draw in [0, 1) for one decision of one stand-in: seeded from the round, the bot and
## [param salt], so a replayed round makes the same mistakes and two bots make different ones.
func _bot_roll(name: StringName, player: WoPlayer, salt: int) -> float:
	var subject := (round_number * 4099 + int(player.entity_id % 4096)) * 65536 + (salt & 0xffff)
	return random.stream_for(name, subject).next_range_f(0.0, 1.0)


## What this stand-in will get wrong at route point [param index]: decided once per point and
## attempt. A jump not taken, a take-off early or late, a window not waited for.
func _bot_plan(player: WoPlayer, racing: Dictionary, index: int) -> void:
	if int(racing["plan_index"]) == index and int(racing["plan_falls"]) == player.falls:
		return

	var factor := float(racing["factor"])
	var salt := index * 64 + player.falls
	racing["plan_index"] = index
	racing["plan_falls"] = player.falls
	racing["fumble"] = _bot_roll(&"bot_fumble", player, salt) * 100.0 < racer.value("fumble") * factor
	racing["rash"] = _bot_roll(&"bot_rash", player, salt) * 100.0 < racer.value("rash") * factor
	# Early or late by up to `timing` seconds, evenly: early is a jump taken that much further
	# back (shorter, still made over most gaps), late is that much more run before it — and
	# past an edge point half a metre from the edge, a late take-off is a step into the water.
	var off := (_bot_roll(&"bot_timing", player, salt) * 2.0 - 1.0) * racer.value("timing") * factor
	# A third of it off a TOP (a ball, a log, a pad: a point with a wide reach), where the
	# take-off is wherever the landing put you and a person jumps the moment they are on it.
	# At the full error eight medium stand-ins fell off First Splash's three balls on six
	# attempts in ten: a ball is under a metre of top, and a quarter-metre early is short.
	var route := stage.route()
	if index < route.size() and float((route[index] as Dictionary)["reach"]) > 0.6:
		off *= 0.35
	racing["late"] = int(maxf(off, 0.0) * float(tick_rate))
	racing["late_going"] = false
	racing["queued"] = 0
	racing["early"] = maxf(-off, 0.0) * config.run_speed
	racing["window"] = -1


func _bot_run(player: WoPlayer, command: DotFpsCommand) -> void:
	var route := stage.route()

	if route.is_empty():
		return

	var racing := _racer_of(player)

	# Back on the deck after a fall, and not running yet.
	if _tick < int(racing["pause_until"]):
		command.move = Vector2.ZERO
		return

	var index := mini(int(_bot_route.get(player.player_id, 0)), route.size() - 1)
	var point: Dictionary = route[index]
	var next_index := _bot_next(player, racing, index)
	var next: Dictionary = route[next_index] if next_index < route.size() else {}
	var before_index := stage.route_prev(index, int(racing.get("branch", 0)))
	var before: Vector3 = (route[before_index] as Dictionary)["at"] if before_index >= 0 else player.controller.state.position

	# Fallen onto an earlier part of the course (a leg below this one, a turn back): the point
	# being run for is overhead, so start again from the nearest point. Only well back along
	# the route and well below: on a climb the next point is above the runner too, and a
	# nearest point one back is just the one passed.
	if int(_tick + player.entity_id) % 32 == 0 and player.controller.state.mode == DotFpsState.Mode.GROUND \
			and (point["at"] as Vector3).y - player.controller.state.position.y > 2.0:
		var nearest := _route_after(player.controller.state.position, int(racing.get("branch", 0)))
		if nearest < index - 1:
			_bot_route[player.player_id] = nearest
			return

	var at := player.controller.state.position
	var grounded := player.controller.state.mode == DotFpsState.Mode.GROUND
	var ground_id := player.controller.state.ground_id
	# On a tile of a grid of trapdoors (not merely near one): see [method _bot_tile_column].
	var on_tile := grounded and not stage.tile_under(ground_id).is_empty()

	# A column of tiles claimed for this grid, not the middle one (see [method _bot_tile_column]).
	if bool(point["board"]) and not bool(point["ride"]):
		var shift := _bot_tile_column(player, racing, point, on_tile)
		if shift != Vector3.ZERO:
			point = point.duplicate()
			point["at"] = (point["at"] as Vector3) + shift

	var toward: Vector3 = (point["at"] as Vector3) - at
	toward.y = 0.0
	_bot_plan(player, racing, index)

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	# In the air, aimed at a top to land on: brake if the jump is going to carry past it.
	# Something to board too: a run at a row of tiles jumped at the deck's edge carried a
	# runner two rows past the first one, onto a tile on its way down (Trapdoor Run).
	if not grounded and (bool(point["jump"]) or bool(point.get("bounce", false)) or bool(point["board"])):
		_bot_land_on(player, command, point["at"], (point["at"] as Vector3) - before, float(point["reach"]) > 0.6)
	elif not grounded and before_index >= 0 and _bot_save_landing(player, command, point["at"],
			(point["at"] as Vector3) - before):
		return

	# A bouncer is ground for one tick: its point is reached by coming down over it, and the
	# bounce itself carries the runner on toward the next. Measured on First Splash's pads:
	# held to "on the ground within reach", a stand-in braked onto the first pad for ever.
	# Or over it and past it, on the way up off the pad: a bounce that came down a metre and a
	# half past the middle of the last pad went on braking back toward that middle, short of
	# the deck after it (Grand Tour, every runner who took that bounce long).
	var over_it := toward.length() < 2.5 and toward.dot((point["at"] as Vector3) - before) < 0.0
	if bool(point.get("bounce", false)) and (toward.length() < float(point["reach"]) or over_it) \
			and player.controller.state.velocity.y > 0.0 and not grounded:
		_bot_route[player.player_id] = next_index
		return

	# A point ON something that moves is reached by standing on it, wherever it has got to:
	# chasing the coordinates the mover started from walked the bot backwards off its tail.
	if bool(point["ride"]) and grounded and stage.carries(player.controller.state.ground_id):
		_bot_wait.erase(player.player_id)
		_bot_route[player.player_id] = next_index
		command.move = Vector2.ZERO
		return

	# Something to land on: nothing is started until it will be there. Asked every tick, so
	# a bot riding a mover stays on it, carried, until the far side is in reach.
	if bool(point["board"]) and grounded:
		var waited := int(_bot_wait.get(player.player_id, 0))

		# Six seconds at the most: a window that never comes is a course to fix, and a bot
		# standing still for ever would hide that rather than show it.
		var cell := stage.tile_cell(point["at"])
		var line: Vector3 = (point["at"] as Vector3) - before
		var from_deck := not cell.is_empty() and not on_tile
		# [b]Lined up on its column before it goes, from a deck.[/b] Slantwise, the walk's
		# jump came down short of the first row: the gap is crossed on the slant.
		var across := stage.tile_column_shift(int(cell["piece"]), at, int(racing.get("tile_col", int(cell["col"])))) \
			if from_deck else Vector3.ZERO
		var may := across.length() <= TILE_LINED_UP and _bot_may_board(player, point, line)

		# Rash (`wo_bot_rash`, drawn per point and attempt): off the deck onto the tiles
		# without waiting for the column to be clear, as a window is not waited for.
		if from_deck and not may and across.length() <= TILE_LINED_UP and bool(racing["rash"]) \
				and stage.supported(point["at"], _tick):
			may = true

		if waited < tick_rate * (6 if int(point["span"]) <= 1 else 24) and not may:
			# [b]Another column, from the deck only, once its own has kept it waiting.[/b] A
			# person watches the column in front and takes the next one if it opens first,
			# timed from where they will be once they have stepped across to it; never
			# across a row once on the tiles, which is walking over tiles as they drop (a
			# field that did it fell half as often again).
			if from_deck and waited >= int(TILE_PATIENCE * float(tick_rate)):
				var piece := int(cell["piece"])
				var original: Vector3 = (route[index] as Dictionary)["at"]
				var walk := config.run_speed * config.walk_speed_scale
				var claims := _tile_claims(player, piece)
				var own := int(racing.get("tile_col", -1))
				var crowded := waited >= int(TILE_PATIENCE * 2.0 * float(tick_rate))
				for col in range(claims.size()):
					# Not into a column more of the field has claimed, until it has waited
					# twice as long: a field that took whichever column opened first all
					# crossed in one.
					if col == own or (not crowded and own >= 0 and claims[col] > claims[own]):
						continue
					var step_across := stage.tile_column_shift(piece, at, col)
					var later := _tick + int((step_across.length() / walk + TILE_START_SECONDS) * float(tick_rate))
					var there := original + stage.tile_column_shift(piece, original, col)
					if stage.tile_crossing_clear(at + step_across, there, later, walk, config.run_speed,
							TILE_START_SECONDS, line):
						racing["tile_col"] = col
						point = point.duplicate()
						point["at"] = there
						across = step_across
						break

			# Standing on a tile that is going, anywhere is better than down with it, but only
			# if the next one is there: the warning is on for the last 0.6 s a tile is up, and
			# a crossing may leave in it; going on the warning alone walked into a dropped tile.
			if not (stage.tile_dropping(ground_id, at, _tick) and stage.supported(point["at"], _tick)):
				_bot_wait[player.player_id] = waited + 1
				command.move = Vector2.ZERO
				# Waiting on the deck, far enough back from the edge to be walking when it
				# jumps (one that stopped where the edge jump fires jumped from a standstill
				# when it went, into the gap before the first row: Trapdoor Run's last grid),
				# and lined up on its column.
				if from_deck:
					var forward := line.normalized() if line.length() > 0.05 else Vector3.ZERO
					forward.y = 0.0
					if not stage.supported(at + forward * 1.3 + Vector3(0.0, 0.1, 0.0), _tick):
						command.yaw = rad_to_deg(atan2(-forward.x, -forward.z))
						command.move = Vector2(0.0, -1.0)
						command.set_button(DotFpsCommand.BUTTON_WALK, true)
					elif across.length() > TILE_LINED_UP * 0.5:
						command.yaw = rad_to_deg(atan2(-across.x, -across.z))
						command.move = Vector2(0.0, 1.0)
						command.set_button(DotFpsCommand.BUTTON_WALK, true)
				return

	# Walked into, for its last metre and a half, a point the bot may have to stop at: one that
	# arrived at a run and then stopped slid a metre past it, which beside a mover is off the
	# edge. Not further out: a bot walking the last two and a half metres walked through the
	# ram it had timed its window for at a run.
	# Never on the tiles, where the next row is run onto, not stopped for (see [method _bot_may_board]).
	var stops := bool(point["wait"]) or (not next.is_empty() and bool(next["board"]) and not on_tile)

	# Only on the way IN: a bot let go from a wait point timed its window at a run, and one
	# that walked through it arrived late and was hit — every pusher on Punch Alley, every time.
	if bool(point["walk"]) or (stops and toward.length() < 1.6 and toward.length() > float(point["reach"])):
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	# Onto a tile, at a walk: a running jump is nearly five metres and a row of tiles is two,
	# and a stand-in that ran at the first row landed on the third (Trapdoor Run). Once on
	# them, at a run: walked, a crossing took three seconds, long enough for every tile in
	# the column to drop once.
	if bool(point["board"]) and not bool(point["ride"]) and not on_tile \
			and not stage.tile_columns(point["at"]).is_empty():
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	# Two seconds at the most behind anybody: whoever is in front may be stuck themselves, and a
	# queue behind a runner who never goes is a stand-in that never finishes (a lab run of logs
	# had one standing at the edge for the whole clock).
	if bool(point["jump"]) and toward.length() < 4.0 and int(racing.get("queued", 0)) < tick_rate * 2 \
			and _bot_queue(player, command, point["at"]):
		racing["queued"] = int(racing.get("queued", 0)) + 1
		return

	var running := command.move != Vector2.ZERO
	# Landed on a top, the yaw is still at its point, behind the runner: the hop looks the way the run will go.
	var hop_yaw := NAN
	if bool(point["jump"]) and float(point["reach"]) > 0.6 and grounded and not next.is_empty() and toward.length() < 1.5:
		var onward := (next["at"] as Vector3) - at
		hop_yaw = rad_to_deg(atan2(-onward.x, -onward.z))
	_bot_hop(player, command, hop_yaw)

	# [b]Stopped to let an arm go by, it does not take off.[/b] The hop stops a runner whose
	# landing the arm would be on, and the take-off below then jumped anyway, from a tick of
	# braking with no wish: off the sweeper's far edge at a metre and a half a second, into
	# the gap (Spin Cycle, most of every preset's falls there).
	if running and command.move == Vector2.ZERO and bool(point["jump"]):
		return

	# [b]A hop that carries past the jump point ahead is the jump.[/b] An arm on the piece
	# across a gap is hopped from the deck before it, short of the edge's jump point; aimed in
	# the air at that point, behind it by then, the runner braked to come down on the deck and
	# came down in the gap. Spin Cycle's falls by the spinner's turntable and off the far
	# edges of the sweeper and the spinner deck were these, and nightmare, which misses the
	# fewest hops, fell there most and finished behind hard. So the route moves on with it,
	# and the landing is steered onto what is beyond the gap, when the hop reaches it: one that
	# comes down in the gap is braked back onto this side, as before (a hop off the sweeper's
	# deck at five metres a second, taken as the jump, fell a metre short of the next).
	if grounded and command.is_pressed(DotFpsCommand.BUTTON_JUMP) and bool(point["jump"]) \
			and float(point["reach"]) <= 0.6 and not next.is_empty():
		var airtime := 2.0 * sqrt(2.0 * config.gravity * config.jump_height) / config.gravity
		var flat := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
		if flat.length() * airtime > toward.length() and stage.supported(at + flat * airtime + Vector3(0.0, 0.1, 0.0),
				_tick + int(airtime * float(tick_rate))):
			_bot_route[player.player_id] = next_index
			return

	_bot_unstick(player, command)

	# Heading for something to land on, the jump is at whatever edge the bot reaches first,
	# which on a moving floor is nowhere a route point could name. A gap a stride crosses is
	# stepped, not jumped: a running jump is nearly five metres, and jumping the thirty
	# centimetres between a deck and a mover beside it carried the bot clean over the mover.
	if bool(point["board"]) and grounded:
		var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))
		# From a deck onto tiles, the jump is put off until the runner is nearly at the edge:
		# a jump taken at a walk is two metres, and fired the usual metre back it came down in
		# the gap before the first row (Trapdoor Run's last grid, a mistake-free field).
		var lead := 0.35 if not on_tile and not stage.tile_cell(point["at"]).is_empty() else 0.7
		var ahead := at + heading * lead + Vector3(0.0, 0.1, 0.0)

		# [b]Tile to tile is a step, never a jump.[/b] The gap between two rows is a stride;
		# what made the edge jump fire there was the tile ahead being DOWN, and a jump at a
		# walk over a dropped tile came down in the hole it left. A tile ahead that is down is
		# waited for, unless the one underfoot is going too.
		if on_tile and not stage.tile_cell(ahead).is_empty():
			if not stage.supported(ahead, _tick) and not stage.tile_dropping(ground_id, at, _tick):
				command.move = Vector2.ZERO
		elif not stage.supported(ahead, _tick) \
				and not stage.supported(at + heading * 1.6 + Vector3(0.0, 0.1, 0.0), _tick):
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

	# Backing up for a run-up (see the jump below), wherever that takes it, straight back along
	# the line the jump will take.
	if _tick < int(racing.get("backup_until", 0)) and grounded:
		if not next.is_empty():
			var line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
			line.y = 0.0
			if line.length() > 0.01:
				command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.move = Vector2(0.0, -1.0)
		return

	# A late take-off under way: running on the way it was going (past the point, which would
	# otherwise turn it round), then the jump, whether or not there is still ground under it.
	if bool(racing.get("late_going", false)):
		command.yaw = float(racing["late_yaw"])
		command.move = Vector2(0.0, 1.0)
		if int(racing["late"]) > 0:
			racing["late"] = int(racing["late"]) - 1
			racing["late_going"] = true
			racing["late_yaw"] = command.yaw
			return
		racing["late_going"] = false
		if grounded and not bool(racing["fumble"]):
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		_bot_route[player.player_id] = next_index
		return

	# An early take-off is a jump point reached further back than it is.
	var reach := float(point["reach"]) + (float(racing["early"]) if bool(point["jump"]) else 0.0)

	# [b]A top landed on past its point is reached.[/b] Landing a little past is the aim (see
	# [method _bot_land_on]); a runner seven tenths of a metre past a pad's point, outside its
	# reach, turned round, ran back at it, and jumped for the next pad from a run the wrong
	# way, into the pond.
	if bool(point["jump"]) and float(point["reach"]) > 0.6 and grounded and not next.is_empty():
		var line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
		line.y = 0.0
		if line.length() > 0.01 and -toward.dot(line.normalized()) > 0.0 and toward.length() < 2.2:
			reach = maxf(reach, toward.length() + 0.01)

	# [b]Somebody is on the top the jump from here lands on: wait for them to go on[/b], two
	# seconds at the most, a couple of metres back from the edge so there is a run at it when
	# it comes free. Eight stand-ins jumped onto one lily pad together and knocked each other
	# into the pond; a runner who waited AT the edge had no run left and jumped short (Trapdoor
	# Run's pads, a field going round and round for the whole clock). Only from an edge:
	# standing still on a top is losing the speed the next jump needs.
	if bool(point["jump"]) and float(point["reach"]) <= 0.6 and grounded and toward.length() < 3.0 \
			and not next.is_empty() and _top_taken(player, next):
		var held := int(racing.get("held", 0))
		if held < tick_rate * 2:
			racing["held"] = held + 1
			command.move = Vector2(0.0, -0.7) if toward.length() < 2.0 else Vector2.ZERO
			return
	elif bool(point["jump"]):
		racing["held"] = 0

	if toward.length() > reach:
		return

	if bool(point["wait"]) and not next.is_empty() and not bool(racing["rash"]):
		var waited := int(_bot_wait.get(player.player_id, 0))

		# [b]The window is SEEN, and then gone for, a reaction later[/b] (dot-bot's
		# `bot_reaction`): a person does not set off on the tick a ram starts home, and one
		# who reacts slowly goes into a window as it closes. Committed once seen, so a slow
		# reaction is a late start, never a second wait.
		if int(racing["window"]) < 0 and waited < tick_rate * (6 if int(point["span"]) <= 1 else 24) \
				and not _span_clear(at, index, int(point["span"])):
			_bot_wait[player.player_id] = waited + 1
			command.move = Vector2.ZERO
			command.set_button(DotFpsCommand.BUTTON_JUMP, false)
			return

		if int(racing["window"]) < 0:
			racing["window"] = _tick

		var react := int(racer.reaction() * float(racing["factor"]) * float(tick_rate))

		if _tick - int(racing["window"]) < react:
			command.move = Vector2.ZERO
			command.set_button(DotFpsCommand.BUTTON_JUMP, false)
			return

	_bot_wait.erase(player.player_id)

	# Nor is something to board passed in the air: passing over the first row of tiles in the
	# jump onto it made the second row the target, and the landing was braked onto that one
	# instead, as it dropped.
	if bool(point["board"]) and not grounded:
		return

	# A jump point passed in the air is not passed: it is where the NEXT jump starts, and
	# advancing on it mid-flight meant the bot came down on a ball, never jumped off it and
	# slid into the water. Held until the bot is on its feet.
	if bool(point["jump"]):
		if not grounded:
			racing["grounded_for"] = 0
			return

		# [b]Not on the tick of landing.[/b] Until the world has stepped once with the feet
		# down, the velocity is still the jump's: seven metres a second, so the run-up below
		# let the next jump go at once, and the landing on the ball's curve had already taken
		# it to four. Every second ball, short.
		racing["grounded_for"] = int(racing.get("grounded_for", 0)) + 1
		if int(racing["grounded_for"]) < 2 and float(point["reach"]) > 0.6:
			return

		# [b]On a top, face the next one, never the point.[/b] A landing is aimed a little past
		# a top's point (see [method _bot_land_on]), so the point is behind the runner and
		# turning to it is running backwards: on a log that took the take-off from five metres
		# a second to two, and the jump went into the water between two logs (Log Roll, a
		# mistake-free field falling three times a run). Past the point and too slow for the
		# jump, the yaw is left to the run-up below, which turns to the next top itself.
		if float(point["reach"]) > 0.6 and not next.is_empty():
			var facing: Vector3 = (next["at"] as Vector3) - at
			facing.y = 0.0
			var beyond := -toward.dot(facing.normalized()) if facing.length() > 0.1 else 0.0
			var flat_now := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
			var going := flat_now.dot(facing.normalized()) if facing.length() > 0.1 else 0.0
			var need := _jump_speed_needed(at, next["at"])
			if facing.length() > 0.1 and (beyond < 0.2 or going >= need):
				command.yaw = rad_to_deg(atan2(-facing.x, -facing.z))
			# Faster than the jump needs: the excess braked off on the take-off, never a wish
			# on to full speed. A jump off a log at seven metres a second was braked in the air
			# to a standstill just past the next log's top, and the run-up from there went down
			# its far side, where the motor refuses a jump (First Splash's second log, easy
			# stand-ins wedged there twenty times in four rounds). Never on a log turning toward
			# the runner, which takes the speed a jump needs: braked there too, a mistake-free
			# field fell on Log Roll.
			if going >= need * TAKEOFF_SPARE and facing.length() > 0.1 \
					and stage.carry(player.controller.state.ground_id, at, _tick).dot(facing) >= 0.0:
				command.move = Vector2(0.0, -clampf((going - need * TAKEOFF_SPARE) / GROUND_BRAKE, 0.0, 1.0))
		elif not next.is_empty():
			# [b]An edge's jump point already behind: the jump goes on, not back.[/b] A hop
			# on the sweeper came down a few centimetres past the point, the yaw was still
			# at the point, and the take-off went backwards at a metre and a half a second
			# into the gap ahead (Spin Cycle, most of every preset's falls there). Only once
			# past it and still going on: before the point the run-up is left straight, as it
			# always was, and turned for a runner going back, The Sweeper's easy field fell
			# more and finished behind medium.
			var jump_line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
			jump_line.y = 0.0
			var onward := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).dot(jump_line)
			if jump_line.length() > 0.1 and toward.dot(jump_line) < 0.0 and onward > 0.0:
				command.yaw = rad_to_deg(atan2(-jump_line.x, -jump_line.z))

		# [b]Toward where the jump is GOING, on a point marked `onward`.[/b] A bot that
		# landed half a metre past a lily pad's centre was still facing that centre, behind
		# it, and hopped backwards and wide into the water every time. Opt-in per point,
		# because doing it everywhere broke four courses that passed: a gap's edge point is
		# routinely passed before the take-off, and turning there spoils a straight run-up.
		# Before the run-up below, which on a pad would otherwise run back at the point too.
		if bool(point.get("onward", false)) and not next.is_empty():
			var onward: Vector3 = (next["at"] as Vector3) - at
			onward.y = 0.0
			if onward.length() > 0.1:
				command.yaw = rad_to_deg(atan2(-onward.x, -onward.z))

		# Up to speed first, for a few ticks: a landing on a ball or a turning log costs speed,
		# and a jump taken at four metres a second off a log falls short of the next one — a
		# jump is cut short in the air, never stretched.
		var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
		var spent := int(_bot_runup.get(player.player_id, 0))

		# Longer on a top that fights back: a log rolling toward the runner took the landing
		# down to one and a half metres a second, and three ticks of running on it was still
		# under two when the jump went, a metre short (Log Roll, every other log). Never once
		# past the point, though, where the top is going away under the feet.
		var onward_line := (next["at"] as Vector3) - (point["at"] as Vector3) if not next.is_empty() else Vector3.ZERO
		onward_line.y = 0.0
		var past := -toward.dot(onward_line.normalized()) if onward_line.length() > 0.01 else 0.0
		var top := float(point["reach"]) > 0.6

		if top and not next.is_empty():
			# [b]On a top, run until the jump will make the next one, or the top runs out.[/b]
			# What the next jump needs is arithmetic (the distance over the time a jump is in
			# the air, to the next top's height); what the top allows is its reach past the
			# point. A fixed three ticks of run-up jumped at whatever the landing left, and a
			# pad landing at four metres a second went into the pond every time.
			var needed := _jump_speed_needed(at, next["at"])
			# The speed TOWARD the next top: a runner going sideways at six metres a second
			# is not going to make it.
			var to_next: Vector3 = (next["at"] as Vector3) - at
			to_next.y = 0.0
			var closing := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).dot(to_next.normalized()) \
				if to_next.length() > 0.01 else flat_speed
			# And not much sideways: a pad landed on a metre and a half off its middle had the
			# runner going across it, and the jump went across too (Spin Cycle's second pad).
			var across := 0.0
			if to_next.length() > 0.01:
				var flat_velocity := Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z)
				across = (flat_velocity - to_next.normalized() * closing).length()
			if (closing < needed * 1.05 or across > 1.5) and past < float(point["reach"]) + 0.6 and spent < RUNUP_TICKS * 3:
				_bot_runup[player.player_id] = spent + 1
				var ahead: Vector3 = (next["at"] as Vector3) - at
				ahead.y = 0.0
				if ahead.length() > 0.1:
					command.yaw = rad_to_deg(atan2(-ahead.x, -ahead.z))
				return
		elif flat_speed < config.run_speed * 0.85 and spent < 3:
			_bot_runup[player.player_id] = spent + 1
			return

		_bot_runup.erase(player.player_id)

		# [b]Too slow at an edge, back up for a run at it.[/b] A runner put back at a
		# checkpoint a metre from a gap took off at under three metres a second and fell short
		# every time; a person takes three steps back. Only at an edge (a narrow reach), never
		# on a top, where stepping back is stepping off.
		# Or going the wrong way: a runner who hopped an arm and came down beside an edge ran
		# back along it to the jump point and jumped sideways off it.
		var squint := 0.0
		if not next.is_empty() and flat_speed > 0.5:
			var jump_line: Vector3 = (next["at"] as Vector3) - (point["at"] as Vector3)
			jump_line.y = 0.0
			if jump_line.length() > 0.01:
				squint = rad_to_deg(Vector3(player.controller.state.velocity.x, 0.0, player.controller.state.velocity.z).angle_to(jump_line))
		# Never on a turntable: the disc carries the runner sideways, which reads as a squint,
		# and backing up under a spinner's arms is standing in their way (Spin Cycle's last two
		# discs: hard stand-ins knocked in at the far edge). A seesaw still wants the run-up:
		# without it the next plank was jumped short (Log Roll, a third more falls).
		if (flat_speed < config.run_speed * 0.6 or squint > 30.0) and float(point["reach"]) <= 0.6 \
				and int(racing.get("backed_up", -1)) != index \
				and stage.ground_kind(player.controller.state.ground_id) != "turntable":
			racing["backed_up"] = index
			racing["backup_until"] = _tick + int(0.4 * float(tick_rate))

		if _tick < int(racing.get("backup_until", 0)):
			command.move = Vector2(0.0, -1.0)
			return

		# Late: still running, for as many ticks as this take-off is late by. Off an edge
		# point that is a step past the edge, and the water.
		if int(racing["late"]) > 0:
			racing["late"] = int(racing["late"]) - 1
			return

		# A fumble is a jump not taken, decided once per bot, point and attempt.
		if not bool(racing["fumble"]):
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)


	_bot_route[player.player_id] = next_index


## Whether somebody else is on, or coming down on, the top at route point [param point]: a
## point a jump lands on (`jump` or `bounce` with a reach of a top), with a body within 1.5 m of
## it across and not far above or below.
func _top_taken(player: WoPlayer, point: Dictionary) -> bool:
	if not (bool(point["jump"]) or bool(point.get("bounce", false))) or float(point["reach"]) <= 0.6:
		return false

	if not body_rules.solid:
		return false

	var at: Vector3 = point["at"]

	for id: StringName in players:
		var other: WoPlayer = players[id]

		# Stand-ins pass through each other (see [method _apply_body_mask]): only a person in
		# the way is in the way.
		if other == player or other.is_bot or not other.is_alive() or other.watching or other.finished:
			continue

		var there := other.controller.state.position
		var across := Vector2(there.x - at.x, there.z - at.z).length()

		if across < 1.5 and absf(there.y - at.y) < 2.5:
			return true

		# Coming down on it: in the air within a jump of it and moving toward it.
		var velocity := other.controller.state.velocity
		var toward_top := Vector2(at.x - there.x, at.z - there.z)
		if other.controller.state.mode != DotFpsState.Mode.GROUND and across < 5.0 \
				and Vector2(velocity.x, velocity.z).dot(toward_top) > 0.0:
			return true

	return false


## The flat speed a jump from [param from] needs to come down on [param to] (a little short of
## it is enough: a top has a reach). From the configuration's jump height and gravity.
func _jump_speed_needed(from: Vector3, to: Vector3) -> float:
	var g := config.gravity
	var up := sqrt(2.0 * g * config.jump_height)
	var rise := to.y - from.y
	var root := up * up - 2.0 * g * rise
	if root <= 0.0:
		return INF
	var airtime := (up + sqrt(root)) / g
	var distance := maxf(Vector2(to.x - from.x, to.z - from.z).length() - 0.2, 0.0)
	return distance / maxf(airtime, 0.05)


## How far past a top's point a stand-in aims to land, metres. See [method _bot_land_on].
const LAND_PAST := 0.3

## Ticks a stand-in may spend getting up to speed on a top before it jumps off it anyway.
const RUNUP_TICKS := 9

## A stand-in on a top going faster than this many times the next jump's need brakes the
## excess on the take-off tick (see [method _bot_run]). At 1.15 a mistake-free field fell on
## Log Roll's logs.
const TAKEOFF_SPARE := 1.3

## Metres a second a full backward wish takes off a runner on the ground in one tick.
const GROUND_BRAKE := 3.3

## Seconds a stand-in standing still may take to get going, reckoned onto the latest it is on
## each tile of a crossing (`WoCourse.tile_crossing_clear`).
const TILE_START_SECONDS := 0.1

## How much of the crossing's slow speed and margin a stand-in already on the tiles allows
## for. With all of it, a runner who set off on a clear crossing found it not clear any more
## from the first row (it lands at a walk, off the model) and stood there until the tile went.
const TILE_ON_SLACK := 0.4

## Metres off its column's middle a stand-in on a deck counts as lined up on it.
const TILE_LINED_UP := 0.3

## Seconds a stand-in waits on the deck for its own column of tiles before it takes another
## whose crossing is clear and no more of the field has claimed; after twice this, any.
const TILE_PATIENCE := 1.5


## The offset that moves [param point], a route point on a grid of tiles, onto the column this
## stand-in crosses it in; zero for a point on no tiles.
##
## [b]A field spread across the columns, each down its own.[/b] Stand-ins pass through each
## other, so a field waiting at a grid stood on one tile and went down with it. On the deck
## a stand-in claims, among the columns that can be crossed at all, the one fewest others on
## the grid have claimed (the nearest of those); once on the tiles its column is the one
## under its feet, wherever the jump put it, never one it would have to walk across a row to
## reach.
func _bot_tile_column(player: WoPlayer, racing: Dictionary, point: Dictionary, on_tile: bool) -> Vector3:
	var at: Vector3 = point["at"]
	var cell := stage.tile_cell(at)

	if cell.is_empty():
		return Vector3.ZERO

	var piece := int(cell["piece"])

	if on_tile:
		var under := stage.tile_under(player.controller.state.ground_id)
		if int(under["piece"]) == piece:
			racing["tile_piece"] = piece
			racing["tile_col"] = int(under["col"])
			racing["tile_falls"] = player.falls
	elif int(racing.get("tile_piece", -1)) != piece or int(racing.get("tile_falls", -1)) != player.falls:
		var cols := int((stage.pieces[piece]["spec"] as Dictionary)["cols"])
		var claims := _tile_claims(player, piece)

		# Among the columns that can be crossed at all (see `WoCourse.tile_column_crossable`).
		var here := player.controller.state.position
		var walk := config.run_speed * config.walk_speed_scale
		var line := _tile_line(at)
		var best := -1
		for col in range(cols):
			if not stage.tile_column_crossable(piece, col, here, at, walk, config.run_speed, TILE_START_SECONDS, line):
				continue
			if best < 0 or claims[col] < claims[best] or (claims[col] == claims[best] \
					and stage.tile_column_shift(piece, here, col).length() < stage.tile_column_shift(piece, here, best).length()):
				best = col
		if best < 0:
			best = int(cell["col"])

		racing["tile_piece"] = piece
		racing["tile_col"] = best
		racing["tile_falls"] = player.falls

	return stage.tile_column_shift(piece, at, int(racing["tile_col"]))


## How many other stand-ins have claimed each column of the grid of tiles [param piece] and
## are still on their way over it.
func _tile_claims(player: WoPlayer, piece: int) -> Array[int]:
	var claims: Array[int] = []
	claims.resize(int((stage.pieces[piece]["spec"] as Dictionary)["cols"]))
	claims.fill(0)
	var route := stage.route()

	for id: StringName in _bot_racer:
		var other: Dictionary = _bot_racer[id]
		var them: WoPlayer = players.get(id)
		if them == null or them == player or int(other.get("tile_piece", -1)) != piece \
				or int(other.get("tile_falls", -1)) != them.falls:
			continue
		var their_index := mini(int(_bot_route.get(id, 0)), route.size() - 1)
		var their_cell := stage.tile_cell((route[their_index] as Dictionary)["at"])
		if not their_cell.is_empty() and int(their_cell["piece"]) == piece:
			claims[int(other.get("tile_col", 0))] += 1

	return claims


## The way the route runs at the route point nearest [param at] (from the point before it).
func _tile_line(at: Vector3) -> Vector3:
	var route := stage.route()
	var nearest := 0
	for i in range(route.size()):
		if ((route[i] as Dictionary)["at"] as Vector3).distance_to(at) < ((route[nearest] as Dictionary)["at"] as Vector3).distance_to(at):
			nearest = i
	var before := stage.route_prev(nearest, 0)
	return ((route[nearest] as Dictionary)["at"] as Vector3) - ((route[before] as Dictionary)["at"] as Vector3) if before >= 0 else Vector3.ZERO


## Stops behind somebody standing (or nearly) right in front: a queue, the way people wait at
## the edge before a run of tops. True when it stopped.
##
## [b]Eight stand-ins at one edge pushed each other into the water.[/b] With `mp_solidplayers`
## a runner arriving behind one who waits for a top slid round them and ran off the edge
## beside them: on a lab run of five balls a field of eight fell at the deck's edge eighteen
## times. Slowing to a walk behind them instead was worse (a walk is no run-up for a jump),
## so this stops, and only behind somebody who is not running away (under 3 m/s).
##
## Only near a jump point, and only behind somebody nearer it, so a queue is an order and never
## a ring: the first version stopped every runner on the start pad behind every other, and
## nobody ever left it.
func _bot_queue(player: WoPlayer, command: DotFpsCommand, jump_at: Vector3) -> bool:
	if player.controller.state.mode != DotFpsState.Mode.GROUND or command.move == Vector2.ZERO \
			or not body_rules.solid:
		return false

	var at := player.controller.state.position
	var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))
	var mine := Vector2(jump_at.x - at.x, jump_at.z - at.z).length()

	for id: StringName in players:
		var other: WoPlayer = players[id]

		if other == player or other.is_bot or not other.is_alive() or other.watching or other.finished:
			continue

		var gap := other.controller.state.position - at

		if absf(gap.y) > 0.8:
			continue

		gap.y = 0.0
		var ahead := gap.dot(heading)
		var going := other.controller.state.velocity.dot(heading)

		var theirs := Vector2(jump_at.x - other.controller.state.position.x, jump_at.z - other.controller.state.position.z).length()

		if ahead > 0.0 and ahead < 1.5 and (gap - heading * ahead).length() < 0.9 and going < 3.0 and going > -0.5 and theirs < mine:
			command.move = Vector2.ZERO
			return true

	return false


## Steers a bot in the air so it comes down on [param target] rather than past it.
##
## [b]A top is small and a running jump is long.[/b] A bot that jumps the moment it lands on
## a ball takes off at whatever speed the landing left it, so the next jump is anywhere from
## three and a half to five metres — and five metres past a ball's top is its far side. The
## motor's air control brakes hard when the wish is against the motion (it is the same
## arithmetic that lets a person stop a jump short), so this predicts where the jump comes
## down at the target's height and holds BACK while that is past it.
func _bot_land_on(player: WoPlayer, command: DotFpsCommand, target: Vector3, line: Vector3, top: bool = false) -> void:
	var state := player.controller.state
	var flat := Vector3(target.x - state.position.x, 0.0, target.z - state.position.z)

	if flat.length() > 7.0:
		return

	var g := config.gravity
	var rise := target.y - state.position.y
	var root := state.velocity.y * state.velocity.y - 2.0 * g * rise

	if root < 0.0:
		return

	var falls_in := (state.velocity.y + sqrt(root)) / g
	command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
	var current := Vector3(state.velocity.x, 0.0, state.velocity.z)
	# [b]How far past the target the landing is, along the JUMP'S LINE[/b] (from the point
	# before to this one). Measured along the line from the runner to the target instead, a
	# jump that had come level with a pad beside it counted nothing as "over" and stopped
	# braking while its speed carried it on past: hard and nightmare stand-ins came down on
	# Spin Cycle's second pad 1.9 m past its middle, at its rim, and jumped short of the
	# third. Measured along the velocity, a runner drifting sideways counted the drift as
	# "over" and braked short of every second ball on Big Balls.
	var along := Vector3(line.x, 0.0, line.z)
	if along.length() < 0.5:
		along = current
	var over := 0.0
	if along.length() > 0.01:
		var lands := state.position + current * falls_in
		over = Vector3(lands.x - target.x, 0.0, lands.z - target.z).dot(along.normalized())

	# Aiming a little PAST the top, never at it: a runner who comes down on a ball's top at a
	# stroll cannot jump on to the next one. Braking all the way to the point left stand-ins a
	# metre short of every third ball.
	over -= LAND_PAST

	# Within a quarter of a metre is near enough for an edge or a pad; a ball's top is not
	# flat, so a landing half a metre past it comes down lower and later, further past, on the
	# slope: Big Balls turned to run along X lost a clean runner off its second ball eight times
	# from landings 0.7 m past. A top is braked to within five centimetres.
	if over <= (0.05 if top else 0.25) or falls_in <= 0.02 or current.length() < 0.5:
		# Nothing in: no wish adds nothing to a jump already at speed, and the jump lands
		# where it was always going to.
		command.move = Vector2.ZERO
		return

	# [b]Braked straight against the velocity, never back along the line to the target.[/b]
	# That line is not the velocity when the runner is off it, and a backward wish along it
	# pushes AWAY from the line: a runner half a metre to one side drifted four metres sideways
	# and past the ball (Big Balls, found by stand-ins coming off a sweeper at an angle). A wish
	# against the velocity only slows; it never turns.
	command.yaw = rad_to_deg(atan2(-current.x, -current.z))

	# Proportional, and full back is far too much: the motor takes over three metres a second
	# off a jump in ONE tick when the wish is fully against it, and the first version stopped
	# every jump dead a metre off the deck. The slowdown needed, spread over the ticks left.
	var ticks_left := maxf(falls_in * float(tick_rate), 1.0)
	var per_tick := over / falls_in / ticks_left
	var full := config.run_speed * 30.0 / float(tick_rate)
	# A stand-in steers a landing as well as `wo_bot_landing` says: below 1 it brakes too
	# little and comes down past a small top, which is how a person slides off a ball.
	var skill := racer.value("landing") if racer != null else 1.0
	command.move = Vector2(0.0, -clampf(per_tick / full * skill, 0.02, 1.0))


## Brakes a jump that is going to come down off the side of the deck it was taken over: true
## when it braked. Only while the ground is still under the bot (braking over a gap is
## falling short of the far side) and only for a jump that will land on nothing.
##
## [b]A hop over an arm is taken the way the bot was running[/b], and running out to the side
## of a centre spinner that is mostly sideways: six metres a second for seven tenths of a
## second carried every stand-in of every preset off the edge of Spin Cycle's first spinner
## deck, twelve falls a field. A person in the air over the edge pulls back.
func _bot_save_landing(player: WoPlayer, command: DotFpsCommand, target: Vector3, line: Vector3) -> bool:
	var state := player.controller.state
	var current := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if current.length() < 0.5:
		return false

	var height := target.y
	var root := state.velocity.y * state.velocity.y - 2.0 * config.gravity * (height - state.position.y)

	if root < 0.0:
		return false

	var falls_in := (state.velocity.y + sqrt(root)) / config.gravity
	var below := Vector3(state.position.x, height + 0.1, state.position.z)
	var lands := below + current * falls_in

	var lands_tick := _tick + int(falls_in * float(tick_rate))

	if stage.supported(lands, lands_tick) or not stage.supported(below, _tick):
		return false

	# And only a jump going off the SIDE: the same jump straight down the route's line would
	# have come down on something. A hop taken toward the front edge is a hop over an arm or a
	# hammer, and braking it under the arm (Big Balls' wrecking balls) is worse than the edge.
	var ahead := Vector3(line.x, 0.0, line.z)

	if ahead.length() < 0.5 or not stage.supported(below + ahead.normalized() * current.length() * falls_in, lands_tick):
		return false

	command.yaw = rad_to_deg(atan2(-current.x, -current.z))
	command.move = Vector2(0.0, -1.0)
	return true


## Jumps when the bot has been running for a second and got nowhere.
##
## [b]A turning log's steep side is a treadmill.[/b] A bot running up it at exactly the speed
## the log turns back stayed on the same spot for half a minute at a time — every number
## correct, the course just never ending. A person in that spot jumps; so does this.
func _bot_unstick(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var mark: Array = _bot_stuck.get(player.player_id, [])

	# Letting go, for half a second after being stuck on something too steep to jump from.
	if mark.size() > 2 and _tick < int(mark[2]):
		command.move = Vector2.ZERO
		return

	if mark.is_empty() or _tick - int(mark[1]) >= tick_rate:
		# [b]Only against a mark from the last second and a half.[/b] A bot held still (waiting
		# for a mover, a window, a column of tiles) is not asked here, so its mark is as old as
		# the wait: on the tick it set off it was "a second without moving" and jumped from a
		# standstill, short of the mover it was timing (Trapdoor Run, three of a field together).
		var stuck := not mark.is_empty() and command.move != Vector2.ZERO \
			and _tick - int(mark[1]) < tick_rate * 3 / 2 \
			and Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4
		var release := -1

		if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		elif stuck:
			# On a face too steep to stand on, the motor has the bot sliding, and a slide is not
			# ground to jump from. Stop pushing and drop: a restart costs seconds, the treadmill
			# cost minutes.
			release = _tick + tick_rate / 2

		_bot_stuck[player.player_id] = [at, _tick, release]


## Jumps whatever low thing is about to sweep through where the bot is running, and ducks
## whatever high thing is.
##
## [b]A person jumps a low arm; they do not wait for a gap it never leaves.[/b] A sweeper
## with two arms at eighty degrees a second covers a six-metre deck for most of every turn,
## so "wait until the way is clear" waits for ever. This asks the course about the next
## half second along the bot's own heading, and jumps when an arm is due between a fifth and
## a half of a second from now — the part of a jump when the feet are above a low arm.
func _bot_hop(player: WoPlayer, command: DotFpsCommand, yaw: float = NAN) -> void:
	if player.controller.state.mode != DotFpsState.Mode.GROUND or command.move == Vector2.ZERO:
		return

	var heading_yaw := command.yaw if is_nan(yaw) else yaw
	var heading := Vector3(-sin(deg_to_rad(heading_yaw)), 0.0, -cos(deg_to_rad(heading_yaw)))
	var at := player.controller.state.position
	var limits := Vector3(1.0, 1.0, 1.0)
	var duck := false
	var jump := false
	var high_arm := stage.high_arm_near(at, 3.0)

	# The same three moments the hop always asked about (a fifth to two fifths of a second:
	# when a jump's feet are over a low arm), plus the two either side for the duck, which
	# has to start earlier and last longer.
	for step in [0.0, 0.2, 0.3, 0.4, 0.6]:
		var ahead: float = step
		# Crouched, a bot runs at the crouch speed; standing, at the run.
		var where_standing := at + heading * config.run_speed * ahead
		var tick := _tick + int(ahead * tick_rate)

		if stage.knock(where_standing, false, tick, limits) == Vector3.ZERO:
			continue

		# [b]A high arm is ducked, never jumped.[/b] If crouching clears what standing does
		# not, the arm is high; jumping into it is the one wrong answer, and the hop below
		# would give it, because all it knows is that something is coming.
		var where_crouched := at + heading * config.run_speed * 0.4 * ahead

		if high_arm and stage.knock(where_crouched, true, tick, limits) == Vector3.ZERO:
			duck = true
		elif ahead >= 0.2 and ahead <= 0.4 \
				and stage.knock(where_standing + Vector3(0.0, 1.0, 0.0), false, tick, limits) == Vector3.ZERO:
			# [b]Only what a jump clears.[/b] A metre up, which is where the feet are a fifth
			# to two fifths of a second into a jump, a low arm has passed under; a ram, a
			# hammer or a falling curtain is still there. Hopping a ram put the runner in it
			# in the air: on Punch Alley the better a stand-in hopped (`hop_miss`), the more
			# it fell, and hard was slower there than medium.
			jump = true

	# Missed now and then (`wo_bot_hop_miss`), decided per half second so one arm is one
	# decision: a stand-in that never misses an arm is the one thing on a sweeper nobody believes.
	if (duck or jump) and racer != null and player.is_bot:
		var racing := _racer_of(player)
		var bucket := _tick / maxi(tick_rate / 2, 1)
		if _bot_roll(&"bot_hop", player, bucket) * 100.0 < racer.value("hop_miss") * float(racing["factor"]):
			return

	# [b]A hop that lands in the arm is worse than no hop.[/b] An arm sweeping the same way
	# the runner is going stays over the deck ahead of them for most of a second: hopping it
	# lands on it again. Measured on First Splash, a stand-in whose arrival on the sweeper was
	# shifted by a few hundredths of a second fell off it on most attempts. So the landing (a
	# jump is about 0.7 s) is asked too, and if it is in the arm's way and standing still for
	# half a second is not, the runner stops and lets it go by, as a person does.
	if jump and not duck:
		var lands := false
		for ahead in [0.72, 0.85]:
			var where: Vector3 = at + heading * config.run_speed * ahead
			if stage.knock(where, false, _tick + int(ahead * tick_rate), limits) != Vector3.ZERO:
				lands = true
				break
		if lands:
			var still_safe := true
			for ahead in [0.0, 0.15, 0.3, 0.45]:
				if stage.knock(at, false, _tick + int(ahead * tick_rate), limits) != Vector3.ZERO:
					still_safe = false
					break
			if still_safe:
				command.move = Vector2.ZERO
				command.set_button(DotFpsCommand.BUTTON_WALK, false)
				return

	if duck:
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	elif jump:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## Whether [param point] — something to land on — will be under a jump that sets off now:
## near enough to reach at a run, and there when the bot comes down and a moment after.
##
## [b]Onto tiles, the whole crossing[/b] (`WoCourse.tile_crossing_clear`): at a walk to the
## first row (the jump onto it is taken at a walk, so it is in the air for the walk's
## distance, not the run's) and at a run across the rest. Asked as "the tile there in an
## eighth of a second at a run", a stand-in standing still, a second and a half of walk and
## jump away, was answered about the wrong moment; and a tile that was there on landing
## dropped while it stood on it waiting for the next row.
func _bot_may_board(player: WoPlayer, point: Dictionary, line: Vector3 = Vector3.ZERO) -> bool:
	var from := player.controller.state.position
	var to: Vector3 = point["at"]
	var distance := Vector2(to.x - from.x, to.z - from.z).length()

	var tiles := not stage.tile_cell(to).is_empty()

	# A ride that has not brought the bot this close yet is a ride to stay on. Tiles are not
	# a ride: a column two over is further than that from a deck, and the crossing is timed
	# from wherever the runner is.
	if distance > 5.0 and not tiles:
		return false

	if tiles:
		var velocity := player.controller.state.velocity
		var moving := Vector2(velocity.x, velocity.z).length() > 1.0
		return stage.tile_crossing_clear(from, to, _tick, config.run_speed * config.walk_speed_scale,
			config.run_speed, 0.0 if moving else TILE_START_SECONDS, line,
			TILE_ON_SLACK if not stage.tile_under(player.controller.state.ground_id).is_empty() else 1.0)

	var lands := _tick + int(distance / maxf(config.run_speed, 0.5) * float(tick_rate)) + tick_rate / 8
	return stage.supported(to, lands) and stage.supported(to, lands + tick_rate / 4)


## Everybody still racing or home, in race order: the finished by place, then by checkpoint,
## then by how far along the route they are. What the HUD's place and the announcer's leader
## read; on a client from the positions it draws. Watchers and an arena give an empty list.
func race_order() -> Array[StringName]:
	var order: Array[StringName] = []

	if stage == null or not stage.is_course():
		return order

	var route := stage.route()
	var keys := {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching:
			continue

		var key := 0.0

		if player.finished:
			key = 1.0e9 - float(player.place)
		else:
			var at := player.controller.state.position
			var index := _route_after(at) if not route.is_empty() else 0
			# How far along, in metres (a fork counted at its shortest branch's length, so a
			# runner on the long way round is not ahead for its points coming later in the
			# list), and between the nearest point and the next, so two runners at one point
			# are told apart.
			var progress := stage.route_progress()
			var along := float(progress[index]) if index < progress.size() else 0.0
			var after := stage.route_next(index)
			if after < route.size():
				var here: Vector3 = (route[index] as Dictionary)["at"]
				var next: Vector3 = (route[after] as Dictionary)["at"]
				var leg := here.distance_to(next)
				var toward := clampf(1.0 - at.distance_to(next) / maxf(leg, 0.01), -1.0, 1.0)
				along += toward * (float(progress[after]) - float(progress[index]))
			key = float(player.checkpoint + 1) * 1.0e5 + along

		keys[id] = key
		order.append(id)

	order.sort_custom(func(a: StringName, b: StringName) -> bool:
		return float(keys[a]) > float(keys[b]) or (float(keys[a]) == float(keys[b]) and String(a) < String(b)))
	return order


## The route point a bot should head for from [param at]: the nearest one, then onward
## ([param branch] is the way it is going at a fork, when the nearest point is where one starts).
func _route_after(at: Vector3, branch: int = 0) -> int:
	var route := stage.route()
	var best := 0
	var best_distance := INF

	for index in range(route.size()):
		var distance := at.distance_to((route[index] as Dictionary)["at"])

		if distance < best_distance:
			best_distance = distance
			best = index

	# [b]Past the nearest point, the next one.[/b] A checkpoint just across a gap is nearer the
	# jump point behind it than the point ahead, and a stand-in put back there turned round and
	# jumped back across the gap, every time (Spin Cycle's second checkpoint).
	var after := stage.route_next(best, branch)
	if after < route.size():
		var here: Vector3 = (route[best] as Dictionary)["at"]
		var next: Vector3 = (route[after] as Dictionary)["at"]
		var ahead := Vector3(next.x - here.x, 0.0, next.z - here.z)
		if ahead.dot(Vector3(at.x - here.x, 0.0, at.z - here.z)) > 0.0:
			best = after

	return best


## The route point after [param index] for this stand-in, choosing a branch where a fork starts.
##
## [b]The faster way is taken by `wo_bot_risk`[/b]: a chance in a hundred per fork and ATTEMPT
## (`falls`), like every other decision, so a stand-in that went in off the risky branch may
## take the safe one from the checkpoint. Harder presets take the risk more often, and
## make it more often, which is most of why they are faster on a course with a fork.
func _bot_next(player: WoPlayer, racing: Dictionary, index: int) -> int:
	var route := stage.route()

	if index < route.size() and int((route[index] as Dictionary).get("branch", 0)) != 0:
		racing["branch"] = int((route[index] as Dictionary)["branch"])
		return stage.route_next(index, int(racing["branch"]))

	var branches := stage.route_branches(index)

	if branches.is_empty():
		return stage.route_next(index, 0)

	if int(racing.get("fork_at", -1)) != index or int(racing.get("fork_falls", -1)) != player.falls:
		var risky := _bot_roll(&"bot_risk", player, index * 64 + player.falls) * 100.0 < racer.value("risk")
		var chosen := int((branches[0] as Dictionary)["branch"])
		for b: Dictionary in branches:
			if bool(b["risky"]) == risky:
				chosen = int(b["branch"])
				break
		racing["fork_at"] = index
		racing["fork_falls"] = player.falls
		racing["branch"] = chosen

	return stage.route_next(index, int(racing["branch"]))


func _bot_fight(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var enemy := _nearest_enemy(player)

	if player.weapons != null and enemy != null:
		_aim_bot(player, command, enemy)
		var distance := enemy.controller.state.position.distance_to(at)

		if distance > 7.0:
			command.move = Vector2(0.0, 1.0)

		return

	# Nothing in hand: the nearest weapon, then the nearest prop, then walk at somebody.
	var target := Vector3.INF
	var best := INF

	for pickup_id: int in pickups:
		var spot: Vector3 = (pickups[pickup_id] as Dictionary)["at"]
		var distance := spot.distance_to(at)

		if distance < best:
			best = distance
			target = spot

	if player.grab != null and player.grab.is_carrying() and enemy != null:
		_aim_bot(player, command, enemy)
		# Thrown once the aim is on (dot-bot's trigger) and they are near enough to hit.
		command.set_button(DotFpsCommand.BUTTON_USER_0, command.is_pressed(DotFpsCommand.BUTTON_USER_0)
			and enemy.controller.state.position.distance_to(at) < 9.0)
		command.move = Vector2(0.0, 1.0)
		player.wants_grab = false
		return

	if target == Vector3.INF:
		for prop in props.all_props():
			var body := prop.body()

			if body == null:
				continue

			var distance := body.global_position.distance_to(at)

			if distance < best:
				best = distance
				target = body.global_position

		if target != Vector3.INF and best < GRAB_REACH - 0.6:
			var look := target - player.eye_position()
			command.yaw = rad_to_deg(atan2(-look.x, -look.z))
			command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
			player.wants_grab = not player.wants_grab
			return

	if target == Vector3.INF and enemy != null:
		target = enemy.controller.state.position

	if target != Vector3.INF:
		var toward := target - at
		toward.y = 0.0
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)


func _nearest_enemy(player: WoPlayer) -> WoPlayer:
	var best: WoPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: WoPlayer = players[id]

		if other == player or not other.is_alive() or other.watching:
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(player.controller.state.position)

		if distance < closest:
			closest = distance
			best = other

	return best


## Aims a stand-in at [param target] and fires when dot-bot's [DotBotAim] says: the view turns
## at `bot_turn_rate`, the first shots miss by `bot_aim_error` and settle, the trigger waits
## `bot_reaction` after the target is first in view. One `bot_difficulty` for the race and the
## fight; the old `wo_bot_spread` (a fixed offset per round) is gone.
func _aim_bot(player: WoPlayer, command: DotFpsCommand, target: WoPlayer) -> void:
	var aim: DotBotAim = _racer_of(player)["aim"]
	var eye := player.eye_position()
	var point := target.eye_position() - Vector3(0.0, 0.35, 0.0)

	if eye.distance_to(point) < 0.01:
		return

	var now := _bot_now()
	var _new := aim.engage(int(target.entity_id), eye, point, now)
	var view := aim.track(eye, point, target.controller.state.velocity, now, delta_for_tick())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(now, eye.distance_to(point))

	if fire:
		aim.note_shot(eye, point, now)

	command.set_button(DotFpsCommand.BUTTON_USER_0, fire)


## The game clock in seconds, for the stand-ins' aim.
func _bot_now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


# --- Reacting ---------------------------------------------------------------

## The stock death reactions plus this game's [constant FLING]. One list for both ends.
static func death_reactions() -> DotPlayerDeathReactions:
	var out := DotPlayerDeathReactions.stock()
	var fling := DotPlayerDeathReaction.new()
	fling.id = FLING
	fling.display_name = "Wipeout fling"
	fling.weight = 0.0
	fling.pose = DotPlayerDeathReaction.Pose.LAUNCH
	fling.push = 9.0
	fling.hit_push = 6.0
	fling.launch_up = 9.0
	fling.launch_along = 4.0
	fling.spin = 12.0
	fling.start_sound = DotPlayerDeathReactions.SOUND_WHOOSH
	fling.land_sound = DotPlayerDeathReactions.SOUND_THUD
	fling.land_speed = 3.0
	var _added := out.add(fling)
	return out


## How wild a knockout is, 0 to 1, from the fraction of health the player had BEFORE the blow:
## 0 at or above [member WoConfig.knockout_fling_below] (or with the flight off), 1 at no health.
func fling_wildness(health_before: float) -> float:
	var below := config.knockout_fling_below
	if below <= 0.0 or config.player_health <= 0.0:
		return 0.0
	var fraction := clampf(health_before / config.player_health, 0.0, 1.0)
	if fraction > below:
		return 0.0
	return 1.0 - fraction / below


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick, with the killing weapon's def (zee's sniper and launcher always throw
## the body). A death with no sideways direction (a fall, a trap) pushes nothing.
##
## [b]A course knockout at low health is a flight[/b] ([constant FLING]): the lower the health
## the blow found, the harder the push, written into the death's damage (which is what travels).
func decide_death(player: WoPlayer, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ZeeWeaponPack.table()
	var direction := damage.direction
	var attacker: WoPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	var death := DotPlayerDeath.decide(
		ragdoll_rules.reactions(death_reactions()), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick), _weapon_defs.get(damage.weapon_id)
	)

	if damage.context.has("health_before"):
		var wild := fling_wildness(float(damage.context["health_before"]))
		if wild > 0.0:
			death.reaction = FLING
			# 25 percent of the power at the edge, all of it at no health; 1.0 is a hundred damage.
			death.damage = config.knockout_fling_power * (0.25 + 0.75 * wild) * 100.0
			death.headshot = false

	return death


func _on_player_died(player: WoPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	if player.grab != null:
		var _dropped := player.grab.drop()

	# Spectating and progress BEFORE dot-match: `report_kill` can end the round inside the
	# call, and a kill counted after that is counted in no round. mg-smash-copter's finding.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			stage.water_height() + 8.0, _tick
		)

	if progress != null:
		progress.on_died(player.player_id, by, why == DIED_FELL, true)

	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	if authoritative:
		player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)

	# On the course a death is either the round over for them (the brief's "fatal", the
	# default) or a restart at the last checkpoint. Either way they are alive again at once:
	# an eliminated player watches from the lounge, untouchable, until the next round.
	if authoritative and stage != null and stage.is_course() and not player.finished:
		if player.health != null:
			player.health.health = config.player_health
			player.health.alive = true
		if config.course_deaths_eliminate or config.instant_death:
			player.watching = true
			player.out_for_round = config.instant_death
			if player.health != null:
				player.health.invulnerable = true
			var seat := stage.lounge_spot(20 + players.size())
			player.place_at(seat[0], seat[1])
		else:
			var spot := stage.respawn_point(player.checkpoint, player.falls % 5)
			player.place_at(spot[0], spot[1])

	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.COUNTDOWN:
			return maxf(config.countdown_seconds - phase_elapsed, 0.0)
		Phase.COURSE:
			return maxf(course_limit() - course_elapsed, 0.0)
		Phase.HANDOVER:
			return maxf(config.handover_seconds - phase_elapsed, 0.0)
		Phase.FINALE:
			return maxf(config.finale_seconds - phase_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"course": str(course_doc.get("id", "-")),
		"arena": str(arena_doc.get("id", "-")),
		"players": players.size(),
		"finished": finished_count(),
		"alive": alive_count(),
		"props": props.world_count() if props != null else 0,
		"pickups": pickups.size(),
		"decided": _winner_name if _decided else "-",
		"courses": catalogue.courses.size() if catalogue != null else 0,
		"arenas": catalogue.arenas.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["wipeout, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	if stage != null:
		lines.append_array(stage.describe_lines())

	return lines


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: WoPlayer, shot: DotShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == DotHitGroup.HEAD)
