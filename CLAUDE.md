# mg-wipeout

Obstacle courses over water; if two or more sides finish, a final death in a random arena with props to throw and weapons on the floor. It is the family's game whose obstacles are **scripted machinery** (arms, hammers, rams, rides) and whose first phase is about time, not survival: a fall sends you back to the last checkpoint, a knock costs health. The second phase is mg-smash-copter's idea (the good ones finish in a fight) made physical, with props carried by dot-props' gravity gun and weapons found rather than dealt.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and each addon's own before working in it. The courses are the [mg-wipeout-maps](../mg-wipeout-maps) repository's; its `CLAUDE.md` is about authoring them. The reasoning is in [docs/](docs/design.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | the course, obstacles, the wire, rounds, the course vote, damage, weather, the final death, points, delivery |
| [docs/stand-ins.md](docs/stand-ins.md) | the bots: difficulty, racing mistakes, route flags, a field of them, measured times, or a course a bot cannot finish |
| [docs/history.md](docs/history.md) | where this came from, and what running it found |

## Layout

| Path | What |
| --- | --- |
| `game/wo_course.gd` | THE FILE. A document built into pieces; every piece a function of the tick |
| `game/wo_course_doc.gd` | what a course and an arena are: JSON, validated, normalised, sent on the wire |
| `game/wo_catalogue.gd` | every document the server has, one built-in course and arena, which is next |
| `game/wo_game.gd` | the simulation: phases, falls, checkpoints, the finish, weather, the final death, bots, `race_order()` |
| `game/wo_racer.gd` | how a stand-in races: mistake rates and the fork choice (`risk`) per dot-bot preset, `wo_bot_*` cvars |
| `game/wo_announcer.gd` | the show's voice: lines, the announcer, the crowd (client) |
| `game/wo_config.gd` | every rule a course is played under |
| `game/wo_controller.gd`, `wo_player.gd` | `DotFpsController` with the pre/post-simulate hooks; one person: movement, carry/knock, progress, hands |
| `game/wo_rules.gd` | a `DotMatchRules` whose outcome is whatever `WoGame` decided |
| `game/wo_module.gd`, `wo_services.gd`, `wo_server.gd`, `wo_vote.gd` | the `DotGameModule` (cvars, `wo_status` / `wo_courses` / `wo_reload`, stand-ins, delivered courses); chat, voice and moderation over dot-game; the course vote over dot-vote |
| `game/wo_client.gd`, `wo_hud.gd`, `wo_audio.gd`, `wo_figure.gd`, `wo_settings.gd` | the local player, drawing and weather view; HUD; sounds and machinery; watcher figures; dot-menu settings |
| `game/wo_content.gd`, `wo_textures.gd`, `wo_paths.gd`, `wo_avatars.gd` | final-death props; surface roles and tints; `rebase()` for delivery; site avatars |
| `game/net/` | the codec (`STAGE`, `PROGRESS`, `PICKUP`…), the link, two behaviours, the bridge |
| `courses` | a dot-bootstrap link to `../mg-wipeout-maps/courses` (gitignored) |
| `examples/` | `headless_run`, `headless_courses`, `headless_net`, `headless_workshop` (subscribed packs' courses: solo, online, kinds, own ids, the ballot), `dedicated` |
| `tools/` | `soak.tscn` (`./game.sh soak`, [docs/soak.md](docs/soak.md)), `shot.sh`/`shot.gd` (render a view), `trace_course` (where one stand-in falls and why), `race_times` (a field per preset, finish times), `make_sounds.py` (writes `audio/`) |
| `audio/` | the crowd, the horn and the water (synthesised by `tools/make_sounds.py`), the announcer (Kenney, CC0) |

## Running and testing

`./game.sh test` (every suite, with a timeout and the stderr check; `./game.sh suites` lists them). `./game.sh` plays it.

- `headless_courses` runs every course with a stand-in (a course with a fork twice: `wo_bot_risk` 0 and 100) and stands in every arena. It drives ticks **without** waiting on physics frames, legitimate only because every moving piece is a static body written straight into the physics server. It runs with damage and weather off, because it proves a course can be finished.
- `headless_net` proves both ends agree: obstacles at five ticks, the course digest, the final death, a landed shot's HIT to the shooter alone (armed) and the owner's magazine for `correct_drawn`. It also fails on any engine error in its stderr (an `EngineErrors` logger; armed with `WoToyNet.pull`'s out-of-tree guard and dot-net's history #30 both reverted).
- **Every suite frees the previous world before building the next**: they share one physics space and every course is built at the origin.
- `tools/race_times.tscn` (`godot --headless --path . res://tools/race_times.tscn -- --course=wo_first_splash --rounds=2`) is the measure of a course's length and a preset's mistakes; `--verbose` prints every fall, `--follow=NAME` one runner's every tick. [stand-ins](docs/stand-ins.md#measured)
- `tools/shot.sh --view=race --seconds=22`, `--view=crowd`, `--view=duck --wo-course-ids=wo_the_sweeper` (a stand-in ducking an arm, close), `--view=falls`, `--view=course --wo-course-ids=wo_grand_tour`, `--view=finale`, `--view=tiles`, `--view=third --board`, `--view=third --ballot` (the course vote's ballot), `--view=third --console="net_stat 3"` (a line typed at the player's console first). Every view change wants a rendered frame.
- After touching a camera, the view key or player collision: `tools/camera_check.sh` (cameras round every piece, armed; the player walked into another with `mp_solidplayers` both ways; `--render` for frames). [design](docs/design.md#cameras-and-bodies)
- **Arming**: `headless_net`'s obstacle agreement and every suite's total are armed; most other checks are not yet armed one by one. Arm a check before trusting it.

## Rules that bite

- **Instant death is `wo_instant_death` (`WoConfig.instant_death`): a fall into the water, or any death on a course, is out for the rest of the ROUND (`WoPlayer.out_for_round`, across every course of it, cleared in `_on_round_started`), and a course that wants it says so in mg-wipeout-maps' `cfg/<course id>.cfg`.** `WoCourseCfg` applies the file on `world_rebuilt` (server only: solo has no console) and puts back what it changed when the next course loads, unless the operator changed that cvar since; only `wo_` cvars, because a courses pack may be anyone's. The `cfg` directory is a second dot-bootstrap link beside `courses`, found by `WoCatalogue` at `<root>/../cfg`. Armed in `headless_run` (`_test_instant_death`, `_test_course_cfg`).
- **Workshop courses are `WoCatalogue.follow_content`**: a pack's map entry names a course document in `scene`, read on every `playable_courses()`, so solo plays it as `Name [Pack]` and online lists none. Limits in [docs/not-yet.md](docs/not-yet.md). **A pack course takes the same path as an own one** (`WoCourseDoc.parse_json`, then `change_course_now`, `build_stage`, the round), never a scene and never a second loader: a torn document or an arena is `refused`, an own id wins, and online none is listed or choosable. `headless_workshop` starts a round on a fixture course; `tools/shot.sh --view=pack` renders it.

- **Everybody steps (padding underfoot) and the courses have an outdoor bed** (dot-audio's stock, `WoAudio`). Levels are measured with `addons/dot_audio/tools/loudness.sh` (−17 LUFS band, `loudness_trim_db`).
- A dead body falls as dot-player-char's ragdoll: the server picks the fall (`WoGame.decide_death`, on `player.death`), it rides DEATH last and optional, and the client copies it from the figure it draws (`WoClient._fall`). The `sv_ragdoll*` cvars are bound in the module, REPLICATED, and followed by the client. A blow or a blast still knocks the body to pieces (`_break`, this game's own look); anything less leaves a ragdoll. See dot-player-char's [docs/ragdolls.md](../dot-player-char/docs/ragdolls.md).
- **Offline, the client's buttons go onto the world's own sample** (`WoPlayer.command_stamp`, set in `WoClient._adopt`), never onto `controller.current_command`, which `WoPlayer.simulate` samples over: that way no trigger ever reached the world's gun offline. `headless_run`'s "offline, the client's trigger" is armed ([history](docs/history.md)).
- **The drawn gun is only what the server armed** (`WoClient._give_locally` per `player_armed`/ARMED, never `give_everything`, which left a slot holding whatever was given last), counted by dot-ui's `DotAmmoCounter` bottom right (`WoHud._draw_ammo`) and brought to the server's count after `DRAWN_SETTLE_SEC` quiet (`WoClient.correct_drawn`: owner-only snapshot fields online, the world's rig offline). A hit is the server's word (`WoGame.hit_landed` from each weapon shot's damages, HIT to the shooter alone): `DotHitMarker` and zee's red burst on the body (`play_body_hit`, by `has_method`). `headless_run`'s "an armed racer draws the server's gun" is armed.
- **Every key is a `WoBindings` row read through its action**, never a keycode (Escape excepted); H is help (dot-menu's stock key; `WoSettings._fill_help` writes the rules), so no row may default to H. `headless_run` checks it and the Escape menu's Help and Leave.
- **M is the course list** (dot-menu's map menu): `WoGame.course_rows()` and `change_course_now()` (the next course plus dot-match's `begin_round_now`) serve both solo and the server, where dot-vote's map menu lets the owner's `sv_map_menu_flag` change it now and gives anybody else a vote. No row may default to M; `headless_run` and `dedicated` check it.
- Where an obstacle is at tick N is a formula both ends evaluate; nothing about the course is replicated after `STAGE`. Anything new that moves, warns, sounds or blows must be a function of the tick too. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Pose the course at the tick being simulated in `_on_pre_simulate`, including prediction replays. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Hazards are measured analytically, never collided; carriers are solid and move riders by exact displacement. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Moving pieces are static bodies written through `PhysicsServer3D.body_set_state`, never `AnimatableBody3D`. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- The normalised document is the course; the validator floats every weather number so a round trip is byte-identical. [design](docs/design.md#decision-2-the-course-travels-whole)
- The warmup's course is round one's; do not draw a new one at `start()`. [design](docs/design.md#decision-2-the-course-travels-whole)
- The game decides the round (`WoRules` CUSTOM); solo sides start at `SOLO_SIDE_BASE` and are varints. [design](docs/design.md#decision-3-a-round-is-decided-by-the-game-not-by-dot-match)
- Knock damage is charged on the authority; a course elimination must count as off the course or the round runs its clock. [design](docs/design.md#damage-on-the-course)
- **A READY before the player is seated is kept** (`_ready_unseated` in the bridge) and answered by `add_player`: over ENet with loss it overtakes the link's `loaded`, and a dropped READY left the client waiting for ever. `headless_net` sends it first (armed). [history](docs/history.md)
- The grab key is in `WoNetCommand`, not `DotFpsCommand`'s spare buttons; the gravity gun runs on the server only. [design](docs/design.md#the-final-death)
- `game.yml` names no courses pack (it sets `maps_delivery: client`, so the owner's maps pack also reaches every client for its `worlds/` meshes; `WoWorld.fetch` asks for one course's mesh group once a pack publishes groups, nightly `wipeout-mesh-groups`); a server owner names mg-wipeout-maps in their map config. Re-add delivered courses after `wo_reload`. [design](docs/design.md#delivery-the-courses-are-a-second-pack)
- Every `res://` string naming the game's own files goes through `WoPaths.rebase()` (the family's delivery rule; [dot-server-deploy](../dot-server-deploy/docs/delivery-constraint.md)).
- A route flag is earned by a traced failure; `onward` is opt-in per point. [stand-ins](docs/stand-ins.md)
- A course with a fork is format 2 (`branch`/`risky` on route points); walk the route with `WoCourse.route_next`/`route_prev`, never `index + 1`, and order a race by `route_progress`, never by index. [design](docs/design.md#courses-that-turn-climb-and-fork)
- Nothing assumes a course runs down −Z: positions come from the document, directions from the route or the runner. [design](docs/design.md#courses-that-turn-climb-and-fork)
- A stand-in hops only what a metre up clears, takes a hop that lands beyond an edge's gap as the jump, measures a landing's overshoot along the jump's line, and never backs up on a turntable. [stand-ins](docs/stand-ins.md#the-route-flags)
- A stand-in sets off onto trapdoor tiles only when the whole crossing is clear (`WoCourse.tile_crossing_clear`), down a column it claimed on the deck and then the one under its feet; tile to tile is a step, never a jump, and it never walks across a row. `race_times --verbose` prints crossings per column and tile falls. [stand-ins](docs/stand-ins.md#the-route-flags)
- Stand-ins are on the `bot` collision layer and pass through each other; a person is solid to them. Never put a stand-in on `player` or a stand-in's mask on `bot`. [stand-ins](docs/stand-ins.md#a-field-of-them)
- A stand-in's difficulty is dot-bot's `bot_difficulty`; racing mistakes are `WoRacer` columns (`wo_bot_*`), every draw per bot, point and attempt (never per round: a fumble drawn per round was fumbled for ever). `bot_mistakes 0` only in the course suite. [stand-ins](docs/stand-ins.md#how-a-stand-in-races)
- **A round runs `courses_per_round` courses (`wo_courses_per_round`) while more than one side finishes each**; `_begin_next_course` re-lays the course, places everybody and heals them, points kept, and the final death follows the last. One finisher or none ends the round at once. **Health is `health_enabled` (`wo_health`)**: knocks, lightning and hard landings (`fall_safe_height`, `fall_damage_per_metre`, charged in `_watch_landing`) all go through `_hurt_on_course`, which records `health_before`; a knockout at or under `knockout_fling_below` of full health gets the `WoGame.FLING` ragdoll reaction (registered on both ends by `death_reactions()`), pushed harder the lower the health. Every amount is a `wo_*` cvar. Suites that need one course and then a final death set `courses_per_round = 1`; `headless_run` arms the course count, the damage and the fling.
- A knock is charged at most once a second and a fall heals; a checkpoint is never in a hazard's reach (mg-wipeout-maps' builder refuses it). [design](docs/design.md#damage-on-the-course)
- The dressing (stands, crowd, screens, flags, confetti) and the announcer are client side; a server builds none of it, and an unknown dressing kind is dropped, never refused. [design](docs/design.md#the-show)
- The course vote opens `wo_vote_after` into a course and applies at the round's end (MANUAL, `END_OF_ROUND`), rocked votes too; under MANUAL `WoVote` opens a passed rock-the-vote itself, or `!rtv` does nothing. The match answers dot-vote's `round_in_progress_fn` (`world.match_node.is_live()`, set by name because an older shell's dot-vote lacks it), so a `time_up: finish_round` limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`; `dedicated` checks both halves. [design](docs/design.md#the-course-vote)
- **A seat behind its loading cover is not harmed** (dot-game's "still loading"): `WoGame.harm_gate`, set by the module from `can_peer_be_harmed`, is asked in the combat resolver's `adjust` (every knock, landing, blast, thrown prop, shot and the arena's water), so it cannot be hurt or eliminated; admin slay/slap carry `context.admin` and pass. On a course a fall puts it back at its checkpoint without counting a fall, and the finish does not count it across. The course clock is shared and does not wait for it. `dedicated` checks it over a real socket; `tools/render_cover.sh` renders the cover and the frame after it lifts. A death on a course revives at once, so a test proves one with `player_died`, not health.
- The HUD follows the menu's theme and HUD size (`WoHud.follow_menu`, dot-menu's `follow_hud` by name); `WoHud.piece_theme()` is the accent only (amber highlight and edge), never plate, text or ink, and the HUD's Labels set no colour of their own except the accent lines. `headless_run` checks a theme change reaches the pieces and the lines.
- **Toys are dot-props' loose ones only** (start pen, arenas), on the `toy` layer no person collides with; a client registers their mirrors on TOYS whether its stage is built or not. [design](docs/design.md#toys)
- Set the audio listener before the machinery plays, or the manager culls everything by distance from the origin. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Only moving pieces and hazards keep a colour tile; every other role is the light grid under a pastel (`WoTextures.INSTALLED_TINTS`). The light is a dot-lighting document from the course theme (`WoCourse.light_document`), turned down under Compatibility; still boxes and the start pen get dot-lighting's `DotContactShade` (`_add_contact_shade`). [design](docs/design.md#colour-and-light)
- `project.godot` carries no comments: the editor drops them, and any key left at its default, the first time it saves the file, so the reasons for its settings live here. Gravity stays the engine default and nothing reads it: `WoConfig.gravity` is written onto the world's own physics space, because a project setting does not travel inside a delivered pack. The renderer is `gl_compatibility`, what the delivered client runs, and lighting is tuned under it. The canvas texture filter is Nearest so the prototype grid reads as discrete squares from forty metres up, where a player judges a platform's tilt. Texture imports keep `detect_3d/compress_to=0` (`[importer_defaults]` starts new ones that way) so the editor never re-imports one VRAM-compressed on a first open.

## Open items

- **Course levels for the nightly quota**: see mg-wipeout-maps' CLAUDE.md for what a level is here.
- The crowd and announcer have not been heard in a browser build.
- Most checks are not armed one by one yet.
- The carrying pose is checked by `headless_run` but not rendered: staging a stand-in mid-carry in the shot tool is its own job.

- **Imported courses use the `world` and `kill` piece kinds.** `world` (`game/wo_world.gd`) builds a dot-map mesh from `<root>/../worlds/<mesh>.json` (the `worlds` bootstrap link beside `courses`) with hull collisions; `kill` is a box that counts as a fall (`WoCourse.in_kill`). `mg-wipeout-maps/tools/import_world.py` writes them; its spec's `hidden` and `attached` list brush models to skip. Online clients read the mesh from the mounted maps pack (`game.yml` `maps_delivery: client`; `WoWorld.prefix_of` scans `res://dot_cloud/*/*/worlds/`; `headless_net` arms it). Plan: mg-wipeout-maps `docs/import-plan.md`.
