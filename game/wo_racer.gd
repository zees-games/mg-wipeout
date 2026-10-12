extends RefCounted

## How a stand-in races: how often it gets a jump wrong, how late it reacts to a window, how
## well it steers a landing, how long it shakes off a fall. One column per dot-bot preset.
##
## [b]A race is lost to mistakes, not to speed.[/b] Everybody runs at the same speed here; what
## separates a good run from a bad one is a jump taken a tenth of a second late off an edge, a
## window gone through as it closed, an arm not jumped. So the stand-ins' difficulty is a set of
## mistake rates, never a slower run: a bot jogging at three quarters of the run reads as broken,
## one that falls off a ball reads as a person.
##
## [b]The preset is dot-bot's `bot_difficulty`[/b] ([DotBotSettings] on the world), so one
## word sets how a stand-in races and how it fights in a final death. The reaction to a window
## is dot-bot's own `bot_reaction`, because it is the same thing: the time between seeing and
## doing. Each row here is a cvar, `wo_bot_<field>`, overridable on its own; an override
## outlives a preset change, as in dot-bot ([DotBotSettings]).
##
## [b]Every stand-in is a little different.[/b] [method factor] scales one bot's mistakes by
## up to `variety` either way, drawn from the bot and the round, so eight medium bots finish
## spread out rather than in a clump, and the order changes from round to round.
##
## [b]`WoConfig.bot_mistakes` scales all of it[/b], and 0 is a stand-in that is never wrong:
## the course suite's, which proves a course can be finished, not that a bot can.

const CHANNEL := "wo.racer"

## [code][field, min, max, easy, medium, hard, nightmare, help][/code]. The cvar is
## `wo_bot_` + field. Medium is tuned so a medium field finishes most courses with a fall or
## two each; the measured spread per preset is in docs/stand-ins.md.
const SPEC := [
	["fumble", 0.0, 100.0, 7.0, 3.5, 1.5, 0.5, "Chance in a hundred a stand-in does not take a jump at all."],
	["timing", 0.0, 0.5, 0.06, 0.04, 0.025, 0.012, "Seconds a stand-in's take-off can be early or late."],
	["rash", 0.0, 100.0, 14.0, 7.0, 3.0, 1.0, "Chance in a hundred a stand-in goes without waiting for its window."],
	["hop_miss", 0.0, 100.0, 18.0, 9.0, 4.0, 1.0, "Chance in a hundred a stand-in fails to jump or duck an arm."],
	["landing", 0.0, 1.0, 0.55, 0.75, 0.9, 1.0, "How well a stand-in steers a jump onto a small top (1 is perfectly)."],
	["recover", 0.0, 5.0, 1.4, 0.9, 0.5, 0.25, "Seconds a stand-in stands still after a fall, shaking it off."],
	["variety", 0.0, 1.0, 0.45, 0.45, 0.4, 0.3, "How much one stand-in differs from the next, as a share of every mistake."],
	["risk", 0.0, 100.0, 15.0, 40.0, 70.0, 90.0, "Chance in a hundred a stand-in takes the faster, riskier branch at a fork."],
]

const COL_FIELD := 0
const COL_MIN := 1
const COL_MAX := 2
const COL_FIRST_PRESET := 3
const COL_HELP := 7

## The dot-bot preset the values below are for; follows [member settings].
var preset: String = DotBotProfile.DEFAULT_PRESET

## Fields set by hand, field -> float. They survive a preset change.
var overrides: Dictionary = {}

## Scales every mistake; [code]WoConfig.bot_mistakes[/code]. 0 is never wrong.
var mistakes: float = 1.0

## The world's dot-bot settings, read for the preset and for `reaction`.
var settings: DotBotSettings = null


func _init(p_settings: DotBotSettings = null) -> void:
	settings = p_settings
	if settings != null:
		preset = settings.difficulty()


## A setting's value now: an override, else the preset's column. Mistake rates and timings are
## scaled by [member mistakes]; `landing` moves toward perfect as it goes to 0.
func value(field: String) -> float:
	if settings != null:
		preset = settings.difficulty()

	var raw := float(overrides[field]) if overrides.has(field) else preset_value(preset, field)

	match field:
		"landing":
			return lerpf(1.0, raw, clampf(mistakes, 0.0, 1.0))
		"variety", "risk":
			# A choice, not a mistake: a stand-in that is never wrong still picks a way, and
			# the course suite sets it to send one down each branch.
			return raw
		_:
			return raw * maxf(mistakes, 0.0)


## The reaction to a window opening, seconds: dot-bot's `bot_reaction`, scaled like a mistake.
func reaction() -> float:
	var seconds := settings.profile.reaction if settings != null else 0.3
	return seconds * maxf(mistakes, 0.0)


