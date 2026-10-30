extends DotConfig

## Every number this game has, layered like every other [DotConfig], in metres and seconds as the course documents are.
## Not the courses: where a platform is and how fast an arm turns are the document's ([WoCourseDoc]), content a server
## installs and a client is sent. This file is the rules every course is played under.

@export_group("The round")

## Seconds everybody stands behind the start gate before it drops.
##
## Not zero: everyone is placed in the same tick, and a course started then is won by whoever loaded first.
@export_range(0.0, 30.0, 0.5) var countdown_seconds: float = 4.0

## Seconds the course is open before the round is called on the clock.
##
## A course document may ask for its own; this is the operator's ceiling. Six minutes: clean runs take one or two.
@export_range(10.0, 1200.0, 5.0) var course_seconds: float = 360.0

## Seconds between the course closing and the final death starting.
##
## Not zero, for the teleport: arriving already hit by a thrown barrel is a death nobody could have avoided.
@export_range(0.0, 30.0, 0.5) var handover_seconds: float = 4.0

## Seconds the final death runs before the round is called on the clock (a draw).
@export_range(10.0, 900.0, 5.0) var finale_seconds: float = 100.0

## How many courses a round runs before its final death, when more than one side finishes.
##
## Only a course two sides finished goes on: the second course rewards a close race. 1 is one course.
@export_range(1, 12, 1) var courses_per_round: int = 3

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds the final killcam plays when a round ends on a kill, added to the intermission (`mp_killcam_time`, 0 off).
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 10.0

## Whether the side that got furthest wins a round nobody finished. On: the alternative is a draw saying the person at
## the last checkpoint and the one who never left the pad played equally well.
@export var progress_decides: bool = true

@export_group("Sides")

## How many teams the server plays with. 0 is every player for themselves, because a course is run by one person;
## teams change what finishing means (a side is through if anybody is). Up to six, as mg-smash-copter, beyond which
## the final death is a free-for-all with bookkeeping.
@export_range(0, 6, 1) var team_count: int = 0

## Whether players may pick their own side.
@export var allow_team_choice: bool = true

## Whether the server evens the sides up between rounds.
@export var autobalance: bool = true

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

## Whether the course hurts at all: knocks, lightning and hard landings. Off, a player's health
## on the course never moves (the final death's fight still uses it, or nobody could win it).
@export var health_enabled: bool = true

## Metres a player may drop onto a deck without it costing health. A jump is 1.25 and a step
## down a course's own platforms is two or three.
@export_range(0.0, 30.0, 0.25) var fall_safe_height: float = 3.5

## Health a hard landing costs, per metre fallen past [member fall_safe_height]. 0: never.
@export_range(0.0, 50.0, 0.5) var fall_damage_per_metre: float = 6.0

## The health fraction (of [member player_health]) at or below which the blow that knocks a player out throws the body
## as a ragdoll. Lower health, wilder flight: a quarter of [member knockout_fling_power] just under this, all of it at
## none. 0 turns it off.
@export_range(0.0, 1.0, 0.01) var knockout_fling_below: float = 0.5

## How hard a knockout at no health throws the body: the ragdoll's push strength, 1 being a
## hundred points of damage (the ragdoll caps it at three).
@export_range(0.0, 10.0, 0.1) var knockout_fling_power: float = 3.0

## How fast a player runs, in m/s.
@export_range(1.0, 20.0, 0.1) var run_speed: float = 7.0

## What fraction of [member run_speed] holding the walk key gives.
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.45

## Metres a standing jump rises.
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.25

## Metres per second squared, for everything: players and props.
##
## Here, not in `project.godot`, as a delivered pack runs at the host's setting and floats. Applied by [WoGame].
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0

## How hard an obstacle throws a player at the least, in m/s.
##
## A floor under the knock: a slow arm near its hub is a metre a second, which reads as an obstacle that does nothing.
@export_range(0.0, 40.0, 0.5) var knock_min_speed: float = 8.0

## The most an obstacle can throw a player, in m/s. A safety cap rather than a feel dial.
@export_range(1.0, 80.0, 0.5) var knock_max_speed: float = 22.0

## How far up every knock throws a player, in m/s.
##
## Up as well as away: a knock along the ground is a shove a player can run out of; one that lifts them is a flight.
@export_range(0.0, 30.0, 0.5) var knock_lift: float = 5.5

