extends CanvasLayer

const WoGame := preload("wo_game.gd")
const WoPlayer := preload("wo_player.gd")

## The clock, where you are on the course, and in a final death how much you have left.
##
## [b]How far along you are is the bar along the bottom, and it is the number a player
## cannot read off the world.[/b] A course is long and mostly behind you; the checkpoints
## crossed out of the course's total says whether a fall now costs ten seconds or a minute,
## and the finished count says whether the course is about to close.
##
## [b]Health only in a final death.[/b] Nothing on a course can hurt you — a fall is a
## restart, a knock is a flight — so a health number there would be a number that never
## moves, and the one thing a player learns from a number that never moves is to ignore it.

# No `const CHANNEL`. This draws numbers from state somebody else owns and has nothing an
# operator would act on; the round, the finishes and the deaths are logged by [WoGame],
# which is where the decisions are. A channel declared and never used is a file that meant
# to say something and does not.

var game: WoGame = null
var player: WoPlayer = null

## Bottom right while armed: the weapon in hand and `magazine | reserve`. See [method _draw_ammo].
var ammo: DotAmmoCounter = null

## The rig the counter reads: the gun this client draws (`WoClient.weapons`), which
## `WoClient.correct_drawn` brings to the server's count once quiet.
var weapons_fn: Callable = Callable()

## Four ticks round the crosshair for a hit the server confirmed. See [method confirm_hit].
var hit_marker: DotHitMarker = null

## The clock with the phase line under it: dot-ui's [DotScoreStrip], clock alone.
var strip: DotScoreStrip = null
## Health in a final death: dot-ui's [DotVitals], bar and number on one plate, red at a
## quarter. Hidden on a course; see the class note.
var vitals: DotVitals = null
var _field: Label = null
var _special: Label = null
var _shout: Label = null

## The announcer's line under the course name ([method announce]), and the runner's place in
## the race over the progress bar ("3rd of 9").
var _ticker: Label = null
var _place: Label = null
var _ticker_for: float = 0.0

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null
var _tilt_back: ColorRect = null
var _tilt_fill: ColorRect = null
var _root: Control = null

## Seconds left of the big shouted line in the middle of the screen.
var _shout_for: float = 0.0

## Damage feedback: the last health seen, and a flash that fades (a red wash and a shake of the bar).
var _health_seen: float = -1.0
var _hurt_flash: float = 0.0
var _hurt_wash: ColorRect = null
var _course_seen: int = 1
const HURT_FLASH_SEC := 0.45

## An administrator's `blind`, over the world and under the HUD's numbers.
##
## [b]Under the numbers, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the phase and their own health still say the round is going on and
## that they are in it, which is what makes it read as "an admin did this" rather than as a
## client that stopped drawing.
##
## [b]But not under the progress bar, which a blind hides.[/b] The bar says how much of the
## course is behind them, which is a thing their eyes would have told them.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and not
## instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## Seconds left at which the clock turns red.
const LOW_CLOCK_SEC := 10.0

## The course name's amber, which is also the glance pieces' highlight.
const AMBER := Color(0.98, 0.78, 0.33)


## This game's accent over whichever theme the player picked in the menu: the course name's
## amber as the glance pieces' highlight and their plates' edge. The plates, the words and
## their outline are the theme's (dark by default), so a light or high-contrast theme can
## change them. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(AMBER, 0.3))
	t.set_color(&"highlight", type, AMBER)
	return t


## The Escape menu, whose theme this HUD follows (dot-menu's `follow_hud`): the menu sets the
## theme on the HUD's root now and at every theme change, and applies the player's HUD size.
## Christian's first play test (2026-10-11) asked for a darker HUD a player can restyle in
## the menu. Duck-typed and called by name, for a client shell older than dot-menu 7.
var _menu: Object = null


func follow_menu(menu: Object) -> void:
	_menu = menu
	_follow()


func _follow() -> void:
	if _root != null and _menu != null and _menu.has_method(&"follow_hud"):
		_menu.call(&"follow_hud", _root, piece_theme())


