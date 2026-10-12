# mg-wipeout

Obstacle courses over water; if two or more sides finish, a final death in a random arena with props to throw and weapons on the floor. It is the family's game whose obstacles are **scripted machinery** (arms, hammers, rams, rides) and whose first phase is about time, not survival: a fall sends you back to the last checkpoint, a knock costs health. The second phase is mg-smash-copter's idea (the good ones finish in a fight) made physical, with props carried by dot-props' gravity gun and weapons found rather than dealt.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and each addon's own before working in it. The courses are the [mg-wipeout-maps](../mg-wipeout-maps) repository's; its `CLAUDE.md` is about authoring them. The reasoning is in [docs/](docs/design.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | the course, obstacles, the wire, rounds, the course vote, damage, weather, the final death, points, delivery |
| [docs/stand-ins.md](docs/stand-ins.md) | the bots, route flags, or a course a bot cannot finish |
| [docs/history.md](docs/history.md) | where this came from, and what running it found |

## Layout

| Path | What |
| --- | --- |
| `game/wo_course.gd` | THE FILE. A document built into pieces; every piece a function of the tick |
| `game/wo_course_doc.gd` | what a course and an arena are: JSON, validated, normalised, sent on the wire |
| `game/wo_catalogue.gd` | every document the server has, one built-in course and arena, which is next |
| `game/wo_game.gd` | the simulation: phases, falls, checkpoints, the finish, weather, the final death, bots |
| `game/wo_config.gd` | every rule a course is played under |
| `game/wo_controller.gd`, `wo_player.gd` | `DotFpsController` with the pre/post-simulate hooks; one person: movement, carry/knock, progress, hands |
| `game/wo_rules.gd` | a `DotMatchRules` whose outcome is whatever `WoGame` decided |
| `game/wo_module.gd`, `wo_services.gd`, `wo_server.gd`, `wo_vote.gd` | the `DotGameModule` (cvars, `wo_status` / `wo_courses` / `wo_reload`, stand-ins, delivered courses); chat, voice and moderation over dot-game; the course vote over dot-vote |
| `game/wo_client.gd`, `wo_hud.gd`, `wo_audio.gd`, `wo_figure.gd`, `wo_settings.gd` | the local player, drawing and weather view; HUD; sounds and machinery; watcher figures; dot-menu settings |
| `game/wo_content.gd`, `wo_textures.gd`, `wo_paths.gd`, `wo_avatars.gd` | final-death props; surface roles and tints; `rebase()` for delivery; site avatars |
| `game/net/` | the codec (`STAGE`, `PROGRESS`, `PICKUP`…), the link, two behaviours, the bridge |
| `courses` | a dot-bootstrap link to `../mg-wipeout-maps/courses` (gitignored) |
| `examples/` | `headless_run`, `headless_courses`, `headless_net`, `dedicated` |
| `tools/` | `shot.sh`/`shot.gd` (render a view), `trace_course` (where a stand-in falls and why) |

## Running and testing

`./game.sh test` (every suite, with a timeout and the stderr check; `./game.sh suites` lists them). `./game.sh` plays it.

- `headless_courses` runs every course with a stand-in and stands in every arena. It drives ticks **without** waiting on physics frames, legitimate only because every moving piece is a static body written straight into the physics server. It runs with damage and weather off, because it proves a course can be finished.
- `headless_net` proves both ends agree: obstacles at five ticks, the course digest, the final death.
- **Every suite frees the previous world before building the next**: they share one physics space and every course is built at the origin.
- `tools/shot.sh --view=course --wo-course-ids=wo_grand_tour`, `--view=finale`, `--view=tiles`, `--view=third --board`, `--view=third --ballot` (the course vote's ballot), `--view=third --console="net_stat 3"` (a line typed at the player's console first). Every view change wants a rendered frame.
- **Arming**: `headless_net`'s obstacle agreement and every suite's total are armed; most other checks are not yet armed one by one. Arm a check before trusting it.

