extends DotGameVisualQaCapture

## Wipeout's visual QA capture (the loop is dot-game's docs/visual-qa.md). Two kinds of item, each recorded frame by frame
## at --fps in three views (f first person, t behind-right, o an opponent in front):
##   person_<letter>  one of the six people (WoFigure) idling, walking, running, crouching, jumping and carrying a prop on the gravity gun; f is a rival's eye a few metres in front.
##   weapon_<id>      a weapon of the game's default pool: f is the real view model (ZeeViewModel with its arms) at the eye,
##                    t and o draw the person holding it (WoFigure.hold) through draw, fire and reload.
## The outside views and frame saving are dot-game's DotGameVisualQaViews, through DotGameVisualQaCapture.

const WoFigure := preload("../game/wo_figure.gd")

## Your own body draws only in the outside views; the view model (ZeeViewModel's view_layer 20) only in the first-person one.
const BODY_LAYER := 1 << 18
const ALL_LAYERS := 0xFFFFF
const BODY_HEIGHT := 1.8
const PERSON_CLIPS: PackedStringArray = ["idle", "walk", "run", "crouch", "jump", "carry"]
const WEAPON_CLIPS: PackedStringArray = ["idle", "draw", "fire", "reload"]
## Ground speed per person clip (metres a second), about the game's walk and run.
const PERSON_SPEED := {"idle": 0.0, "walk": 2.9, "run": 6.5, "crouch": 2.9, "jump": 2.9, "carry": 2.9}
const SECONDS := {"idle": 2.0, "walk": 2.4, "run": 2.0, "crouch": 2.0, "jump": 1.6, "carry": 2.0, "draw": 1.0, "fire": 2.0, "reload": 3.0}
## Seconds between shots in the fire clip when a weapon has no use interval; otherwise its own, as in a match.
const FIRE_EVERY := 0.5
## bone_pop limit in a fire clip whose arm swings or throws: a real strike turns the forearm about 1700 deg/s.
const STRIKE_POP_DEG := 130.0
## The weapons the game hands out when its weapon_pool is empty (`WOGame._weapon_pool`); a pool set in config is not read here.
const DEFAULT_POOL: Array[StringName] = [ZeeWeaponIds.REVOLVER, ZeeWeaponIds.SMG, ZeeWeaponIds.CARBINE, ZeeWeaponIds.RIFLE, ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.DRUM_SHOTGUN, ZeeWeaponIds.MARKSMAN, ZeeWeaponIds.LAUNCHER, ZeeWeaponIds.HATCHET, ZeeWeaponIds.MALLET]

var _figure: WoFigure = null
var _model: ZeeViewModel = null
var _holder := Node3D.new()
var _shown_kind := ""
var _shown_id := ""
var _shots_done := 0
var _weapon_defs := {}
var _struck := false


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for path in WoFigure.ATLASES:
		items.append("person_" + path.get_file().get_basename().trim_prefix("texture-"))
	for def in ZeeWeaponPack.weapons():
		_weapon_defs[String(def.id)] = def
		if DEFAULT_POOL.has(def.id):
			items.append("weapon_" + String(def.id))
	return items


func _clips(item: String) -> PackedStringArray:
	return PERSON_CLIPS if item.begins_with("person_") else WEAPON_CLIPS


func _seconds(_item: String, clip: String) -> float:
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	build_stage()
	first_person.cull_mask = ALL_LAYERS & ~BODY_LAYER
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	root.add_child(_holder)


func _stage(item: String, clip: String) -> DotResult:
	_clear()
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	views.opponent_offset = Vector3(0.4, 1.6, -4.0)
	views.opponent_look_height = 1.3
	if item.begins_with("weapon_"):
		# Straight ahead, a held gun points down the lens and draws as a thin stick; from the gun-hand side it reads in profile.
		views.behind_offset = Vector3(2.4, 1.5, 2.2)
		views.opponent_offset = Vector3(3.0, 1.3, -2.2)
		views.opponent_look_height = 1.0
		var id := StringName(item.trim_prefix("weapon_"))
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if not (art is ZeeWeaponArt):
			return DotResult.fail(DotError.CODE_INVALID, "no art for %s" % id)
		var def: DotWeaponDef = _weapon_defs.get(String(id))
		if clip == "reload" and (def == null or not def.uses_magazine()):
			return DotResult.fail(DotError.CODE_UNSUPPORTED, "%s has no magazine" % id)
		_shown_kind = "weapon"
		_stand_person("a")
		_figure.hold(id, false)
		_model = ZeeViewModel.new()
		_model.name = "ViewModel"
		first_person.add_child(_model)
		_model.set_process(false)
		var equipped := _model.equip(art as ZeeWeaponArt)
		if not equipped.ok:
			return equipped
		_model.on_deploy(1.0)
		_shots_done = 0
		_struck = false
	else:
		_shown_kind = "person"
		_stand_person(item.trim_prefix("person_"))
		_figure.carrying = clip == "carry"
	_shown_id = item
	return DotResult.success(clip)


func _stand_person(letter: String) -> void:
	_figure = WoFigure.new()
	_figure.name = "Figure"
	_holder.add_child(_figure)
	_figure.global_position = Vector3.ZERO
	var colour := Color(0.9, 0.35, 0.3) if _shown_kind == "weapon" else Color(0.3, 0.45, 0.9)
	_figure.build(BODY_HEIGHT, _atlas_of(letter), colour)


