# Stand-ins

Stand-ins run the document's route (`route` in mg-wipeout-maps). The flags are the whole brain, and each was earned by watching a bot fail in `tools/trace_course` (`godot --headless --path . res://tools/trace_course.tscn -- --course=wo_log_roll --every=0.5`). How many there are follows dot-server's `DotBotQuota`: a person replaces a bot, and leaving brings it back.

- **`jump`**: jump here, **once on the ground** (a jump point passed in the air was skipped, and the bot slid off the ball it landed on), after getting up to speed for up to three ticks (a landing on a turning log costs speed, and a slow jump falls short; a jump is cut short in the air, never stretched).
- In the air toward a `jump` point, `_bot_land_on` predicts the landing and brakes **proportionally**: full back-wish removes 3 m/s in one tick and stopped every jump dead.
- **`wait`**: hold until `WoCourse.path_clear` says the run to the next point meets no hazard. Exact, because hazards are functions of the tick. Walk only the last 1.6 m into a stop point (walking 2.5 m walked the bot through the ram it had timed at a run).
- **`board`**: something to land on. Hold until it will be under the landing and within 5 m, then run and jump at whatever edge comes first (`supported` 0.7 m ahead), but step a gap a stride crosses (jumping the 30 cm to a mover carried the bot over it).
- **`ride`**: a point ON a carrier is reached by standing on any carrier (chasing the mover's start coordinates walked the bot off its tail).
- **`onward`**: a jump point the bot may land PAST; the jump and its run-up aim at the next point instead. Opt-in per point, because doing it on every jump point broke four courses: a gap's edge point is routinely passed before take-off, and turning there spoils a straight run-up.
- `_bot_hop` jumps an arm due in 0.2–0.4 s along the heading. The bot ducks only when `WoCourse.high_arm_near` finds an arm whose underside is above a standing jump; ducking every arm at head height crouched it under hammers it should have run past.
- `_bot_unstick` jumps after a second of going nowhere, or lets go on a face too steep to jump from (a turning log's steep side was a 30-second treadmill).
- `bot_fumble_chance` misses a jump per bot, waypoint and round, reproducibly.

Course layout rules the stand-ins taught (the authoring side is in mg-wipeout-maps):

- Every route starts at the middle of the start pad, and restarts and joiners get full-row seats: a restart at the side of the pad walked off the narrower run-out.
- Pendulums use `yaw` 0: `yaw` 90 turns the swing plane along the path, so a hammer lifted a waiting bot again and again.
- A conveyor on a ramp takes `pitch`, and its carry follows it; laid flat it was a wall.
- Hammers at least 4.2 m apart and rams 4.5 m, waiting halfway / 2.4 m short; closer, the one behind reached a person waiting for the one in front.
