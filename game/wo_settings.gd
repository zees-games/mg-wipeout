extends DotMenuGameSettings

const WoBindings := preload("wo_bindings.gd")

## A player's settings and their menu: dot-menu's `DotMenuGameSettings` with this game's spec. Scopes are the family's:
## `sensitivity` ACCOUNT, `field_of_view` SERVER_CLAMPED, volumes this machine's. Use: `setup()`, `bind_look/camera/audio`, `open()`.
## Help and Leave are dot-menu's stock; the keys are [WoBindings], so the help screen lists them.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://wipeout_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"wipeout"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Wipeout"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.reduce_motion_text = "The end-of-round announcement appears at once, with nothing sliding, rising or bursting."
	s.ambient_text = "Quiet sounds under the course."
	s.not_applied = NOT_APPLIED
	s.bindings_maker = func() -> DotMenuBindings: return WoBindings.make()
	s.help_about = "Get round the course over the water as fast as you can: arms, hammers, rams and rides are all trying to knock you off. A fall sends you back to your last checkpoint, and a knock costs health."
	s.help_cards = [
		["Points", "Finishing earns points by place, and the side that wins the round earns more. Tab shows everybody's."],
		["The final", "If two or more sides finish, the round ends in a fight in an arena: pick props up and throw them, and grab the weapons lying on the floor. The last side with anybody standing wins the round."],
	]
	s.help_sections = [["Mouse", [["Left", "Throw what you hold, or fire; watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys"]]
	return s
