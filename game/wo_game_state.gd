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

const TEAM_COLOURS: Array[Color] = [
	Color(0.85, 0.27, 0.26),
	Color(0.29, 0.53, 0.86),
	Color(0.35, 0.72, 0.38),
	Color(0.92, 0.78, 0.22),
	Color(0.66, 0.42, 0.82),
	Color(0.91, 0.55, 0.20),
]

const TEAM_NAMES: Array[String] = [
	"Red", "Blue", "Green", "Yellow", "Violet", "Orange",
]

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


## Team [param index]'s colour (0 is team id 1): the table's six, then as many more as the server
## plays with, spread round the hue circle by the golden ratio so neighbours differ.
static func team_colour(index: int) -> Color:
	if index >= 0 and index < TEAM_COLOURS.size():
		return TEAM_COLOURS[index]
	return Color.from_hsv(fposmod(0.11 + float(index) * 0.618034, 1.0), 0.62, 0.86)


## Team [param index]'s name (0 is team id 1): the table's, then "Team 7", "Team 8" and on.
static func team_name(index: int) -> String:
	if index >= 0 and index < TEAM_NAMES.size():
		return TEAM_NAMES[index]
	return "Team %d" % (index + 1)