## Rules that bite

- **Every key is a `WoBindings` row read through its action**, never a keycode (Escape excepted); H is help (dot-menu's stock key; `WoSettings._fill_help` writes the rules), so no row may default to H. `headless_run` checks it and the Escape menu's Help and Leave.
- Where an obstacle is at tick N is a formula both ends evaluate; nothing about the course is replicated after `STAGE`. Anything new that moves, warns, sounds or blows must be a function of the tick too. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Pose the course at the tick being simulated in `_on_pre_simulate`, including prediction replays. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Hazards are measured analytically, never collided; carriers are solid and move riders by exact displacement. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Moving pieces are static bodies written through `PhysicsServer3D.body_set_state`, never `AnimatableBody3D`. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- The normalised document is the course; the validator floats every weather number so a round trip is byte-identical. [design](docs/design.md#decision-2-the-course-travels-whole)
- The warmup's course is round one's; do not draw a new one at `start()`. [design](docs/design.md#decision-2-the-course-travels-whole)
- The game decides the round (`WoRules` CUSTOM); solo sides start at `SOLO_SIDE_BASE` and are varints. [design](docs/design.md#decision-3-a-round-is-decided-by-the-game-not-by-dot-match)
- Knock damage is charged on the authority; a course elimination must count as off the course or the round runs its clock. [design](docs/design.md#damage-on-the-course)
- The grab key is in `WoNetCommand`, not `DotFpsCommand`'s spare buttons; the gravity gun runs on the server only. [design](docs/design.md#the-final-death)
- `game.yml` names no courses pack; a server owner names mg-wipeout-maps in their map config. Re-add delivered courses after `wo_reload`. [design](docs/design.md#delivery-the-courses-are-a-second-pack)
- Every `res://` string naming the game's own files goes through `WoPaths.rebase()` (the family's delivery rule; [dot-server-deploy](../dot-server-deploy/docs/delivery-constraint.md)).
- A route flag is earned by a traced failure; `onward` is opt-in per point. [stand-ins](docs/stand-ins.md)
- The course vote opens `wo_vote_after` into a course and applies at the round's end (MANUAL, `END_OF_ROUND`), rocked votes too; under MANUAL `WoVote` opens a passed rock-the-vote itself, or `!rtv` does nothing. The match answers dot-vote's `round_in_progress_fn` (`world.match_node.is_live()`, set by name because an older shell's dot-vote lacks it), so a `time_up: finish_round` limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`; `dedicated` checks both halves. [design](docs/design.md#the-course-vote)
- Set the audio listener before the machinery plays, or the manager culls everything by distance from the origin. [design](docs/design.md#decision-1-an-obstacle-is-a-pure-function-of-the-tick)
- Only moving pieces and hazards keep a colour tile; every other role is the light grid under a pastel (`WoTextures.INSTALLED_TINTS`). The light is a dot-lighting document from the course theme (`WoCourse.light_document`), turned down under Compatibility. [design](docs/design.md#colour-and-light)
- `project.godot` carries no comments: the editor drops them, and any key left at its default, the first time it saves the file, so the reasons for its settings live here. Gravity stays the engine default and nothing reads it: `WoConfig.gravity` is written onto the world's own physics space, because a project setting does not travel inside a delivered pack. The renderer is `gl_compatibility`, what the delivered client runs, and lighting is tuned under it. The canvas texture filter is Nearest so the prototype grid reads as discrete squares from forty metres up, where a player judges a platform's tilt. Texture imports keep `detect_3d/compress_to=0` (`[importer_defaults]` starts new ones that way) so the editor never re-imports one VRAM-compressed on a first open.

## Open items

- **Course levels for the nightly quota**: see mg-wipeout-maps' CLAUDE.md for what a level is here.
- Most checks are not armed one by one yet.
- The carrying pose is checked by `headless_run` but not rendered: staging a stand-in mid-carry in the shot tool is its own job.
