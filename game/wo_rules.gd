extends DotMatchRules

## A round ends when the game says so: neither of dot-match's shipped shapes fits, as nobody dies or scores on a
## course. What decides is [WoGame], which knows who finished; this only reads that answer, and returns NONE every
## tick it has not decided.

## `func() -> Dictionary`: `{decided: bool, winner: int}`. Set by [WoGame].
var decision_fn: Callable = Callable()


static func make() -> DotMatchRules:
	# Not this class's own name, for dot-match's reason: a script that names itself in an
	# expression cuts Godot 4.7.2's exit teardown short. See docs/gdscript-hazards.md.
	var rules := new()
	rules.id = &"wipeout"
	rules.display_name = "Wipeout"
	rules.score_limit = 0
	# The course and the final death keep their own clocks; this is the BACKSTOP, set by [WoGame] to their sum and a
	# minute more, so a round with a hole in its rule ends as a draw rather than running for ever, and dot-match
	# stops warning that only a custom outcome can end a round.
	rules.time_limit_sec = 600.0
	rules.rounds_to_win = 999
	rules.respawn_disabled = true
	rules.kill_points = 1
	rules.suicide_points = 0
	return rules


func _round_outcome(
	_scoreboard: DotScoreboard,
	_teams: DotTeamManager,
	_elapsed_sec: float
) -> Outcome:
	if not decision_fn.is_valid():
		return Outcome.NONE

	var decision: Dictionary = decision_fn.call()

	if bool(decision.get("decided", false)):
		return Outcome.CUSTOM

	# Only the backstop clock is left to the parent: there is no score limit to reach.
	return super._round_outcome(_scoreboard, _teams, _elapsed_sec)


func _round_winner(_scoreboard: DotScoreboard, _teams: DotTeamManager) -> int:
	if not decision_fn.is_valid():
		return 0

	return int((decision_fn.call() as Dictionary).get("winner", 0))
