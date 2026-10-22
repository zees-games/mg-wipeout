# Bot soak

`./game.sh soak [course] [minutes]` runs `tools/soak.tscn`: four stand-ins (`game/wo_racer.gd`) racing one course in the real `WoGame`, driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts, ticked externally at 64 Hz. A map here is a course id from `courses/`. Rounds run back to back (no warm-up, intermission or weather); a bot counts as stuck only while the course is open and it has not finished. The report is `.godot/test-logs/soak-<course>.json` and one `SOAK {...}` line, and the exit code is 1 on failure. Knocks are not kills, so the kill check is off, and there is no navigation mesh, so off-nav and unreachable are off.

First run, 2026-10-22, 1 simulated minute per course, 4 bots, all 21 courses (the 5 arenas are the final death's and have no course to ride): 21 pass, 0 fail. Tick cost p95 is 0.9 to 2.4 ms at 64 Hz, worst single tick 11.4 ms (wo_grand_tour), object growth 0% everywhere.

- Longest stuck spell was 4.5 s (wo_labo_course), under the 10 s limit; wo_dc_course, wo_lego_course and wo_sweet_course reached 4.0 s.
- Most falls in the minute: wo_dans_course (before it was imported whole) 33, wo_log_roll 11, wo_the_sweeper 7. Falls are the game, not a failure (the checkpoint puts the bot back); wo_first_splash and wo_trapdoor_run had none.
- One minute is shorter than a full course plus its close, so no course cycled into a second round (`rounds` is 1 everywhere). A longer soak (`./game.sh soak wo_grand_tour 10`) is what exercises round turnover.