func bind(p_game: WoGame, p_player: WoPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# [b]A full-rect Control between the CanvasLayer and the labels, and the first render of
	# game-buses-from-hell is why.[/b] A CanvasLayer is not a Control and does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing:
	# every label lands in the top-left corner on top of the others, and the only one
	# visible is whichever drew last, clipped in half by the edge of the screen. It reads as
	# the HUD being half-written.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# First, so every widget added below draws over it. Full rect on `_root`, which is full
	# rect on a CanvasLayer — so the whole viewport, with no safe-area inset between them to
	# leave a frame of the world showing round the edge, which is what game-arena's first
	# render of its own blind found. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	_root.add_child(blind_overlay)

	var size := 22

	# The glance pieces read their colours from the theme on the type DotHudPiece; set on
	# the root, every piece under it inherits them. See [method piece_theme].
	_root.theme = piece_theme()
	_follow()

	# The clock, and the phase line under it. Full width, because the strip centres itself
	# on its own middle; the course name sits under it.
	strip = DotScoreStrip.new()
	strip.name = "Clock"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 16.0
	strip.offset_bottom = 96.0
	_root.add_child(strip)

	_special = _label(size)
	_special.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	# Right under the strip's line, which ends about 90 pixels down.
	_special.offset_top = 94.0
	_special.offset_bottom = 128.0
	_special.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_special.add_theme_color_override("font_color", AMBER)

	# The announcer, an accent line like the course name over it: amber, so it reads as the
	# show talking and not as the rules.
	_ticker = _label(size - 2)
	_ticker.name = "Announcer"
	_ticker.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_ticker.offset_top = 128.0
	_ticker.offset_bottom = 160.0
	_ticker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ticker.add_theme_color_override("font_color", AMBER)

	_shout = _label(size + 20)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 190.0
	_shout.offset_bottom = 260.0
	_shout.offset_left = -520.0
	_shout.offset_right = 520.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# [b]Above the chat box, because the chat box also draws itself bottom-left.[/b] The
	# first render had the health number and the first line of chat in the same forty pixels,
	# one on top of the other — which is exactly the shape of the bug game-buses-from-hell
	# shipped with four HUD labels, and is invisible to a headless suite because a headless
	# viewport is 64 x 64 and nothing there can overlap anything.
	# The plate is 56 tall and ends 206 pixels off the bottom, above the chat box's FULL
	# eight-row log, which reaches 202 (checked in headless_run). The old number ended at 150,
	# over the log's top rows; only a full log showed it.
	vitals = DotVitals.new()
	vitals.name = "Vitals"
	vitals.bar_end = 220.0
	vitals.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	vitals.offset_left = 24.0
	vitals.offset_right = 24.0 + 340.0
	vitals.offset_top = -262.0
	vitals.offset_bottom = -206.0
	vitals.visible = false
	_root.add_child(vitals)

	_hurt_wash = ColorRect.new()
	_hurt_wash.name = "HurtWash"
	_hurt_wash.color = Color(0.85, 0.05, 0.05, 0.0)
	_hurt_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hurt_wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_hurt_wash)


	# Bottom right, above the field line: what is in hand and how much is in it. The play test
	# found a gun with no counter anywhere; dot-ui's DotAmmoCounter is the family's one.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo.offset_left = -420.0
	ammo.offset_right = -24.0
	ammo.offset_top = -176.0
	ammo.offset_bottom = -100.0
	ammo.visible = false
	_root.add_child(ammo)

	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(hit_marker)

	_field = _label(size)
	_field.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_field.offset_left = -400.0
	_field.offset_right = -30.0
	_field.offset_top = -80.0
	_field.offset_bottom = -26.0
	_field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Bottom middle, above where the chat box's input line opens, and under nothing else:
	# the health number is bottom-left and the field bottom-right, and a player who is out
	# has no use for either.
	watching_label = _label(size)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_build_tilt()

	# Over the progress bar: where you are in the race, the number a runner glances for.
	_place = _label(size)
	_place.name = "Place"
	_place.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_place.offset_left = -150.0
	_place.offset_right = 150.0
	_place.offset_top = -82.0
	_place.offset_bottom = -50.0
	_place.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# A dot rather than a cross. For the whole first half there is nothing to aim at, and in
	# the second half every weapon in the pack has its own spread — so what a player needs is
	# "the point I am looking at", which is one pixel.
	var dot := ColorRect.new()
	dot.name = "Crosshair"
	dot.color = Color(1.0, 1.0, 1.0, 0.75)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dot.offset_left = -3.0
	dot.offset_top = -3.0
	dot.offset_right = 3.0
	dot.offset_bottom = 3.0
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dot)


