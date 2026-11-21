extends RefCounted
## A course's light: the dot-lighting document its theme describes and the profile this machine draws it with
## ([wo_course_base.gd] puts both on its rig).


## The dot-lighting document a course's theme describes. The sun is high (a deck is not in its neighbour's shadow) and
## behind the start (the faces a runner runs toward are lit). The ambient is a pale cool grey whatever the theme, as a
## saturated fill turns shaded faces navy. Fog starts at 120 m so nothing a player must react to is hidden.
static func light_document(theme: Dictionary) -> Dictionary:
	var sun: Color = theme.get("sun", Color(1.0, 0.96, 0.88))
	var horizon: Color = theme.get("horizon", Color(0.82, 0.88, 0.94))
	return {
		"sun": {
			"pitch_src": -54.0,
			"yaw_src": 145.0,
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0,
			"spread_degrees": 1.0,
			"ambient_colour": [0.74, 0.78, 0.92],
		},
		"fog": {
			"enabled": true,
			"colour": [horizon.r, horizon.g, horizon.b],
			"start": 6300.0,
			"end": 40000.0,
			"max_density": 0.25,
		},
	}


## What this machine draws of a course's light: dot-lighting's `painted()` profile (API 3), matched to the
## Compatibility renderer, which has no headroom above white. Shadows stay on in the browser, unlike `web()`: a mover's
## shadow on the deck is how a player sees where it is.
static func light_profile() -> GSLightProfile:
	var p := GSLightProfile.painted()
	p.sun_shadows = true
	return p
