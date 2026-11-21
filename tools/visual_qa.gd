extends GSGameVisualQaCapture

## Wipeout's visual QA capture (the loop is gs-game's docs/visual-qa.md), frame by frame at --fps in three views
## (f first person, t behind-right, o an opponent in front). Items: person_<letter> (one of the six WoFigure people idling, walking, running, crouching, jumping and carrying a prop; f is a rival's eye a few metres ahead), object_* (the course objects, see visual_qa_course.gd), weapon_<id> (f the real ZeeViewModel with its arms, t and o the person holding it through draw, fire and reload).
## The outside views and frame saving are gs-game's GSGameVisualQaViews, through GSGameVisualQaCapture.

const WoFigure := preload("../game/wo_figure.gd")
const WoCatalogue := preload("../game/wo_catalogue.gd")
const CourseItems := preload("visual_qa_course.gd")

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
var _course_items := CourseItems.new()
var _runner_speed := 0.0
## The stage's floor, sun and sky, hidden while a built course (with its own) is filmed.
var _stage_dressing: Array[Node] = []


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for path in WoFigure.ATLASES:
		items.append("person_" + path.get_file().get_basename().trim_prefix("texture-"))
	for def in ZeeWeaponPack.weapons():
		_weapon_defs[String(def.id)] = def
		if DEFAULT_POOL.has(def.id):
			items.append("weapon_" + String(def.id))
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	items.append_array(_course_items.items(catalogue))
	return items


func _clips(item: String) -> PackedStringArray:
	if _course_items.has(item):
		return _course_items.clips(item)
	return PERSON_CLIPS if item.begins_with("person_") else WEAPON_CLIPS


func _seconds(item: String, clip: String) -> float:
	if _course_items.has(item):
		return _course_items.seconds(item)
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	if limits_path == "":
		limits_path = "res://tools/visual_qa_thresholds.json"
	build_stage()
	first_person.cull_mask = ALL_LAYERS & ~BODY_LAYER
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	root.add_child(_holder)
	for child in stage.get_children():
		if child is MeshInstance3D or child is DirectionalLight3D or child is WorldEnvironment:
			_stage_dressing.append(child)


func _stage(item: String, clip: String) -> GSResult:
	_clear()
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	views.opponent_offset = Vector3(0.4, 1.6, -4.0)
	views.opponent_look_height = 1.3
	_set_stage_dressing(not _course_items.has(item))
	if _course_items.has(item):
		# From behind and to the right, and from the runner's left front, so the object is in both views.
		views.behind_offset = Vector3(2.2, 2.1, 4.5)
		views.behind_look_height = 1.3
		views.opponent_offset = Vector3(-3.4, 1.7, -1.0)
		views.opponent_look_height = 1.3
		_shown_kind = "course"
		_shown_id = item
		var staged := _course_items.stage(_holder, item, clip)
		if not staged.ok:
			return staged
		_stand_person("a")
		return GSResult.success(clip)
	if item.begins_with("weapon_"):
		# Straight ahead, a held gun points down the lens and draws as a thin stick; from the gun-hand side it reads in profile.
		views.behind_offset = Vector3(2.4, 1.5, 2.2)
		views.opponent_offset = Vector3(3.0, 1.3, -2.2)
		views.opponent_look_height = 1.0
		var id := StringName(item.trim_prefix("weapon_"))
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if not (art is ZeeWeaponArt):
			return GSResult.fail(GSError.CODE_INVALID, "no art for %s" % id)
		var def: GSWeaponDef = _weapon_defs.get(String(id))
		if clip == "reload" and (def == null or not def.uses_magazine()):
			return GSResult.fail(GSError.CODE_UNSUPPORTED, "%s has no magazine" % id)
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
	return GSResult.success(clip)


func _set_stage_dressing(shown: bool) -> void:
	for node in _stage_dressing:
		if node is WorldEnvironment:
			if shown and node.get_parent() == null:
				stage.add_child(node)
			elif not shown and node.get_parent() != null:
				stage.remove_child(node)
		else:
			node.visible = shown


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
	if _shown_kind == "course":
		_drive_course(t)
		return
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


## A runner in the built course: the course posed at [param t], the figure where the capture puts it, facing -Z.
func _drive_course(t: float) -> void:
	var step := 1.0 / float(fps)
	var runner := _course_items.drive(t)
	var speed := float(runner["speed"])
	_figure.global_position = runner["at"]
	_figure.rotation = Vector3(0.0, deg_to_rad(float(runner.get("yaw", 0.0))), 0.0)
	_figure.set_motion({"on_floor": true, "vertical": 0.0, "crouched": false, "sprinting": speed > 4.0,
		"aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.person.animate(speed, step)


func _drive_weapon(clip: String, t: float, step: float) -> void:
	var id := StringName(_shown_id.trim_prefix("weapon_"))
	var art := ZeeWeaponArtTable.table().get(id) as ZeeWeaponArt
	match clip:
		"draw":
			_model.on_deploy(clampf(t / 0.6, 0.0, 1.0))
			_figure.hold(id, t < 0.3)
		"fire":
			var def: GSWeaponDef = _weapon_defs.get(String(id))
			var every := _fire_interval(def)
			var due := int(floor((t - 0.2) / every)) + 1 if t >= 0.2 else 0
			while _shots_done < due:
				_shots_done += 1
				_fire(art)
		"reload":
			var def2: GSWeaponDef = _weapon_defs.get(String(id))
			if t < step:
				_model.on_reload_begin(0, def2.magazine)
			_model.on_reload(clampf(t / 2.6, 0.0, 1.0))
	_model.advance(step)


func _fire_interval(def: GSWeaponDef) -> float:
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
		var outcome := GSWeaponOutcome.of(GSWeaponOutcome.KIND_THROW)
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
		var _tagged := GSGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


## Weapons: the real view model's camera at the person's eye. People: a rival's eye 2.5 m in front, looking at the subject.
func _place_first_person(_item: String) -> void:
	if _shown_kind == "weapon" or _shown_kind == "course":
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
