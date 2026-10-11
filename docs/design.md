# Design

## Decision 1: an obstacle is a pure function of the tick

mg-smash-copter's platforms are a spring the server integrates and replicates, because what they do depends on who stands on them. Nothing here does. An arm turns at a speed, a mover eases with a period, a tile drops on a schedule hashed from its index, so **where every obstacle is at tick N is a formula both ends evaluate, and nothing about the course is replicated after the document arrives**. A client predicting its own player poses the course at the tick it is simulating, first (`WoController._on_pre_simulate`, which runs during prediction replays too), so a jump over a sweeping arm lands or fails identically on both ends. `headless_net`'s "every obstacle is where the server has it" asserts it from both ends.

**Hazards are not solid to a player; carriers are.** A swept capsule meeting a body that moved into it between ticks is resolved by depenetration, which is order-dependent and differs between machines. So spinners, pendulums and pushers are measured analytically against the player's capsule (`WoCourse.knock`: segment–segment for an arm, point–segment for a ball, sampled box for a ram) and throw at the surface's own speed, clamped to `knock_min_speed`..`knock_max_speed`, plus `knock_lift`. Movers, turntables, rollers, seesaws, belts and tiles are solid, and whoever stands on one is moved by `WoCourse.carry`: the exact displacement `pose(t+dt)·pose(t)⁻¹·p − p`, not velocity times step, or a player standing still on a turntable spirals off it.

**Moving pieces are STATIC bodies, teleported, never `AnimatableBody3D`.** Godot's physics server applies a new transform to a kinematic body only at its next step (the first lands at once, later ones wait), so a client replaying six predicted ticks in one frame would sweep all six against obstacles a frame old. A static body's transform, written through `PhysicsServer3D.body_set_state` as well as the node (`WoCourse._place`), applies immediately. A frame posed between ticks (`pose_at_time`, client drawing) forgets its cached tick so the next `pose_at(N)` re-poses.

Everything derived from the tick follows the same rule and never goes on the wire:

- **Tells**: a drop-tile is red for `WoCourse.TILE_WARN_SECONDS` (0.6 s) before it drops (`tile_warning`). A `high_sweeper`'s arms pass above a crouch and below a standing head.
- **Weather** is drawn once per round into the course document (`WoGame.draw_weather` into `doc["weather"]`): gusts (`wind_chance`, `wind_strength`) and lightning at drawn spots and ticks (`storm_chance`, `storm_strikes`, `strike_radius`, `strike_damage`) are pure functions of the tick in `WoCourse.wind` / `strike`, applied in the player's own predicted tick.
- **The machinery is heard** on the client, once a frame (`WoAudio.present_machinery(course, seconds, listener)`): an arm crossing the listener's bearing from its hub is a whoosh, a hammer through the bottom of its swing a whoosh, a ram at full reach a thump, a tile's warning a rattle. A jump in time (more than 0.25 s, or a new stage via `reset_machinery`) only remembers the time, or every arm would be heard at once. Which side of the bearing is a bool, not `signf` (`signf(0)` matches neither side). The listener must be set before the audio manager culls by distance. The sounds are synthesised into dot-audio's bank under the id and path a file would have, so an `.ogg` still wins.

## Decision 2: the course travels, whole

A course is a JSON document (`WoCourseDoc`); the server reads documents from `courses/` and sends the **normalised** one in `STAGE` (deflated, both lengths in a header, refused rather than decompressed when torn). A client needs no course files and cannot disagree about where a deck is. The client validates what it receives, so a client a format behind refuses with a sentence. `headless_net` checks the client's course digest equals the server's.

- **The document validator turns every weather number into a float**: JSON has one number type, and an int tick came back as a float and broke "the same document, to the byte".
- **The warmup's course is round one's.** `_ready` lays a course out (a world is never empty), `start()` rebuilds the same one (on a server the bridge exists only by then, so this is the build clients are sent), and the first round keeps it (`_course_unplayed`); later rounds draw the next, seeded, never the same twice running. `start()` rebuilds the warmup course only if the catalogue still offers it. `WoClient._on_stage` introduces a stage at most once per five seconds, because both rebuilds announced it.

