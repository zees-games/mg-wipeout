# History

Built in one session from mg-smash-copter's skeleton (module, services, wire, client, HUD, spectate, progress, avatars, figure, beacon), renamed `sc` → `wo` and rewritten wherever they named a platform, the cannon or the chopper. Where a comment says "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here; that repository has the long version.

## What running it found

- **The start gate never dropped**, in the suite only: a previous world's closed gate stood in the same physics space, at the origin where every course is built. Every suite now frees the previous world before building the next.
- **A kinematic body moves a step late**, found by the course suite seeing turntables still at the origin. Moving pieces are static bodies now ([design.md](design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)).
- **Glossy water is the sky**: the first render had no horizon. The water is darker and matte.
- **The final death was fought on a magenta floor**: the prototype set's purple under the arenas' warm sun. The arena is the light deck tinted lavender (`WoTextures.INSTALLED_TINTS`).
- **The course was introduced twice at every boot**, in chat and on screen, by the warmup build and `start()`'s rebuild.
- **A storm under a bright sky**: rain was first drawn out of full sunlight; the sun now dims to under half in a storm (the sky material's own colours are still bright).
- **A pickup in a second slot holstered for ever**: dot-weapon's endless switch, fixed there.
- **The machinery check passed with its guard removed** until its time jump was chosen to cross a bearing; a longer jump aliased both arms back to their own side.
- **Offline, the player's gun never fired in the world (2026-10-12).** `WoClient._drive_offline` stamped fire and reload onto `controller.current_command`, and the world's tick then ran `WoPlayer.simulate`, which applied a fresh `sampler.sample()` over it: the drawn gun animated, the world's rig never saw a trigger, and no shot landed. Found in game-zombie-zone's first play test (the counter read 15 / 60 for the whole video) and then measured here: a forced-phase probe left the world's pistol at 15 after five pulls, 10 with the fix. The buttons go onto the sample through `command_stamp` now.

## The first play test's courses and stand-ins (2026-10-12)

Christian's first play test finished First Splash in 22 s on a first try against three stand-ins, one called "Stand-in 2", with nothing round the course but sea. The courses were rebuilt four to six minutes long with stands on five of them, the stand-ins became a field of eight racing on dot-bot's difficulty, and `tools/race_times` was written to measure them. What measuring found:

- **A fumbled jump was fumbled for ever.** The fumble was drawn once per bot, route point and ROUND, so a stand-in that missed a jump missed it again on every attempt and never got past it. It is drawn per attempt now (`falls` in the seed).
- **A checkpoint inside a sweeper's arc.** First Splash put the restart 1.6 m from the end of a deck whose arm reached past it: a stand-in was knocked in again as it stood up. mg-wipeout-maps' builder refuses a checkpoint in any hazard's reach, and puts checkpoints near the start of plain deck (`safe`).
- **Eight solid stand-ins were a crowd, not a race.** They shoved each other off edges and landed on each other on balls; a field of eight took four times as long over five balls as two did. Stand-ins are on a collision layer of their own and pass through each other; a person is still solid to them.
- **Landing brakes pushed runners off the line.** The air brake wished straight back along the line to the target; for a runner half a metre off it, that wish had a sideways part away from the line, and they drifted four metres wide of the ball. It brakes against the velocity now, aiming a little past the top.
- **The jump off a ball went on the landing tick**, while the velocity was still the jump's seven metres a second; the curve had already taken it to four, and every second ball was short. A top is never jumped from on the tick of landing, and the run on it is to the speed the next jump needs.
- **Tiles were taken at a run and only down the middle.** A running jump onto a row of trapdoors lands two rows on, and waiting on the middle tile for the one ahead is waiting for yours to drop. Tiles are walked onto, and a stand-in steps to whichever column will be up.
- **Knocks killed pinned runners.** A ram holding somebody against its stop re-throws them every few ticks; charged each time, half a field was knocked out of Punch Alley in a second each. A knock is charged at most once a second, and a fall heals.

## Courses that turn, and the stand-ins that ran them (2026-10-12)

Every course ran down one straight line. mg-wipeout-maps' builder learned frames (turns, curves, kinks, switchbacks, a spiral climb, ramps up and down) and forks, and nine of the eleven courses were rebuilt round them. Running fields of eight round the new shapes, and round Spin Cycle where hard and nightmare had been no faster than medium, found:

- **A landing's overshoot was measured toward the target.** A jump that came level with a pad beside it counted nothing as past and stopped braking: hard and nightmare stand-ins came down on Spin Cycle's second pad at its rim and jumped short of the third. Measured along the velocity instead, sideways drift counted as past and braked short of balls. It is measured along the jump's own line now, and a top is braked to within 5 cm.
- **Better hoppers fell more on Punch Alley.** The hop jumped anything about to hit, rams included, and a ram meets a hop in the air; hard was slower than medium there. A hop now needs a metre up to be clear, which only a low arm is.
- **Turned, a section that passed failed.** Big Balls' balls turned to run along X lost a clean runner eight times on the second ball: the landing came down 0.7 m past on the ball's curve. Straight, the same numbers had been just inside it.
- **A spinner turning with its disc** (40 against 50 degrees a second) sat its arms on riders and put a field of sixteen in the water seventeen times. The builder refuses one within 60.
- **Backing up for a run-up on a turntable** stood bots in a spinner's arms; not backing up on a seesaw jumped them short of the next plank. Only turntables are exempt.
- **Tiles are the risky branch nobody's skill wins.** A field crowds onto one trapdoor and goes down with it whatever its preset, so the hardest stand-ins, who take the risk most, came last on Trapdoor Run until its risky branches became jumps and pads. Timing the step onto a tile at the walk made it far worse (a nightmare field finished none of sixteen) and was taken out.
- **A READY that overtook the seat was dropped (2026-10-12).** A client sends READY when its link says PLAYING, which the link decides itself after sending `loaded` on another ENet channel. Through a lossy link the READY can reach the server first; `_admit` found no player for the peer and returned, and nothing asked again, so that client never got a world. Loopback and WebSocket order the two, so no suite could see it until `headless_net` sent the READY before the seat.

## Trapdoor tiles were timing, not crowding (2026-10-12)

A field of stand-ins went down with one trapdoor together, and it looked like crowding (they pass through each other, so a waiting field stood on one tile). Claiming a column each spread them out and made it worse. Following single runners tick by tick found timing:

- **The board check asked about the wrong moment.** "Will the tile be there?" was asked at the distance over the RUN speed plus an eighth of a second; the stand-in walks onto tiles and jumps, so it arrived about a second later. And it asked only that the next tile be there for a quarter of a second after landing: the runner then stood on it waiting for the row after, and went down with it. The whole crossing is searched forward now (`WoCourse.tile_crossing_clear`).
- **The edge jump fired between rows when the tile ahead was down.** The gap between two rows is a stride; the jump came only from "nothing under the next metre and a half", which between rows means a dropped tile, and a walk's jump over a hole lands in it. Tile to tile is stepped now, and a dropped tile ahead is waited for.
- **Margins that add up.** Reckoning a slow start onto every row of a straight run made Trapdoor Run's last grid uncrossable in every column; the start is reckoned only after a stop.
- **Two of that grid's three columns can never be crossed straight.** Its third row comes back up just as its second drops, so a runner who keeps to the column has a window of a tenth of a second. Stand-ins only claim columns that can be crossed (`tile_column_crossable`).
- **A stale unstick mark jumped a waiting stand-in from a standstill** onto the mover after the first grid, three of a field together, once the tile timing changed when they reached it. The mark is only trusted for a second and a half.

A mistake-free nightmare field went from 1.25 tile falls a run (four rounds of eight on Trapdoor Run) to none; with mistakes, easy from 1.72 to 0.25 and nightmare from 0.84 to none.


## Dead tile columns, and nightmare behind hard on Spin Cycle (2026-10-13)

- **A column that is clear a sixteenth of a second at a time is not clear.** Trapdoor Run's last grid (seed 53) had two columns no runner who kept to them could cross, its turned grid one, and First Splash's and Grand Tour's grids one each; a field crossed the last grid in one column, 32 times of 32. mg-wipeout-maps' builder now ports `WoCourse.tile_crossing_clear` and refuses a grid with a column clear for under half a second on end, asked every tick from the stand point and from 1.5 m behind it. The first reseed passed a share-of-a-period test (37% for a column) and nobody crossed that column: its moments came two ticks at a time, a stand-in saw one, started walking and the next tick it was gone. After the reseed every column of every grid is crossed (nightmare on the last grid: 6, 19, 7).
- **Nightmare was behind hard on Spin Cycle because the field ran in step.** Nearly mistake-free stand-ins arrive together and meet the same arm together, so the course's holes in the bot showed most in the best preset: a mistake-free field fell 1.5 times a run. Three holes, each traced: a hop short of an edge's jump point was braked in the air back onto the point and came down in the gap (now the hop is the jump when it lands beyond the gap); a runner the hop stopped for an arm took off anyway from a tick of braking (no take-off from that stop); and a hop that came down just past an edge's point took off facing the point, backwards, into the gap (it faces along the jump's line while still going on). A mistake-free field now falls 0.6 times a run there, and nightmare (55.2) is ahead of hard (57.7).
- **Two fixes that measured worse were taken out.** Stopping short of an edge when the landing would be in an arm (`_bot_landing_swept`) helped Spin Cycle and put nightmare behind hard on The Sweeper; facing along the jump line for a runner going back put The Sweeper's easy field ahead of medium. Measure every course after a stand-in change: a field in step makes a small change move a median by seconds.