## The progress bar: how much of the course is behind you.
func _build_tilt() -> void:
	_tilt_back = ColorRect.new()
	_tilt_back.name = "TiltBack"
	_tilt_back.color = Color(0.0, 0.0, 0.0, 0.42)
	_tilt_back.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_back.offset_left = -150.0
	_tilt_back.offset_right = 150.0
	_tilt_back.offset_top = -46.0
	_tilt_back.offset_bottom = -30.0
	_tilt_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_back)

	_tilt_fill = ColorRect.new()
	_tilt_fill.name = "TiltFill"
	_tilt_fill.color = Color(0.45, 0.82, 0.48, 0.9)
	_tilt_fill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_fill.offset_left = -150.0
	_tilt_fill.offset_right = -150.0
	_tilt_fill.offset_top = -46.0
	_tilt_fill.offset_bottom = -30.0
	_tilt_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_fill)


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	# An outline rather than a panel behind it. This HUD is drawn over a bright sky, dark
	# water and a grey deck in the same frame; white is unreadable over one and black
	# over another, and an outline is readable over all three and costs nothing. Its colour
	# and the words' are the menu's theme's (a Label under the root takes them), so a
	# player's theme reaches these lines too.
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


## The spectator line, or an empty string to take it away. See [WoSpectate.line_for].
func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds. What a special announces itself
## with, and what a round ending says.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


## The announcer's line, for a few seconds, under the course name. Newer replaces older.
func announce(text: String, seconds: float = 3.0) -> void:
	if _ticker == null:
		return

	_ticker.text = text
	_ticker_for = seconds


## "1st", "2nd", "3rd", "4th"...
static func ordinal(n: int) -> String:
	var tail := "th"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1:
				tail = "st"
			2:
				tail = "nd"
			3:
				tail = "rd"
	return "%d%s" % [n, tail]


func _process(delta: float) -> void:
	present_blind(delta)

	if _ticker_for > 0.0:
		_ticker_for -= delta
		if _ticker_for <= 0.0 and _ticker != null:
			_ticker.text = ""

	if game == null or game.config == null or _root == null:
		return

	var left := game.seconds_left()
	# No clock between rounds or while waiting: a plate reading 0:00 over "between rounds"
	# says the same thing twice. Red for the last ten seconds.
	var running := game.phase != WoGame.Phase.IDLE and game.sides_are_playable()
	strip.show_clock(
		DotScoreStrip.clock_text(left) if running else "", left <= LOW_CLOCK_SEC, _phase_line()
	)
	_special.text = str((game.stage.doc if game.stage != null else {}).get("name", ""))

	var fighting := game.phase == WoGame.Phase.FINALE or game.phase == WoGame.Phase.HANDOVER

	# The bar is the fight's, and the course's too unless `health_enabled` is off.
	var on_course := game.phase == WoGame.Phase.COURSE or game.phase == WoGame.Phase.COUNTDOWN
	var shows_health := fighting or (on_course and game.config.health_enabled)

	if player != null and player.health != null and shows_health and not player.watching:
		vitals.show_vitals(player.health.health, player.health.max_health)
		vitals.visible = true
		_feel_damage(player.health.health, delta)
	else:
		vitals.visible = false
		_health_seen = -1.0
		_hurt_flash = 0.0
		_hurt_wash.color.a = 0.0

	# Between courses of one round, said once.
	var number := game.course_number()
	if number != _course_seen:
		if number > 1 and game.phase == WoGame.Phase.COUNTDOWN:
			shout("COURSE %d OF %d" % [number, game.config.courses_per_round], 3.0)
		_course_seen = number

	if fighting:
		_field.text = "%d still up" % game.alive_count()
	else:
		_field.text = "%d across of %d" % [game.finished_count(), game.players.size()]

	_draw_ammo()

	_draw_progress()

	if _shout_for > 0.0:
		_shout_for -= delta

		if _shout_for <= 0.0:
			_shout.text = ""