## Health a knock costs on the course, per m/s it threw the player. 0: knocks never hurt.
##
## At 1.0 a slow arm (8 m/s) costs 8 and the hardest throw 22; at 1.4 stand-ins were knocked out before a checkpoint.
@export_range(0.0, 10.0, 0.05) var knock_damage_per_speed: float = 1.0

## Whether a player whose health runs out on the course is out for the round (watching
## from the gallery) rather than put back at the last checkpoint. The brief's "fatal".
@export var course_deaths_eliminate: bool = true

## Instant death: a fall into the water, or any death on the course, puts the player out for the rest of the ROUND
## (watching from the lounge) instead of back at a checkpoint. Off by default; one-life courses switch it on with
## their own `cfg/<course id>.cfg` (`wo_instant_death 1`), reverted when the next course loads.
@export var instant_death: bool = false

## Whether crossing a checkpoint restores health, so one bad stretch is not a slow death.
@export var checkpoint_heals: bool = true

@export_group("Points")

## Points for finishing a course, by place: first, second, third... A finisher past the
## list gets [member finish_points_rest]. They add up over a match and show on the Tab board.
@export var finish_points: PackedInt32Array = PackedInt32Array([10, 7, 5])
@export_range(0, 100, 1) var finish_points_rest: int = 3

## Points for being on the side that wins the round, the final death included.
@export_range(0, 100, 1) var winner_points: int = 10

@export_group("Weather")

## Chance, 0 to 1, that a round's course gets gusts of wind.
@export_range(0.0, 1.0, 0.05) var wind_chance: float = 0.5

## Strongest gust, as a sideways acceleration in m/s². Six is a stagger; twelve is a fall.
@export_range(0.0, 40.0, 0.5) var wind_strength: float = 7.0

## Chance, 0 to 1, that a round's course gets a thunderstorm: rain, and lightning striking
## the course at drawn places and moments.
@export_range(0.0, 1.0, 0.05) var storm_chance: float = 0.25

## How many lightning strikes a storm brings over a course.
@export_range(0, 60, 1) var storm_strikes: int = 14

## How near a strike knocks a player, in metres, and what it costs them.
@export_range(0.5, 20.0, 0.5) var strike_radius: float = 3.5
@export_range(0.0, 400.0, 1.0) var strike_damage: float = 35.0

@export_group("The courses")

## Which courses this server may play, by id. Empty means every one it has.
##
## `--wo-course-ids=wo_spin_cycle` is how `tools/shot.sh` looks at one.
@export var course_ids: PackedStringArray = PackedStringArray()

## Whether the next course is drawn at random (seeded) rather than taken in order.
@export var shuffle_courses: bool = true

## The file that says which courses this server ROTATES: `maps.yml` in `cfg/server/addons/dot_map/` of the `--config`
## directory (dot-map's `DotMapRotationFile`); the game ships none. Empty rotates every course. A course it leaves out
## stays installed but is never drawn, balloted or nominated. Replaces [member shuffle_courses]. `sv_map_rotation_file`.
@export var map_rotation_file: String = DotMapRotationFile.DEFAULT_STEM

## Where course and arena documents are read from, beside the one built into this game.
##
## Relative to the game's root, so a delivered pack reads its own copy.
@export var course_directory: String = "courses"

## Seed every random choice in a round is drawn from: the course, the arena, the spawn areas, the drops.
##
## A seed, not a schedule: two servers on one seed play the same round.
@export var seed_value: int = 20261005

@export_group("The final death")

## Which arenas this server may draw, by id. Empty means every one it has.
@export var arena_ids: PackedStringArray = PackedStringArray()

## How many props are dropped into an arena, per side that made it.
@export_range(0, 40, 1) var finale_props_per_side: int = 6

## How many weapons are laid out in an arena, per side that made it.
@export_range(0, 20, 1) var finale_weapons_per_side: int = 2

## The most props an arena holds at once, whatever the count above asks for.
@export_range(4, 200, 1) var prop_budget: int = 60

## Which weapons may be laid out, by id from the pack. Empty means a sensible default set.
@export var weapon_pool: PackedStringArray = PackedStringArray()

## How fast a thrown prop has to be going to hurt somebody, in m/s.
@export_range(0.5, 60.0, 0.5) var throw_hurt_speed: float = 7.0

## Damage a thrown prop does, per kilogram metre per second of momentum.
@export_range(0.0, 2.0, 0.005) var throw_damage_per_impulse: float = 0.075

