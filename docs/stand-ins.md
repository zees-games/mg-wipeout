# Stand-ins

Stand-ins run the document's route (`route` in mg-wipeout-maps) and make the mistakes a person makes. How many there are follows dot-server's `DotBotQuota`: a person replaces a bot, and leaving brings it back. Solo starts with eight (`offline_bots`, `-- --bots N` at launch); a server's default is `bot_quota 9` in fill mode, a person and eight (`minimum_players`, `game.yml`).

## How a stand-in races

**The difficulty is dot-bot's `bot_difficulty`** (easy, medium, hard, nightmare; medium by default), the same word that sets how a stand-in aims in a final death (dot-bot's `DotBotAim`: `bot_turn_rate`, `bot_reaction`, `bot_aim_error`). The race is decided by mistakes, never by a slower run: everybody runs at the same speed. `WoRacer` holds one column of racing settings per preset, each a cvar (`wo_bot_<field>`, at the solo console too) that outlives a preset change once set by hand, the way dot-bot's own do:

| Setting | easy | medium | hard | nightmare | What |
| --- | --- | --- | --- | --- | --- |
| `wo_bot_fumble` | 7 | 3.5 | 1.5 | 0.5 | chance in 100 a jump is not taken at all |
| `wo_bot_timing` | 0.06 | 0.04 | 0.025 | 0.012 | seconds a take-off is early or late (a third of it off a top) |
| `wo_bot_rash` | 14 | 7 | 3 | 1 | chance in 100 of going without waiting for a window |
| `wo_bot_hop_miss` | 18 | 9 | 4 | 1 | chance in 100 an arm is not jumped or ducked |
| `wo_bot_landing` | 0.55 | 0.75 | 0.9 | 1 | how well a landing on a small top is steered |
| `wo_bot_recover` | 1.4 | 0.9 | 0.5 | 0.25 | seconds stood still after a fall |
| `wo_bot_variety` | 0.45 | 0.45 | 0.4 | 0.3 | how much one stand-in differs from the next |
| `wo_bot_risk` | 15 | 40 | 70 | 90 | chance in 100 of taking a fork's faster, riskier branch (a choice, so not scaled by `wo_bot_mistakes`) |
| `bot_reaction` (dot-bot) | 0.5 | 0.3 | 0.21 | 0.12 | seconds between a window opening and setting off |

- Every mistake is a seeded draw per bot, route point and ATTEMPT (`falls`), so a replayed round makes the same mistakes and a fumbled jump is not fumbled again on every attempt. Each bot's share of the preset (`factor`, up to `wo_bot_variety` either way) is drawn per bot and round: eight medium stand-ins are eight runners, and a different eight next round.
- `wo_bot_mistakes` (`WoConfig.bot_mistakes`, default 1) scales all of it; 0 is a stand-in that is never wrong, which is what `headless_courses` runs to prove a course can be finished.
- A late take-off off an edge point is a step into the water; an early one off a deck is a shorter jump that usually still makes it. That is most of what separates easy from nightmare.

## The route flags

Each was earned by watching a bot fail in `tools/trace_course` (one runner) or `tools/race_times --verbose` (a field).

