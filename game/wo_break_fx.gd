extends Node

## Splinters and chips where a prop breaks, drawn by dot-fx's DotFxBreak and following fx_quality.

## Wire index -> dot-fx material; append only, the index travels in SHATTER.
const MATERIALS: PackedStringArray = ["wood", "metal", "plastic", "stone"]
const KIND_OF_PROP := {&"crate": 0, &"barrel": 1, &"cone": 2, &"tyre": 2, &"boulder": 3}

var break_fx: DotFxBreak = null


func _init() -> void:
	name = "BreakFx"
	break_fx = DotFxBreak.new()
	break_fx.name = "Break"
	add_child(break_fx)


func follow(store: Object) -> void:
	break_fx.follow(store)


## The wire index for a broken prop of [param prop_id]; wood for anything unlisted.
static func material_of(prop_id: StringName) -> int:
	return int(KIND_OF_PROP.get(prop_id, 0))


func shatter(at: Vector3, material: int, size: float = 1.0) -> void:
	if material >= 0 and material < MATERIALS.size():
		var _b := break_fx.burst(MATERIALS[material], at, Vector3.UP, size)
