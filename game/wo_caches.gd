extends RefCounted

## Releases the static caches the game and the family addons hold, for a suite to call just before it quits.
## The mesh cache holds a built map's collision shapes and meshes, so a suite that built a map world otherwise ends
## with "resources still in use at exit" (about 14k leaked shapes), which the runner counts as a failure.
## After it the statics are empty: a running game never calls it.

const WoTextures := preload("wo_textures.gd")
const WoWorld := preload("wo_world.gd")
const WoPlayer := preload("wo_player.gd")
const WoCourseBase := preload("wo_course_base.gd")


static func release() -> void:
	GSMapBspMesh.clear_cache()
	WoTextures.forget_cache()
	WoWorld.forget_cache()
	WoPlayer.forget_cache()
	WoCourseBase._streaks = null
	WoCourseBase._crowd_shader = null
	GSHumanoidFigure.clear_cache()
	GSHudPiece.clear_cache()
	GSMenuKit.clear_cache()
	GSPropBodyLook.clear_cache()
	GSPropModel.clear_cache()
	GSLog.clear_cache()
	GSRegistry.clear_cache()
