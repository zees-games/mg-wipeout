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