## Decision 3: a round is decided by the game, not by dot-match

`WoRules` returns CUSTOM when `WoGame` has decided, with the winner it decided; its only clock is a backstop (`countdown + course + handover + finale + 60 s`), so a round the game never decided still ends and dot-match does not warn at boot. **Solo is the default**: each player is a side of their own, numbered from `SOLO_SIDE_BASE` (100), so `team_of` gives dot-combat distinct sides (friendly fire is off, and everybody on side 0 would be team-mates). Sides are varints on the wire.

Course closed → `finishing_sides()`: two or more → handover into a drawn arena (spawn areas shuffled per round, positions drawn inside them, props and weapons drawn across the drop areas, non-finishers into the gallery, everybody invulnerable for `handover_seconds`); one → that side; none → the furthest checkpoint (`progress_decides`), else a draw. Final death: the last side with anybody up and not watching; on the clock, most people up, else a draw.

## Damage on the course

A knock costs health by how hard it threw you (`knock_damage_per_speed`, 1.0: a slow arm 8, the hardest throw 22; at 1.4 a stand-in was out before its first checkpoint), charged on the authority when it notices the knock, since the throw is predicted. **Health that runs out on the course ends the round for that player** (`course_deaths_eliminate`): alive again at once, watching from the lounge, and `_course_is_over` counts them as off the course or a round with an elimination would always run its clock. Off, it is a restart from the last checkpoint. A checkpoint heals (`checkpoint_heals`). A death breaks the figure on the client (dot-player-char's `DotPlayerBodyBreak`), seeded from the player so every client agrees, mended 1.2 s later.

## The final death

- **Props are carried with dot-props' `DotGravGun`, one per player, server-side only.** The grab key rides in this game's own `WoNetCommand` (`grab`), because `DotFpsCommand`'s three spare buttons are fire, alt-fire and reload; the server turns the held state into an edge. Fire while carrying throws (`throw_impulse`). A thrown prop hurts by momentum (`throw_damage_per_impulse`) for three seconds, once per prop per 20 ticks, credited to the thrower.
- **A carrier is drawn carrying**: `WoPlayerNet.net_carrying` is one bit (the gun runs only on the server), `WoPlayer.is_carrying()` asks the gun where it runs and the bit where it mirrors, and `WoFigure` raises both arms.
- **Weapons are found**: pickups on the floor (`PICKUP`/`PICKUP_GONE` events), taken by standing on them, which builds a `ZeeWeaponRig` the first time (`WoGame.arm`). The client draws each as zee's world model, spinning, with a light under it. Watchers see the weapon in the figure's hand (`WoFigure`, from mg-smash-copter), read off the rig for a simulated player and off `WoPlayer.dealt` for a mirrored one.

## Points and the Tab board

`WoPlayer.points` add up over a match: `finish_points` by place (10, 7, 5, then `finish_points_rest` 3) and `winner_points` (10) for the round's winning side, on the authority. `net_points` and `net_ping` replicate; the module copies each session's dot-server `ping_ms` onto its player. Tab holds dot-menu's `DotMenuScoreboard` with this game's columns (avatar, name, points, place or "out", time, ping). The avatar is the figure's head rendered once per skin into a small SubViewport (`WoClient._portrait`), because every person is the same mesh and a few atlases cover every player.

## Delivery: the courses are a second pack

The game's pack does not contain `courses/` (a link, excluded in the pack). mg-wipeout-maps is published as its own pack and **`game.yml` does not name it**: a server owner names it in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills `DotGameDescriptor.maps`), so which courses a server runs is the owner's choice, not a release of this game. Copying the documents into the game's pack loses: a new course would be a game release and a shell rebuild for every server.

`WoModule._add_delivered_courses` asks dot-game's `DotGameContent.map_dirs(server, "courses")` for every pack the server names (its maps, then any legacy `server_dependencies`) and adds each mount's `courses/` to the catalogue before `world.start()` and again after every `wo_reload` (which forgets everything). A server with no maps pack plays `wo_practice` and logs it; dot-server-deploy's `examples/wipeout_client.tscn` exists to catch that.
