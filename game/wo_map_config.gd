extends RefCounted

## The rules a course's per-map file may set: `cfg/game/mg-wipeout/dot_map/map/<course id>.yml`, anything else is logged and ignored.

## cvar -> its constraint. Server-side rules only; movement is the game's pinned profile.
const KEYS := {
	"wo_course_seconds": {"type": "float", "min": 10.0, "max": 3600.0},
	"wo_health": {"type": "int", "min": 0, "max": 1},
	"wo_knock_damage": {"type": "float", "min": 0.0, "max": 100.0},
	"wo_strike_damage": {"type": "float", "min": 0.0, "max": 100.0},
	"wo_fall_safe_height": {"type": "float", "min": 0.0, "max": 100.0},
	"wo_fall_damage": {"type": "float", "min": 0.0, "max": 100.0},
	"wo_knock_min": {"type": "float", "min": 0.0, "max": 100.0},
	"wo_instant_death": {"type": "int", "min": 0, "max": 1},
	"wo_progress_decides": {"type": "int", "min": 0, "max": 1},
	"wo_gravity": {"type": "float", "min": 1.0, "max": 100.0},
}
