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
| `bot_reaction` (dot-bot) | 0.5 | 0.3 | 0.21 | 0.12 | seconds between a window opening and setting off |

- Every mistake is a seeded draw per bot, route point and ATTEMPT (`falls`), so a replayed round makes the same mistakes and a fumbled jump is not fumbled again on every attempt. Each bot's share of the preset (`factor`, up to `wo_bot_variety` either way) is drawn per bot and round: eight medium stand-ins are eight runners, and a different eight next round.
- `wo_bot_mistakes` (`WoConfig.bot_mistakes`, default 1) scales all of it; 0 is a stand-in that is never wrong, which is what `headless_courses` runs to prove a course can be finished.
- A late take-off off an edge point is a step into the water; an early one off a deck is a shorter jump that usually still makes it. That is most of what separates easy from nightmare.

## The route flags

Each was earned by watching a bot fail in `tools/trace_course` (one runner) or `tools/race_times --verbose` (a field).

- **`jump`**: jump here, **once on the ground**, after getting up to speed (an edge: up to three ticks; too slow or going the wrong way, it backs up 0.4 s along the jump's line for a run at it). On a **top** (a jump point with a reach over 0.6: a ball, a log, a pad) it runs on toward the next top until the jump will make it (the distance over a jump's air time, to the next top's height) or the top runs out, and it is never jumped from on the tick of landing, when the velocity is still the jump's.
- In the air toward a `jump`, `bounce` or `board` point, `_bot_land_on` predicts the landing and brakes **against the velocity, proportionally, aiming 0.3 m past the point**. Braking back along the line to the target pushed a runner who was off the line further off it; braking to land exactly on the point left too little speed for the next top.
- **`wait`**: hold until `WoCourse.path_clear` says the run to the next point meets no hazard, then set off a reaction later (`bot_reaction`), committed: a slow reaction is a late start into a closing window. Walk only the last 1.6 m into a stop point.
- **`board`**: something to land on. Hold until it will be under the landing and within 5 m, then jump at whatever edge comes first; onto tiles at a walk (a running jump lands two rows on), and to whichever column's tile will be up, not only the middle one. A board point is not passed in the air. Not standing on a tile that is about to drop.
- **`ride`**: a point ON a carrier is reached by standing on any carrier.
- **`bounce`**: a point on a bouncer, reached by coming down over it: a runner on a bouncer is on the ground for one tick.
- **`onward`**: a jump point the bot may land PAST; the jump aims at the next point. A top landed on past its point (within 2.2 m) counts as reached on every top.
- `_bot_hop` jumps an arm due in 0.2–0.4 s along the heading, unless the landing (0.7 s on) is in an arm too and standing still is safe, when it stops and lets it pass. It ducks only an arm whose underside is above a standing jump.
- `_bot_unstick` jumps after a second of going nowhere, or lets go on a face too steep to jump from.

## A field of them

- **Stand-ins pass through each other.** They are on their own collision layer (`bot`); a person's movement stops at stand-ins and people, a stand-in's at people only. A solid field of eight shoved itself off every edge and queued at every run of tops. With a person in the way (`mp_solidplayers` on), a stand-in waits a couple of metres back from an edge while the top it would land on is taken (two seconds at most), and queues behind a person standing near a jump point.
- `WoGame.race_order()` is the field in race order (home by place, then checkpoint, then along the route): the HUD's "3rd of 9", the announcer's leader, the big screens.

## Measured

`tools/race_times` races a field round every course at every preset, headless and deterministic (`--bots`, `--rounds`, `--difficulty`, `--course=` a prefix, `--set=field=value`, `--mistakes`, `--damage`, `--verbose`, `--follow=NAME`, `--extra=DIR` for scratch courses, `--csv`). Knock damage on, weather off. Median finish, 2026-10-12, two rounds of eight per preset (home of sixteen, fastest):

| Course | easy | medium | hard | nightmare |
| --- | --- | --- | --- | --- |
| First Splash | 78.1 s (16/16 home, fastest 61.9) | 65.0 s (16/16 home, fastest 61.8) | 64.9 s (16/16 home, fastest 61.8) | 62.8 s (16/16 home, fastest 58.4) |
| Spin Cycle | 77.7 s (16/16 home, fastest 54.0) | 72.7 s (16/16 home, fastest 41.3) | 101.7 s (16/16 home, fastest 50.5) | 92.3 s (15/16 home, fastest 41.5) |
| Big Balls | 89.7 s (16/16 home, fastest 55.9) | 67.4 s (16/16 home, fastest 49.7) | 62.2 s (16/16 home, fastest 46.4) | 56.8 s (16/16 home, fastest 49.3) |
| Punch Alley | 79.1 s (16/16 home, fastest 60.9) | 64.4 s (16/16 home, fastest 57.2) | 68.0 s (16/16 home, fastest 58.8) | 62.9 s (16/16 home, fastest 57.2) |
| Trapdoor Run | 102.3 s (15/16 home, fastest 62.6) | 97.3 s (16/16 home, fastest 62.6) | 84.7 s (16/16 home, fastest 75.1) | 87.0 s (16/16 home, fastest 62.6) |
| Log Roll | 98.7 s (14/16 home, fastest 56.7) | 76.0 s (16/16 home, fastest 55.3) | 71.9 s (16/16 home, fastest 60.6) | 72.8 s (16/16 home, fastest 55.2) |
| The Sweeper | 88.4 s (16/16 home, fastest 48.5) | 76.1 s (16/16 home, fastest 60.6) | 71.3 s (16/16 home, fastest 54.3) | 77.8 s (16/16 home, fastest 49.8) |
| Uphill Belt | 94.4 s (16/16 home, fastest 63.6) | 65.5 s (16/16 home, fastest 63.1) | 66.0 s (16/16 home, fastest 60.5) | 68.2 s (16/16 home, fastest 60.5) |
| Hammer Gauntlet | 90.7 s (16/16 home, fastest 59.2) | 68.3 s (16/16 home, fastest 54.6) | 65.2 s (16/16 home, fastest 48.6) | 51.6 s (16/16 home, fastest 48.3) |
| Grand Tour | 119.9 s (16/16 home, fastest 86.6) | 104.6 s (16/16 home, fastest 95.6) | 104.8 s (16/16 home, fastest 97.4) | 101.6 s (16/16 home, fastest 97.0) |
| Lily Pond | 67.0 s (16/16 home, fastest 60.6) | 67.9 s (16/16 home, fastest 60.6) | 61.1 s (16/16 home, fastest 60.6) | 61.2 s (16/16 home, fastest 60.6) |

A stand-in that never makes a mistake runs each in 55–98 s (`headless_courses`). Easy is the slowest field on every course but Lily Pond (where every preset is within seven seconds) and nightmare the fastest on most; on turning pads after a turntable (Spin Cycle) hard and nightmare are no better than medium, a weakness of the run-up on a carried top, not of the presets. `headless_courses` holds the ordering (a nightmare field of six all home, its median not slower than an easy field's on First Splash).

## Course layout rules the stand-ins taught

The authoring side is in mg-wipeout-maps.

- Every route starts at the middle of the start pad, and restarts and joiners get full-row seats.
- A checkpoint is never in a hazard's reach (the builder refuses it) and sits near the START of plain deck, so a runner put back there has a run-up.
- A run of tops is lined up: a point on the line 3.5 m before the edge.
- Pendulums use `yaw` 0; a conveyor on a ramp takes `pitch`; hammers at least 4.2 m apart and rams 4.5 m.
- A centre spinner ends in four metres of plain deck, so the next jump is not taken sideways out of an arm's reach.
- A stand point before something to board is never behind the run-out's last point.
