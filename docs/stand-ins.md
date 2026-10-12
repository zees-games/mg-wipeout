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
- In the air toward a `jump`, `bounce` or `board` point, `_bot_land_on` predicts the landing and brakes **against the velocity, proportionally, aiming 0.3 m past the point**. Braking back along the line to the target pushed a runner who was off the line further off it; braking to land exactly on the point left too little speed for the next top. How far past is measured **along the jump's own line** (the point before to this one): along the line to the target, a jump level with a pad beside it counted nothing as past and stopped braking (Spin Cycle's pads, hard and nightmare); along the velocity, sideways drift counted as past and braked short. A top is braked to within 5 cm (a ball's curve takes a landing half a metre past further on), an edge to within 25 cm.
- In the air toward any other point, a jump that will come down off the side of the deck it was taken over is braked (`_bot_save_landing`), only when the same jump straight down the route would land: a hop over a centre spinner's arm at a run out to its side went off the deck for every preset.
- A bounce point is reached on the way up off the pad when the bot is over it or past it (within 2.5 m), not only within its reach: a bounce that landed long braked back at the pad's middle and fell short of the deck after.
- **`wait`**: hold until `WoCourse.path_clear` says the run to the next point meets no hazard, then set off a reaction later (`bot_reaction`), committed: a slow reaction is a late start into a closing window. Walk only the last 1.6 m into a stop point.
- **`board`**: something to land on. Hold until it will be under the landing and within 5 m, then jump at whatever edge comes first; onto tiles at a walk (a running jump lands two rows on), and to whichever column's tile will be up, not only the middle one. A board point is not passed in the air. Not standing on a tile that is about to drop.
- **`ride`**: a point ON a carrier is reached by standing on any carrier.
- **`bounce`**: a point on a bouncer, reached by coming down over it: a runner on a bouncer is on the ground for one tick.
- **`onward`**: a jump point the bot may land PAST; the jump aims at the next point. A top landed on past its point (within 2.2 m) counts as reached on every top.
- **`branch`, `risky`** (format 2): a fork. Where one starts, the bot picks a branch (`_bot_next`: the risky one by `wo_bot_risk`, drawn per fork and attempt) and walks only its own branch's points (`WoCourse.route_next`); put back at a checkpoint it takes the branch of the point it is nearest. The race order counts a fork as long as its shortest branch (`WoCourse.route_progress`), so the long way round is not ahead for its points coming later in the list.
- A bot standing more than 2 m below the point it runs for, whose nearest point is two or more behind it, has fallen onto an earlier leg of a course that turns, and starts again from there.
- `_bot_hop` jumps an arm due in 0.2–0.4 s along the heading, **only if a metre up is clear of it** (a low arm; never a ram, a hammer or a falling curtain, which a hop only meets in the air: on Punch Alley the better a bot hopped, the more it fell), unless the landing (0.7 s on) is in an arm too and standing still is safe, when it stops and lets it pass. It ducks only an arm whose underside is above a standing jump.
- Too slow at an edge, it backs up for a run, **except on a turntable**: the disc's carry reads as a squint, and backing up under a spinner's arms is standing in them. On a seesaw it still backs up; without the run the next plank was short.
- `_bot_unstick` jumps after a second of going nowhere, or lets go on a face too steep to jump from.

## A field of them

- **Stand-ins pass through each other.** They are on their own collision layer (`bot`); a person's movement stops at stand-ins and people, a stand-in's at people only. A solid field of eight shoved itself off every edge and queued at every run of tops. With a person in the way (`mp_solidplayers` on), a stand-in waits a couple of metres back from an edge while the top it would land on is taken (two seconds at most), and queues behind a person standing near a jump point.
- `WoGame.race_order()` is the field in race order (home by place, then checkpoint, then along the route): the HUD's "3rd of 9", the announcer's leader, the big screens.

## Measured

`tools/race_times` races a field round every course at every preset, headless and deterministic (`--bots`, `--rounds`, `--difficulty`, `--course=` a prefix, `--set=field=value`, `--mistakes`, `--damage`, `--verbose`, `--follow=NAME`, `--extra=DIR` for scratch courses, `--csv`). Knock damage on, weather off. Median finish, 2026-10-12 after the turning courses and the racing fixes, two rounds of eight per preset (home of sixteen, fastest):

| Course | easy | medium | hard | nightmare |
| --- | --- | --- | --- | --- |
| First Splash | 86.5 s (16/16 home, fastest 71.6) | 75.9 s (16/16 home, fastest 69.5) | 75.4 s (16/16 home, fastest 68.2) | 71.2 s (16/16 home, fastest 68.1) |
| Spin Cycle | 73.7 s (16/16 home, fastest 53.2) | 70.5 s (16/16 home, fastest 57.2) | 65.2 s (16/16 home, fastest 51.7) | 62.7 s (16/16 home, fastest 51.6) |
| Big Balls | 91.7 s (16/16 home, fastest 65.5) | 87.6 s (16/16 home, fastest 65.2) | 80.0 s (16/16 home, fastest 65.1) | 65.3 s (16/16 home, fastest 61.7) |
| Punch Alley | 61.0 s (16/16 home, fastest 57.1) | 58.9 s (16/16 home, fastest 56.9) | 57.0 s (16/16 home, fastest 56.9) | 56.9 s (16/16 home, fastest 56.9) |
| Trapdoor Run | 88.9 s (16/16 home, fastest 71.6) | 81.0 s (16/16 home, fastest 68.6) | 75.0 s (16/16 home, fastest 68.0) | 68.6 s (16/16 home, fastest 68.0) |
| Log Roll | 120.9 s (16/16 home, fastest 61.2) | 91.0 s (16/16 home, fastest 65.2) | 82.0 s (16/16 home, fastest 65.3) | 71.8 s (16/16 home, fastest 65.3) |
| The Sweeper | 76.2 s (16/16 home, fastest 57.0) | 72.2 s (16/16 home, fastest 54.8) | 73.1 s (16/16 home, fastest 55.2) | 56.9 s (16/16 home, fastest 55.2) |
| Uphill Belt | 88.5 s (16/16 home, fastest 86.4) | 86.0 s (16/16 home, fastest 85.1) | 85.7 s (16/16 home, fastest 83.9) | 85.3 s (16/16 home, fastest 82.9) |
| Hammer Gauntlet | 83.2 s (16/16 home, fastest 72.7) | 75.6 s (15/16 home, fastest 66.6) | 69.6 s (16/16 home, fastest 66.4) | 66.4 s (16/16 home, fastest 63.3) |
| Grand Tour | 117.9 s (16/16 home, fastest 108.0) | 108.8 s (16/16 home, fastest 97.1) | 108.9 s (16/16 home, fastest 93.2) | 99.8 s (16/16 home, fastest 91.1) |
| Lily Pond | 80.9 s (16/16 home, fastest 71.8) | 72.3 s (16/16 home, fastest 65.0) | 72.0 s (16/16 home, fastest 65.0) | 66.1 s (16/16 home, fastest 65.1) |

A stand-in that never makes a mistake runs each in 56–119 s, each way through a fork (`headless_courses`). Every preset is faster than the one below it on every course but two, where two rounds put hard within a second of medium: The Sweeper (73.1 against 72.2) and Grand Tour (108.9 against 108.8). Over four rounds hard is ahead on both (Sweeper 66.3 against 70.6, Grand Tour 108.4 against 110.4); a median of sixteen moves by a few seconds with one long fall. Uphill Belt is decided by its belts and bouncers, and every preset is within four seconds there. `headless_courses` holds the ordering (a nightmare field of six all home, its median not slower than an easy field's on First Splash).

## Course layout rules the stand-ins taught

The authoring side is in mg-wipeout-maps.

- Every route starts at the middle of the start pad, and restarts and joiners get full-row seats.
- A checkpoint is never in a hazard's reach (the builder refuses it) and sits near the START of plain deck, so a runner put back there has a run-up.
- A run of tops is lined up: a point on the line 3.5 m before the edge.
- Pendulums use `yaw` 0; a conveyor on a ramp takes `pitch`; hammers at least 4.2 m apart and rams 4.5 m.
- A centre spinner ends in four metres of plain deck, so the next jump is not taken sideways out of an arm's reach.
- A stand point before something to board is never behind the run-out's last point.