## How hard a thrown prop leaves the hands, as an impulse.
@export_range(10.0, 20000.0, 10.0) var throw_impulse: float = 1500.0

## Seconds a thrown prop stays dangerous and credited to whoever threw it.
@export_range(0.5, 30.0, 0.5) var thrown_seconds: float = 3.0

## Whether a hit hurts a team-mate (blows and thrown props alike).
@export var friendly_fire: bool = false

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins (`bot_quota`, fill).
##
## Nine, so one person races eight even solo: the final death needs two finishers.
@export_range(0, 24, 1) var minimum_players: int = 9

## Scales every mistake a stand-in makes (`wo_bot_mistakes`): 1 is the difficulty preset's (dot-bot's
## `bot_difficulty`, through [WoRacer]), 0 a stand-in never wrong. Not zero: a bot that never falls finishes in the
## same time every round. 0 is for the course suite, which proves a course can be finished.
@export_range(0.0, 4.0, 0.05) var bot_mistakes: float = 1.0

## Metres a second a stand-in is reckoned to cover on a hop from stone to stone, landing to landing.
@export_range(1.0, 12.0, 0.1) var bot_hop_speed: float = 4.8

## Metres a second a full backward wish takes off a stand-in on the ground in one tick (its take-off braking).
@export_range(0.5, 20.0, 0.1) var bot_ground_brake: float = 3.3

## Seconds a stand-in standing still may take to get going, reckoned onto each tile of a crossing.
@export_range(0.0, 1.0, 0.01) var bot_tile_start_seconds: float = 0.1

## Seconds either side of a stand-in's time on a tile that the tile must also be up. The tile warning and drop schedule stay in code: a client draws them.
@export_range(0.0, 0.5, 0.01) var bot_tile_margin_seconds: float = 0.08

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

@export_group("Progress")

## Whether the server counts per-player numbers and awards achievements at all.
@export var keep_progress: bool = true

## Where lifetime achievement progress is written. Empty keeps it in memory.
@export var progress_directory: String = ""

## Whether the numbers and the unlocks are reported to the backbone. Needs a credential.
@export var report_progress: bool = false


## `@export_group` -> the cfg file it lives in: `cfg/game/mg-wipeout/config_<file>/game.yml`.
const CFG_FILES := {
	"The round": "round", "Sides": "round", "Points": "round", "Watching": "round", "Progress": "round",
	"The players": "players", "The final death": "players", "Bots": "players",
	"The courses": "courses", "Weather": "courses",
}


## The binder every entry point uses: [param config] layered, one cfg file per [constant CFG_FILES] entry.
static func make_binder(config: DotConfig, json_path := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(config, "mg-wipeout", "wo", json_path)
	b.grouped = true
	b.group_files = CFG_FILES
	return b


func env_prefix() -> String:
	return "WO_"


func cli_prefix() -> String:
	return "--wo-"


## Whether this server plays in teams.
func teams() -> bool:
	return team_count >= 2


func validate() -> DotResult:
	if course_seconds <= 0.0 or finale_seconds <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Both halves of a round have to last some time."
		)

	# One team is not a mode: it is everybody on the same side with nobody to beat, and the
	# final death would end on its first tick.
	if team_count == 1 or team_count > 6:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"team_count is %d; this game plays solo (0) or with two to six sides." % team_count,
		)

	if knock_max_speed < knock_min_speed:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"knock_max_speed (%.1f) is below knock_min_speed (%.1f)."
				% [knock_max_speed, knock_min_speed],
		)

	if spectate_camera < 0 or spectate_camera > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"spectate_camera is %d; it is 0 (anybody), 1 (own side) or 2 (nobody)."
				% spectate_camera,
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"sides": "%d teams" % team_count if teams() else "solo",
		"course": "%.0f s" % course_seconds,
		"finale": "%.0f s" % finale_seconds,
		"courses": "all" if course_ids.is_empty() else ",".join(course_ids),
		"arenas": "all" if arena_ids.is_empty() else ",".join(arena_ids),
		"gravity": "%.1f m/s2" % gravity,
		"bots": minimum_players,
	}


## Overridden to print what this game is tuned to rather than every field. The signature keeps the parent's
## `redact_sensitive` though nothing here is secret: a narrowed override is silently the parent's wherever the
## argument is passed.
func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("wipeout configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-14s %s" % [key, facts[key]])
	return lines
