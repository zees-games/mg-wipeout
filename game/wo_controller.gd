extends DotFpsController

## The first-person controller with the hooks a course needs INSIDE the tick: dot-net's predictor replays ticks by
## calling `simulate_tick` directly, so anything done around the tick is skipped on a replay and obstacles would be
## swept where they are now. [method _on_pre_simulate] and [method _on_post_simulate] run in replays.

## `func(tick: int) -> void`: put the world where it is on [param tick], before the motor runs.
var before_fn: Callable = Callable()

## `func(tick: int, state: DotFpsState) -> void`: what the world does to the player after
## the motor has moved them — a carry, a knock, a bounce.
var after_fn: Callable = Callable()


func _on_pre_simulate(tick: int, _delta: float) -> void:
	if before_fn.is_valid():
		before_fn.call(tick)


func _on_post_simulate(tick: int, _delta: float) -> void:
	if after_fn.is_valid():
		after_fn.call(tick, state)