## How much worse (above 1) or better (below) than the preset one stand-in is this round.
static func factor(variety: float, draw: float) -> float:
	return maxf(1.0 + variety * clampf(draw, -1.0, 1.0), 0.05)


static func preset_value(preset_name: String, field: String) -> float:
	var column := DotBotProfile.PRESETS.find(preset_name)
	if column < 0:
		column = DotBotProfile.PRESETS.find(DotBotProfile.DEFAULT_PRESET)

	for row: Array in SPEC:
		if String(row[COL_FIELD]) == field:
			return float(row[COL_FIRST_PRESET + column])

	return 0.0


static func fields() -> PackedStringArray:
	var out := PackedStringArray()
	for row: Array in SPEC:
		out.append(String(row[COL_FIELD]))
	return out


## Overrides one field from text. Refused outside the row's range.
func set_value(field: String, text: String) -> DotResult:
	for row: Array in SPEC:
		if String(row[COL_FIELD]) != field:
			continue
		if not text.strip_edges().is_valid_float():
			return DotResult.fail(DotError.CODE_INVALID, "wo_bot_%s is a number." % field)
		var number := text.strip_edges().to_float()
		if number < float(row[COL_MIN]) or number > float(row[COL_MAX]):
			return DotResult.fail(DotError.CODE_INVALID,
				"wo_bot_%s is %s to %s." % [field, row[COL_MIN], row[COL_MAX]])
		overrides[field] = number
		return DotResult.success(number)

	return DotResult.fail(DotError.CODE_INVALID, "There is no wo_bot_%s." % field)


## The value a field's cvar shows: the override, else the preset's, unscaled.
func shown(field: String) -> String:
	if settings != null:
		preset = settings.difficulty()
	var raw := float(overrides[field]) if overrides.has(field) else preset_value(preset, field)
	return "%s" % snappedf(raw, 0.001)


# --- Cvars and the solo console ---------------------------------------------------

## The cvar objects [method bind_cvars] made, field -> object.
var _cvars: Dictionary = {}
var _writing: bool = false


## Registers `wo_bot_<field>` for every row through [param add] (dot-server's
## [code]DotModule.add_cvar(name, default, help, flags)[/code]). A value a config left waiting
## is read back as an override. Each cvar follows a preset change unless it was set by hand.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []

	for row: Array in SPEC:
		var field := String(row[COL_FIELD])
		var made_cvar: Variant = add.call("wo_bot_" + field, shown(field), String(row[COL_HELP]), flags)

		if not (made_cvar is Object) or made_cvar == null:
			continue

		var cv := made_cvar as Object
		if cv.has_method(&"with_range"):
			cv.call(&"with_range", float(row[COL_MIN]), float(row[COL_MAX]))
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar.bind(field))
		_cvars[field] = cv
		made.append(cv)

		var waiting := String(cv.call(&"get_string")) if cv.has_method(&"get_string") else ""
		if waiting.is_valid_float() and not is_equal_approx(waiting.to_float(), preset_value(preset, field)):
			var _set := set_value(field, waiting)

	if settings != null and not settings.changed.is_connected(_rewrite_cvars):
		settings.changed.connect(_rewrite_cvars)

	return made


func _on_cvar(_old: String, new_value: String, field: String) -> void:
	if _writing:
		return
	var res := set_value(field, new_value)
	if not res.ok:
		DotLog.warn(CHANNEL, "a stand-in setting was refused", {"field": field, "why": res.error.message})


## After `bot_difficulty` changed: every cvar not set by hand shows the new preset's value.
func _rewrite_cvars() -> void:
	for field: String in _cvars:
		var cv: Object = _cvars[field]
		var text := shown(field)
		if not is_instance_valid(cv) or (cv.has_method(&"get_string") and String(cv.call(&"get_string")) == text):
			continue
		_writing = true
		if cv.has_method(&"force_set"):
			cv.call(&"force_set", text)
		elif cv.has_method(&"set_value"):
			cv.call(&"set_value", text)
		_writing = false


## The same names at a solo console ([code]add_var(name, help, get, set)[/code]).
func bind_console(local: Object) -> bool:
	if local == null or not local.has_method(&"add_var"):
		return false

	for row: Array in SPEC:
		var field := String(row[COL_FIELD])
		local.call(&"add_var", StringName("wo_bot_" + field), String(row[COL_HELP]),
			func() -> Variant: return shown(field),
			func(v: Variant) -> Variant: return set_value(field, str(v))
		)

	return true


func describe() -> Dictionary:
	var out := {"preset": preset, "mistakes": mistakes, "overrides": overrides.duplicate()}
	for field in fields():
		out[field] = value(field)
	out["reaction"] = reaction()
	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["racing as %s, mistakes x%s" % [preset, snappedf(mistakes, 0.01)]])
	for field in fields():
		out.append("%s wo_bot_%-9s %s" % ["*" if overrides.has(field) else " ", field, shown(field)])
	return out