## A drop in health flashes the screen's edge red and shakes the bar for a moment.
func _feel_damage(health: float, delta: float) -> void:
	if _health_seen >= 0.0 and health < _health_seen - 0.01:
		_hurt_flash = HURT_FLASH_SEC
	_health_seen = health

	if _hurt_flash > 0.0:
		_hurt_flash = maxf(_hurt_flash - delta, 0.0)

	var k := _hurt_flash / HURT_FLASH_SEC
	_hurt_wash.color.a = 0.28 * k
	var t := float(Time.get_ticks_msec())
	var shake := Vector2(sin(t * 0.09), cos(t * 0.13)) * 6.0 * k
	vitals.offset_left = 24.0 + shake.x
	vitals.offset_right = 24.0 + 340.0 + shake.x
	vitals.offset_top = -262.0 + shake.y
	vitals.offset_bottom = -206.0 + shake.y


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if is_blind() else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0


## Whether the player this HUD follows is blinded.
func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


func _phase_line() -> String:
	if not game.sides_are_playable():
		return "waiting for players"

	match game.phase:
		WoGame.Phase.COUNTDOWN:
			return "get ready"
		WoGame.Phase.COURSE:
			if player != null and player.finished:
				return "finished #%d in %.1f s" % [player.place, player.finish_seconds]
			return "%.1f s" % game.course_elapsed
		WoGame.Phase.HANDOVER:
			if player != null and player.watching:
				return "the final death — you are watching"
			return "the final death — grab something"
		WoGame.Phase.FINALE:
			if player != null and player.watching:
				return "watching the final death"
			if player != null and player.grab != null and player.grab.is_carrying():
				return "carrying — click to throw, E to drop"
			return "last one standing — E picks things up"
		_:
			return "between rounds"


## The bar along the bottom: the checkpoints crossed out of the course's total, then full and
## gold once across. Hidden in an arena and behind an admin's blind.
func _draw_progress() -> void:
	if _tilt_fill == null or _tilt_back == null:
		return

	var on_course := game.stage != null and game.stage.is_course() and game.phase != WoGame.Phase.IDLE

	if player == null or not on_course or is_blind():
		_tilt_back.visible = false
		_tilt_fill.visible = false
		if _place != null:
			_place.text = ""
		return

	_tilt_back.visible = true
	_tilt_fill.visible = true

	if _place != null:
		var order := game.race_order()
		var at := order.find(player.player_id)
		_place.text = "%s of %d" % [ordinal(at + 1), order.size()] \
			if at >= 0 and order.size() > 1 and game.phase == WoGame.Phase.COURSE else ""

	# The finish counts as the last step, so the bar is full only across the line.
	var steps := game.stage.checkpoint_count() + 1
	var done := steps if player.finished else player.checkpoint + 1
	var fraction := clampf(float(done) / float(maxi(steps, 1)), 0.0, 1.0)
	_tilt_fill.offset_right = -150.0 + 300.0 * fraction
	_tilt_fill.color = Color(0.98, 0.80, 0.30, 0.95) if player.finished \
		else Color(0.40, 0.72, 0.95, 0.9)


## A hit the server confirmed for this player's shot: the marker, larger and red on a kill.
func confirm_hit(killed: bool, headshot: bool) -> void:
	if hit_marker != null:
		hit_marker.flash(killed, headshot)


## The counter, from the rig this player draws: the magazine and the reserve, low at a quarter
## of a magazine; a melee weapon by its name alone; hidden unarmed, dead or blind.
func _draw_ammo() -> void:
	if ammo == null:
		return

	var rig: ZeeWeaponRig = null
	if weapons_fn.is_valid():
		rig = weapons_fn.call() as ZeeWeaponRig

	var def := rig.current_def() if rig != null and is_instance_valid(rig) and rig.arsenal != null else null
	var shown := def != null and player != null and is_instance_valid(player) and player.is_alive() \
		and not is_blind()
	ammo.visible = shown

	if not shown:
		ammo.clear()
		return

	var title := def.display_name if def.display_name != "" else String(def.id)
	var held := rig.arsenal.current()

	if def.ammo_type == &"" or held == null:
		ammo.show_ammo(title, -1, -1)
		return

	var reserve := rig.arsenal.ammo().count(def.ammo_type)

	if def.magazine > 0:
		ammo.show_ammo(title, held.magazine, reserve,
			float(held.magazine) <= float(def.magazine) * 0.25, def.infinite_reserve)
	else:
		ammo.show_ammo(title, reserve, -1, reserve <= 0, false)
