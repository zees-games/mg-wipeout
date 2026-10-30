extends DotMenuSettings

const WoBindings := preload("wo_bindings.gd")

## A player's settings and their menu, on dot-menu's `DotMenuSettings` with this game's schema. Scopes are the
## family's: `sensitivity` ACCOUNT (a person's hand, the same everywhere), `field_of_view` SERVER_CLAMPED (a server
## may cap it but cannot READ it), volumes this machine's. Use: `setup()`, `bind_look/camera/audio`, `open()`.

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
	name = "Settings"
	directory = SETTINGS_DIR
	app_namespace = APP_NAMESPACE
	schema = schema_for()
	config = DotMenuConfig.new()
	config.brand_name = "Wipeout"
	# Help and Leave are dot-menu's stock: H opens help, Leave leaves the server or quits a
	# solo game. Every game in the family has both (the first play test found this one with
	# neither). The keys are a table now ([WoBindings]), so the help screen lists them.
	bindings = WoBindings.make()
	var _layered := config.load_layered()


## The document: this game's field of view first, so it keeps its own default, then the
## stock settings it applies.
static func schema_for() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION
	s.add(DotSettingsDef.integer(&"field_of_view", DEFAULT_FOV, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"reduce_motion", false, &"accessibility").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The end-of-round announcement appears at once, with nothing sliding, rising or bursting."))
	s.add(DotSettingsDef.boolean(&"ambient", true, &"audio").with_description("Quiet sounds under the course."))
	s.add(DotSettingsDef.number(&"ambient_volume", 1.0, 0.0, 1.0, &"audio"))
	return DotMenuStock.declare(s, DotMenuStock.DEFAULT_GROUPS, null, NOT_APPLIED)


## The help screen's goal and rules; the keys come from [WoBindings].
func _fill_help(help: DotMenuHelp) -> void:
	help.about = "Get round the course over the water as fast as you can: arms, hammers, rams and rides are all trying to knock you off. A fall sends you back to your last checkpoint, and a knock costs health."
	help.add_text("Points", "Finishing earns points by place, and the side that wins the round earns more. Tab shows everybody's.")
	help.add_text("The final", "If two or more sides finish, the round ends in a fight in an arena: pick props up and throw them, and grab the weapons lying on the floor. The last side with anybody standing wins the round.")
	help.add_section("Mouse", [["Left", "Throw what you hold, or fire; watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys")
