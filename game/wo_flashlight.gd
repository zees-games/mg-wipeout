extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are gs-flashlight's).

const WoAmbience := preload("wo_ambience.gd")

const GAME_ID := "mg-wipeout"

## The ambience moods whose courses start with the light on: the horror house, the night-time courses and the tunnels. A daylit course starts dark and F lights it.
const DARK_MOODS: PackedStringArray = ["interior_horror", "cave_tunnel", "outdoor_night"]


## A config with this game's defaults: F, off on a lit course, on in a dark mood.
static func make_config() -> GSFlashlightConfig:
	var cfg := GSFlashlightConfig.new()
	cfg.key = "F"
	cfg.dark_moods = DARK_MOODS
	return cfg


## The binder: `wo_flashlight_<field>` cvars, `cfg/game/mg-wipeout/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: GSFlashlightConfig) -> GSGameConfigBinder:
	var b := GSGameConfigBinder.create(cfg, GAME_ID, "wo_flashlight")
	b.profile_kind = "flashlight"
	return b


## The mood a course (or arena) plays under: by id prefix, else the default.
static func mood_of(stage_id: String) -> String:
	var lower := stage_id.to_lower()
	for prefix: String in WoAmbience.PREFIX_MOODS:
		if lower.begins_with(prefix):
			return String(WoAmbience.PREFIX_MOODS[prefix])
	return String(WoAmbience.DEFAULT_MOOD)


## Whether a player starts a course with the light on: the course's mood against the config's dark moods.
static func starts_on(cfg: GSFlashlightConfig, stage_id: String, mood: String = "") -> bool:
	return GSFlashlightRules.start_on(cfg, stage_id, 1.0, mood if mood != "" else mood_of(stage_id))
