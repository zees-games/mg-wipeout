This is a game to demonstrate the capabilities of the [**GameSpice collection**](https://gamespice.net) built on-top of [Godot 4](https://godotengine.org/) and [**GameSpice**](https://gamespice.net). In this 3D game, players race across obstacle courses built over water: sweeping arms, big balls, rolling logs, swinging hammers and floors that drop away. Fall in and you go back to your last checkpoint. If more than one player (or team) makes it to the finish, they fight it out in a random arena with props and weapons until one is left standing. This is inspired by the obstacle-course game shows on TV!

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with GameSpice, you will need to build and integrate your own back-end infrastructure.

This game was built with Claude Code and has had little testing with real players, so please report anything odd you run into.

## How it plays
Everybody starts on the same pad behind a gate. When the gate drops, run, jump, time the arms, wait out the waterfalls and ride the moving platforms. Falling in sends you back to your last checkpoint, and an arm that catches you throws you, usually into the water. Red tiles are about to drop, dripping water is about to pour, and a high arm is one to duck under rather than jump. A course is a minute to two for a good run.

Some courses are a big night out: grandstands full of people down both sides, light towers, flags and big screens with the leaders on them. An announcer counts you down and calls the race (who takes the lead, who goes in, who wins), and the crowd gasps, cheers and jumps to its feet.

Solo you race eight bots by default. They make the mistakes people make: a jump taken a moment late off an edge, a window gone through as it closes, an arm not jumped, a slide off a ball. `bot_difficulty easy`, `medium` (the default), `hard` or `nightmare` at the console, or `-- --bot_difficulty hard` at launch; `-- --bots 4` races four.

The course closes when everybody is across or the clock runs out. Then:

- **Nobody finished:** whoever got furthest wins (or it's a draw, with `wo_progress_decides 0`).
- **One player or team finished:** they win.
- **Two or more finished:** the **final death**. The finishers are dropped into a random arena while props and weapons land on its floor. Pick props up with **E** and throw them, or walk over a weapon to take it. Fall out of the arena and you're out. Everybody else watches from the gallery. Out of the final death, **G** hands you a free camera (move keys fly, Sprint fast, Walk slow) and takes you back to the players; operators switch it off with `mp_freeroam 0`, and `mp_forcecamera` 1 or 2 (or the older `wo_spectate_camera`) restricts the camera, which turns roaming off.

There are beach balls to bat about in the start pen while the gate is up, and balls on most arenas' floors to shoot about and knock into the water. You walk through them and push them, so they never slow you down or hide anybody.

Every player is their own side by default. `wo_teams 2` (the setting accepts 0, or any count of 2 or more; past six the teams get generated colours and names) plays in teams, and a team is through if anybody on it finishes.

The courses live in their own repository, [mg-wipeout-maps](https://github.com/zees-games/mg-wipeout-maps): at the time of writing 21 courses and five arenas, each a JSON file. Without it the game still runs, on one practice course built in.

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Run and look |
| **Space** | Jump |
| **Shift** | Walk (for beams and the tops of balls) |
| **Ctrl** / **C** | Crouch, under a high arm |
| **E** (hold) | Pick up or put down a prop |
| **Mouse 1** | Throw what you are holding, or fire |
| **Mouse 2** / **R** / **1**-**5** | Alt-fire / reload / weapon slots |
| **Q** | Throw the gun in your hand |
| **Y** / **U** | Chat / chat to your side |
| **F** | Flashlight, while still racing or fighting (starts lit on the dark courses: the horror house and the night-time ones). A lit beam is seen by everyone who can see you |
| **F5** | First or third person |
| **Tab** | Scoreboard |
| **H** | Help: the rules and every key as you have it bound |
| **Esc** | Menu: settings (every key above can be rebound), help, and leave |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many GameSpice addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/gamespice-platform/bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/gamespice-platform/bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-wipeout
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

The courses come from the mg-wipeout-maps checkout, which bootstrap links into `courses/` for you. On a deployed server they come from the server instead: the game ships only its built-in practice course, and the server owner picks the courses pack (`gamemann/mg-wipeout-maps`, or their own) in dot-server-deploy's `cfg/content.yml`.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/gamespice-platform/server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect straight away.

| Setting | Default | What it does |
| --- | --- | --- |
| `wo_course_seconds` | 360 | The longest a course stays open (a course may ask for less) |
| `wo_finale_seconds` | 100 | How long a final death lasts before it is called a draw |
| `wo_teams` | 0 | 0 = everybody for themselves, 2 or more = teams (default 0, any value but 1) |
| `wo_props_per_side` | 6 | Props to throw in a final death (default 6, any value) |
| `wo_weapons_per_side` | 2 | Weapons on the arena floor (default 2, any value) |
| `wo_prop_budget` | 60 | Most props an arena holds at once (default 60, any value; 0 = no limit) |
| `wo_knock_min` | 8 | How hard the obstacles throw you |
| `wo_progress_decides` | 1 | 0 = a round nobody finishes is a draw |
| `bot_difficulty` | medium | `easy`, `medium`, `hard` or `nightmare`: how the bots race and aim |
| `wo_bot_mistakes` | 1 | Scales every racing mistake the bots make (0 = never wrong) |
| `mp_teammate_passthrough` | 1 | Shots and team-mates: 0 a team-mate is hit and blocks, 1 through one at the muzzle, 2 through every team-mate |
| `bot_quota` | 9 | Players a round is kept at with bots; each person who joins replaces one |
| `bot_quota_mode` | fill | `fill` (as above), `fixed` (that many bots), `per_player` (that many per person) or `off` |
| `wo_bots` | 1 | 0 = no bots |

A server holds 24 players by default (`max_players` in `game.yml`). The only limits the game checks: `wo_teams` 0 or 2 and up, `bot_quota` 0 or more (default 9, any value; bots only fill free slots, so a full server of `max_players` takes no more).

The bot cvars are the family's shared ones (dot-server's `DotBotQuota` and dot-bot's `bot_difficulty` with its `bot_*` settings). Each racing mistake is a cvar of its own (`wo_bot_fumble`, `wo_bot_timing`, `wo_bot_rash`, `wo_bot_hop_miss`, `wo_bot_landing`, `wo_bot_recover`, `wo_bot_variety`) that the difficulty sets and you can override; `bot_settings` lists dot-bot's. `wo_min_players` still works and sets `bot_quota`; it is deprecated.

Dead players fall as ragdolls ([dot-player-char](https://github.com/gamespice-platform/player-char)); the server picks how each one goes down and everybody sees the same fall. `sv_ragdoll 0` makes it a quick fall with no physics, `sv_ragdoll_style` picks ragdoll, stiff, topple or hide, `sv_ragdoll_time` and `sv_ragdoll_max` say how long and how many, and `sv_ragdoll_reactions` weights the falls (`limp`, `face_plant`, `crumple`, `headshot_launch`, `power_launch`; 0 turns one off).

`mp_teammate_passthrough` is the family's shared one from dot-combat, live from the next shot. At 2 a team-mate in the line never stops a shot; splash still reaches them.

`--wo-course-ids=<ids>` and `--wo-arena-ids=<ids>` limit a server to some courses and arenas.

Console commands:

| Command | |
| --- | --- |
| `wo_status` | What the server is doing |
| `wo_courses` | The courses the server has, and any it refused (with the reason) |
| `wo_reload` | Read the course folder again, for the next round |
| `wo_net` | What the network code is doing |

The `wo_rank` cvar picks the skill rank published as `rank_score`: `weighted` (courses finished, first across, rounds won, final deaths won, a small penalty per fall), `elo` (final-death knockouts), or `weighted:<stat>=<weight>,...`.

### Admin commands
These come from [dot-moderation](https://github.com/gamespice-platform/moderation): `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`. `respawn` puts a runner back at their last checkpoint. `give` and `strip` are turned off, because the weapons in a final death are the ones on its floor.

## Writing a course
A course is a JSON file: a start pad, a list of pieces, checkpoints and a finish. The [mg-wipeout-maps](https://github.com/zees-games/mg-wipeout-maps) README describes the format and every kind of piece. The server sends the course to each player when the round starts, so players don't need the course files.

## Testing

```bash
./game.sh test                      # every script parses, then every suite runs
./game.sh test headless_courses     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: rounds, checkpoints, falls, the final death |
| `headless_courses` | A bot runs every course to the finish, and a nightmare field beats an easy one |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

`tools/race_times.tscn` races a field of bots round every course at every difficulty and prints the finish times. [`docs/design.md`](docs/design.md) has the design decisions and the reasoning behind them, and [`docs/stand-ins.md`](docs/stand-ins.md) the bots.

What the game does not do yet is listed in [`docs/not-yet.md`](docs/not-yet.md).

## Credits

| Asset | Author / source | License | Where |
| --- | --- | --- | --- |
| Surfaces, props | Kenney, Prototype Textures; Survival and Car kits ([kenney.nl](https://kenney.nl)) | CC0 | each kit's licence |
| Players | Quaternius, [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html), skinned from Kenney's Blocky Characters | CC0 1.0 | dot-player-char |
| Weapons | [zee-dot-weapons](https://github.com/zees-games/zee-dot-weapons) | see that repo | that repo |
| Announcer | Kenney, Voiceover Pack and Voiceover Pack Fighter | CC0 | `audio/` |
| Crowd, stadium horn, waterfalls | Synthesised by `tools/make_sounds.py` | MIT | `tools/` |
| Footsteps | Kenney, Impact Sounds | CC0 | `addons/dot_audio/stock/CREDITS.md` |
| Ambience beds | Generated by dot-audio | CC0 | `addons/dot_audio/stock/CREDITS.md` |

If you made one of these assets and want it removed, open an issue.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
