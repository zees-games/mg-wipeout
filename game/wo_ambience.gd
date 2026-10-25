extends RefCounted

## What the courses' ambience is: the cvar defaults shared by the simulation (binds `wo_ambient*`) and the client's director (plays them).

const PREFIX := "wo"
## The crowd and the machinery are the show; the layer sits under them.
const LEVEL := 0.35
const RATE := 0.6
const DEFAULT_MOOD := &"swamp"

## By course id prefix (lower case); a course not listed takes the default.
const PREFIX_MOODS := {
	"wo_arena": &"industrial", "wo_scary": &"interior_horror", "wo_office": &"indoor_hall",
	"wo_labo": &"industrial", "wo_spin_cycle": &"industrial", "wo_punch_alley": &"city_ruins",
	"wo_sweet": &"outdoor_night", "wo_lego": &"outdoor_night",
}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r
