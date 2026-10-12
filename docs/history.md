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