- **`jump`**: jump here, **once on the ground**, after getting up to speed (an edge: up to three ticks; too slow or going the wrong way, it backs up 0.4 s along the jump's line for a run at it). On a **top** (a jump point with a reach over 0.6: a ball, a log, a pad) it runs on toward the next top until the jump will make it (the distance over a jump's air time, to the next top's height) or the top runs out, and it is never jumped from on the tick of landing, when the velocity is still the jump's.
- **On a top, it faces the next top, never the point** (unless it landed past the point too slow to jump, when the run-up goes back over it), and a take-off faster than 1.3 times the jump's need brakes the excess on the take-off tick (`TAKEOFF_SPARE`), except on a log turning toward it. A landing aimed past the point left the point behind the runner: turning to it took a log take-off from five metres a second to two (Log Roll, a mistake-free field falling three times a run), and a take-off at full speed was braked in the air to a standstill past the next log's top, where the motor refuses a jump on the far side's curve.
- In the air toward a `jump`, `bounce` or `board` point, `_bot_land_on` predicts the landing and brakes **against the velocity, proportionally, aiming 0.3 m past the point**. Braking back along the line to the target pushed a runner who was off the line further off it; braking to land exactly on the point left too little speed for the next top. How far past is measured **along the jump's own line** (the point before to this one): along the line to the target, a jump level with a pad beside it counted nothing as past and stopped braking (Spin Cycle's pads, hard and nightmare); along the velocity, sideways drift counted as past and braked short. A top is braked to within 5 cm (a ball's curve takes a landing half a metre past further on), an edge to within 25 cm.
- In the air toward any other point, a jump that will come down off the side of the deck it was taken over is braked (`_bot_save_landing`), only when the same jump straight down the route would land: a hop over a centre spinner's arm at a run out to its side went off the deck for every preset.
- A bounce point is reached on the way up off the pad when the bot is over it or past it (within 2.5 m), not only within its reach: a bounce that landed long braked back at the pad's middle and fell short of the deck after.
- **`wait`**: hold until `WoCourse.path_clear` says the run to the next point meets no hazard, then set off a reaction later (`bot_reaction`), committed: a slow reaction is a late start into a closing window. Walk only the last 1.6 m into a stop point.
- **`board`**: something to land on. Hold until it will be under the landing and within 5 m, then jump at whatever edge comes first. A board point is not passed in the air.
- **`board` onto tiles** (a grid of trapdoors) is timed for the whole crossing, not the next tile: `WoCourse.tile_crossing_clear` searches forward, from where the runner is, where it can be standing in the middle of each row and when, allowing a stop on a tile for as long as that tile stays up, and the stand-in sets off only if that reaches the far side. The reckoning is twice over, soonest (full speed) and latest (`TILE_SLOW` of it, plus `TILE_START_SECONDS` after a stop, plus `TILE_MARGIN_SECONDS`); a stand-in already on the tiles reckons with less of that slack (`TILE_ON_SLACK`), or one that landed at a walk found its clear crossing not clear any more from the first row. Off the deck at a walk (a running jump lands two rows on), lined up on its column first, at least 1.3 m back from the edge so it is walking when it jumps, and the jump put off until 0.35 m before the edge (fired the usual metre back, a walk's jump came down in the gap); across the tiles at a run, stepping from row to row, never jumping (the edge jump fired there only when the tile ahead was DOWN). A tile ahead that is down is waited for; a tile underfoot that is about to drop is left only for a tile that is up. `wo_bot_rash` sends a stand-in off the deck without waiting for its column.
- **`ride`**: a point ON a carrier is reached by standing on any carrier.
- **`bounce`**: a point on a bouncer, reached by coming down over it: a runner on a bouncer is on the ground for one tick.
- **`onward`**: a jump point the bot may land PAST; the jump aims at the next point. A top landed on past its point (within 2.2 m) counts as reached on every top.
- **`branch`, `risky`** (format 2): a fork. Where one starts, the bot picks a branch (`_bot_next`: the risky one by `wo_bot_risk`, drawn per fork and attempt) and walks only its own branch's points (`WoCourse.route_next`); put back at a checkpoint it takes the branch of the point it is nearest. The race order counts a fork as long as its shortest branch (`WoCourse.route_progress`), so the long way round is not ahead for its points coming later in the list.
- A bot standing more than 2 m below the point it runs for, whose nearest point is two or more behind it, has fallen onto an earlier leg of a course that turns, and starts again from there.
- `_bot_hop` jumps an arm due in 0.2–0.4 s along the heading, **only if a metre up is clear of it** (a low arm; never a ram, a hammer or a falling curtain, which a hop only meets in the air: on Punch Alley the better a bot hopped, the more it fell), unless the landing (0.7 s on) is in an arm too and standing still is safe, when it stops and lets it pass. It ducks only an arm whose underside is above a standing jump.
- Too slow at an edge, it backs up for a run, **except on a turntable**: the disc's carry reads as a squint, and backing up under a spinner's arms is standing in them. On a seesaw it still backs up; without the run the next plank was short.
- `_bot_unstick` jumps after a second of going nowhere, or lets go on a face too steep to jump from, measured against a mark from the last second and a half only: a stand-in held still (a mover, a window, a column) is not asked, and against the wait's own mark it jumped from a standstill on the tick it set off.

## A field of them

- **Stand-ins pass through each other.** They are on their own collision layer (`bot`); a person's movement stops at stand-ins and people, a stand-in's at people only. A solid field of eight shoved itself off every edge and queued at every run of tops. With a person in the way (`mp_solidplayers` on), a stand-in waits a couple of metres back from an edge while the top it would land on is taken (two seconds at most), and queues behind a person standing near a jump point.
- **Each down its own column of tiles.** On the deck a stand-in claims the column of the grid fewest others still crossing it have claimed (`_bot_tile_column`), among the columns that can be crossed at all (`WoCourse.tile_column_crossable`: one whose next row comes up just as the row before it drops never can, and Trapdoor Run's last grid has two), and waits for that one; after `TILE_PATIENCE` it takes another whose crossing is clear but not one more of the field has claimed, after twice that any. Once on the tiles its column is the one under its feet, wherever the jump put it: never one it would walk across a row to reach (a field that did walked over tiles as they dropped and fell half as often again). `tools/race_times --verbose` prints the crossings per column of every grid and the falls from the tiles.
- `WoGame.race_order()` is the field in race order (home by place, then checkpoint, then along the route): the HUD's "3rd of 9", the announcer's leader, the big screens.

## Measured

`tools/race_times` races a field round every course at every preset, headless and deterministic (`--bots`, `--rounds`, `--difficulty`, `--course=` a prefix, `--set=field=value`, `--mistakes`, `--damage`, `--verbose`, `--follow=NAME`, `--extra=DIR` for scratch courses, `--csv`). Knock damage on, weather off. Median finish, 2026-10-12 after the log take-offs (ec080e6) and the tile crossing, four rounds of eight per preset (home of thirty-two, fastest):

| Course | easy | medium | hard | nightmare |
| --- | --- | --- | --- | --- |
| First Splash | 81.0 s (32/32 home, fastest 68.0) | 77.6 s (32/32 home, fastest 68.0) | 71.1 s (32/32 home, fastest 67.8) | 68.3 s (32/32 home, fastest 67.9) |
| Spin Cycle | 76.4 s (30/32 home, fastest 52.2) | 62.5 s (31/32 home, fastest 51.2) | 59.0 s (32/32 home, fastest 51.6) | 62.6 s (32/32 home, fastest 51.7) |
| Big Balls | 77.3 s (32/32 home, fastest 64.0) | 65.3 s (32/32 home, fastest 60.9) | 61.2 s (32/32 home, fastest 60.8) | 60.8 s (32/32 home, fastest 60.8) |
| Punch Alley | 62.6 s (32/32 home, fastest 57.1) | 58.9 s (32/32 home, fastest 56.9) | 57.0 s (32/32 home, fastest 56.9) | 56.9 s (32/32 home, fastest 56.9) |
| Trapdoor Run | 79.1 s (32/32 home, fastest 70.1) | 76.1 s (32/32 home, fastest 67.1) | 70.1 s (32/32 home, fastest 67.1) | 67.2 s (32/32 home, fastest 67.2) |
| Log Roll | 89.5 s (32/32 home, fastest 56.4) | 71.8 s (32/32 home, fastest 51.7) | 58.1 s (32/32 home, fastest 51.9) | 53.4 s (32/32 home, fastest 51.7) |
| The Sweeper | 73.0 s (32/32 home, fastest 54.0) | 70.6 s (32/32 home, fastest 54.8) | 66.3 s (32/32 home, fastest 54.1) | 57.7 s (32/32 home, fastest 55.1) |
| Uphill Belt | 90.7 s (32/32 home, fastest 85.5) | 87.9 s (32/32 home, fastest 85.2) | 86.3 s (32/32 home, fastest 82.9) | 82.9 s (32/32 home, fastest 82.9) |
| Hammer Gauntlet | 82.5 s (32/32 home, fastest 72.7) | 73.8 s (31/32 home, fastest 66.5) | 69.6 s (32/32 home, fastest 66.4) | 66.5 s (32/32 home, fastest 63.3) |
| Grand Tour | 110.9 s (32/32 home, fastest 94.4) | 107.9 s (32/32 home, fastest 89.8) | 98.4 s (32/32 home, fastest 89.2) | 92.0 s (32/32 home, fastest 91.1) |
| Lily Pond | 78.3 s (32/32 home, fastest 71.6) | 72.8 s (32/32 home, fastest 65.1) | 72.5 s (32/32 home, fastest 64.7) | 66.0 s (32/32 home, fastest 65.5) |

A stand-in that never makes a mistake runs each in 56–119 s, each way through a fork (`headless_courses`). Every preset is faster than the one below it on every course but Spin Cycle, where nightmare (62.6) is behind hard (59.0); the same four rounds measured the same before the tile change, so it is not the tiles. Uphill Belt is decided by its belts and bouncers, and every preset is within eight seconds there. On Trapdoor Run a mistake-free nightmare field falls no times in four rounds (it fell 1.25 times a run before the crossing was timed whole), and with mistakes the tiles cost easy 0.25 falls a run, nightmare none; `--verbose` prints crossings per column of every grid. `headless_courses` holds the ordering (a nightmare field of six all home, its median not slower than an easy field's on First Splash).

## Course layout rules the stand-ins taught

The authoring side is in mg-wipeout-maps.

- Every route starts at the middle of the start pad, and restarts and joiners get full-row seats.
- A checkpoint is never in a hazard's reach (the builder refuses it) and sits near the START of plain deck, so a runner put back there has a run-up.
- A run of tops is lined up: a point on the line 3.5 m before the edge.
- Pendulums use `yaw` 0; a conveyor on a ramp takes `pitch`; hammers at least 4.2 m apart and rams 4.5 m.
- A centre spinner ends in four metres of plain deck, so the next jump is not taken sideways out of an arm's reach.
- A stand point before something to board is never behind the run-out's last point.
