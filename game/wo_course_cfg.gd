extends RefCounted

## A course's own settings: `cfg/<course id>.cfg` in the courses pack, applied when the course
## is laid out and put back when the next one is.
##
## [b]Why the game does this and not the console's `exec`.[/b] The console runs a file and
## forgets it: nothing would undo a one-life course's `wo_instant_death 1` when the vote moved
## on to a course that wants the checkpoints back, and the operator's own value would be lost
## with it. This remembers what each line replaced and puts it back, unless somebody has
## changed that cvar since (an operator's `wo_instant_death 0` mid-round outranks a file).
##
## [b]Only `wo_` cvars[/b]: the file ships inside a courses pack, which anyone can publish, so it
## must never reach `rcon_*`, `sv_*` or a command. One cvar and its value per line, `//` or `#`
## for comments.

const CHANNEL := "wo.course_cfg"

## name -> {old: String, set: String}, for the lines applied last.
var _applied: Dictionary = {}


## `[[name, value], ...]` from a file's text, in order. A line without a value is skipped; a
## value may be quoted.
static func parse(text: String) -> Array:
	var out: Array = []

	for raw in text.split("\n"):
		var line := raw.strip_edges()

		if line.is_empty() or line.begins_with("//") or line.begins_with("#"):
			continue

		var cut := line.find(" ")

		if cut < 0:
			cut = line.find("\t")

		if cut < 0:
			continue

		var value := line.substr(cut + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		out.append([line.substr(0, cut).to_lower(), value])

	return out


## Puts back what the last file changed, then applies [param text]. Returns how many cvars it
## set. [param console] is a [DotConsole]; with none (a solo game has no console) nothing is
## applied, which is why the file is a server's.
func apply(console: DotConsole, text: String) -> int:
	revert(console)

	if console == null:
		return 0

	var set_count := 0

	for pair: Array in parse(text):
		var cvar_name: String = pair[0]
		var cvar := console.find_cvar(cvar_name)

		if not cvar_name.begins_with("wo_") or cvar == null:
			DotLog.warn(CHANNEL, "a course cfg line was skipped", {"cvar": cvar_name})
			continue

		var old := cvar.get_string()
		var res := cvar.set_value(str(pair[1]))

		if not res.ok:
			DotLog.warn(CHANNEL, "a course cfg value was refused", {
				"cvar": cvar_name, "value": str(pair[1]), "why": res.error.message,
			})
			continue

		# The first line to name a cvar owns its old value.
		if not _applied.has(cvar_name):
			_applied[cvar_name] = {"old": old, "set": cvar.get_string()}
		else:
			_applied[cvar_name]["set"] = cvar.get_string()

		set_count += 1

	return set_count


func revert(console: DotConsole) -> void:
	if console != null:
		for cvar_name: String in _applied:
			var cvar := console.find_cvar(cvar_name)
			var entry: Dictionary = _applied[cvar_name]

			if cvar != null and cvar.get_string() == entry["set"]:
				var _res := cvar.set_value(str(entry["old"]))

	_applied.clear()


## What is applied now, for `describe()`: `name=value` strings.
func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	for cvar_name: String in _applied:
		out.append("%s=%s" % [cvar_name, (_applied[cvar_name] as Dictionary)["set"]])

	return out
