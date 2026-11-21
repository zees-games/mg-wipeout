extends GSGameWorkbenchSuite

## mg-wipeout: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const WoConfig := preload("../game/wo_config.gd")


func _make_config() -> GSConfig:
	return WoConfig.new()


func _make_binder(config: GSConfig) -> GSGameConfigBinder:
	return WoConfig.make_binder(config)
