extends Node3D
## Constants and plain state the simulation and its stand-ins share.

const WoConfig := preload("wo_config.gd")
const WoCourse := preload("wo_course.gd")
const WoIoBot := preload("wo_io_bot.gd")
const WoPlayer := preload("wo_player.gd")
const WoProgress := preload("wo_progress.gd")
const WoRacer := preload("wo_racer.gd")

## The ragdoll reaction a knockout at low health gets: a flight, not a fall. This game's own
## entry on dot-player-char's stock set, on the server (which picks it) and on the client (which
## looks it up by this id). Weight 0 so a roll never picks it; only [method decide_death] names it.
const FLING := &"wipeout_fling"

## How far a prop may be from somebody's eyes to be picked up, in metres.
const GRAB_REACH := 3.5

# Team colours and names are dot-team's, for any number of teams: [method DotTeamSet.palette_colour] and
# [method DotTeamSet.palette_name] (index 0 is team id 1).

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

## The course, or during a final death the arena. One node, rebuilt. See [method _begin_handover].
var stage: WoCourse = null

var props: DotPropSpawner = null

var random: DotRandomManager = null

var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

var progress: WoProgress = null

## player id -> WoPlayer.
var players: Dictionary = {}

## player id -> side. A team id with teams, a side of one's own (100+) without.
var sides: Dictionary = {}

var round_number: int = 0

var phase: int = Phase.IDLE

## The pickups lying in an arena: id -> {weapon, at}.
var pickups: Dictionary = {}

var _tick: int = 0

@export var config: WoConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

var combat: DotCombatManager = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from dot-game's `can_peer_be_harmed`. Unset offline, and a bot is never loading.
var harm_gate: Callable = Callable()

var physics: DotPhysicsLayout = null

@export_range(1, 240, 1) var tick_rate: int = 64
