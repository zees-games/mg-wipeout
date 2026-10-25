extends SceneTree

## Rewrites cfg/game/mg-wipeout/config_*/game.yml from WoConfig's fields: godot --headless --path . --script tools/cfg_templates.gd
## (cfg/ is the mg-wipeout-maps link, so the files land in that repository.)

const WoConfig := preload("../game/wo_config.gd")


func _init() -> void:
	var binder := WoConfig.make_binder(WoConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