func _atlas_of(letter: String) -> String:
	for path in WoFigure.ATLASES:
		if path.ends_with("texture-%s.png" % letter):
			return path
	return WoFigure.ATLASES[0]


func _clear() -> void:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.free()
	if _model != null and is_instance_valid(_model):
		first_person.remove_child(_model)
		_model.free()
	_model = null
	_figure = null


func _subject(_item: String) -> Node3D:
	return _figure


## A person stands at the origin facing -Z; the person clips move it along -Z from behind so the stage is walked, not skated on.
func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var step := 1.0 / float(fps)
	var speed := float(PERSON_SPEED.get(clip, 0.0))
	var airborne := false
	var vertical := 0.0
	if clip == "jump":
		# A 0.6 s hop at the start, again at 1.0 s.
		var phase := fmod(t, 1.0) / 0.6
		airborne = phase < 1.0
		vertical = 4.0 * (1.0 - 2.0 * phase) if airborne else 0.0
		_figure.global_position.y = 4.0 * 0.15 * 4.0 * phase * (1.0 - phase) if airborne else 0.0
	_figure.set_motion({"on_floor": not airborne, "vertical": vertical, "crouched": clip == "crouch",
		"sprinting": clip == "run", "aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.global_position.z = -speed * t + (speed * float(SECONDS.get(clip, 2.0)) * 0.5)
	_figure.global_position.x = 0.0
	_figure.rotation = Vector3.ZERO
	_figure.person.animate(speed, step)
	if _shown_kind == "weapon":
		_drive_weapon(clip, t, step)


func _drive_weapon(clip: String, t: float, step: float) -> void:
	var id := StringName(_shown_id.trim_prefix("weapon_"))
	var art := ZeeWeaponArtTable.table().get(id) as ZeeWeaponArt
	match clip:
		"draw":
			_model.on_deploy(clampf(t / 0.6, 0.0, 1.0))
			_figure.hold(id, t < 0.3)
		"fire":
			var def: DotWeaponDef = _weapon_defs.get(String(id))
			var every := _fire_interval(def)
			var due := int(floor((t - 0.2) / every)) + 1 if t >= 0.2 else 0
			while _shots_done < due:
				_shots_done += 1
				_fire(art)
		"reload":
			var def2: DotWeaponDef = _weapon_defs.get(String(id))
			if t < step:
				_model.on_reload_begin(0, def2.magazine)
			_model.on_reload(clampf(t / 2.6, 0.0, 1.0))
	_model.advance(step)


func _fire_interval(def: DotWeaponDef) -> float:
	if def == null or def.use_interval_ticks <= 0:
		return FIRE_EVERY
	var rate := def.authored_tick_rate if def.authored_tick_rate > 0 else ZeeWeaponPack.TICK_RATE
	return float(def.use_interval_ticks) / float(rate)


func _fire(art: ZeeWeaponArt) -> void:
	_struck = art.pose == ZeeWeaponArtTable.POSE_MELEE or art.pose == ZeeWeaponArtTable.POSE_THROWN
	if art.pose == ZeeWeaponArtTable.POSE_MELEE:
		_model.on_swing()
		_figure.fired(1, ZeeWeaponNet.KIND_SWING)
	elif art.pose == ZeeWeaponArtTable.POSE_THROWN:
		var outcome := DotWeaponOutcome.of(DotWeaponOutcome.KIND_THROW)
		outcome.used = true
		_model.on_used(outcome)
		_figure.fired(1, ZeeWeaponNet.KIND_THROW)
	else:
		_model.on_fired()
		_figure.fired(1, ZeeWeaponNet.KIND_SHOT)


func _grounded(_item: String, clip: String, t: float) -> bool:
	return not (clip == "jump" and fmod(t, 1.0) < 0.6)


func _before_draw(_item: String, _clip: String, _frame: int) -> void:
	if _figure != null:
		var _tagged := DotGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


## Weapons: the real view model's camera at the person's eye. People: a rival's eye 2.5 m in front, looking at the subject.
func _place_first_person(_item: String) -> void:
	if _shown_kind == "weapon":
		first_person.global_position = _figure.global_position + Vector3(0.0, 1.6, 0.0)
		first_person.rotation = Vector3.ZERO
		return
	first_person.global_position = _figure.global_position + Vector3(0.0, 1.6, -2.5)
	first_person.look_at(_figure.global_position + Vector3(0.0, BODY_HEIGHT * 0.5, 0.0))


## A melee swing or a throw is a real strike: judge its forearm pop against the strike limit, as the gun's 90 would fail it.
func _checks(_item: String, clip: String, rows: Array[Dictionary]) -> Array[Dictionary]:
	if _shown_kind == "weapon" and clip == "fire" and _struck:
		for row: Dictionary in rows:
			if row["check"] == "bone_pop" and not row.get("skip", false):
				row["pass"] = float(row["value"]) <= STRIKE_POP_DEG
				row["limit"] = STRIKE_POP_DEG
				row["note"] = "%s (a strike or throw)" % row.get("note", "")
	return rows
