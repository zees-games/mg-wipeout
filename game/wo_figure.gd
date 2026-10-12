extends Node3D

const WoPaths := preload("wo_paths.gd")

## What somebody ELSE looks like: a Kenney blocky character, scaled to the player's hull,
## wearing their side's colour on the torso and turned to where they are looking. Client
## side only; a server never builds one.
##
## [b]This game drew no person at all until 2026-09-24.[/b] Every player's own view was
## first person, and third person showed the platform rather than the player — so nobody had
## needed a body until a networked client, whose other players were drawn as nothing. Their
## node moved, their beacon marked them, and a platform leaned toward a patch of empty deck.
## See `WoPlayer.present_body` for when one is shown.
##
## [b]Top level, and placed by its caller every frame.[/b] The player node is the
## simulation's: on a remote player it is written by the interpolator once a frame, but on
## the local player and on every offline stand-in it moves once a TICK, and a body hung off
## it would step at the tick rate while the camera beside it is blended between ticks. So
## `WoClient.present_frame` hands every body the position this frame draws — the node for a
## remote player, `render_state()` for one this process simulates — and nothing here
## computes one.
##
## [b]One of the family's people[/b] (dot-player-char's `DotHumanoidFigure`: animated, on the
## rig every game's players, bots and NPCs share, the same style as the zombies of the family's
## zombie game), because a player is somebody to see coming and a capsule does not say which way
## somebody is facing from forty metres. Which person a player is still comes from the blocky
## kit's atlas their avatar names ([constant ATLASES]): the atlas letter is a look
## (`DotHumanoidLook.from_letter`), so every avatar document written before the people arrived
## dresses the same person on every client. [b]The side is on the top[/b], [constant TEAM_TINT] of
## the way: the first thing anybody needs to read off a body is whose side it is on.
##
## [b]The weapon is in the person's own hand[/b] (`DotHumanoidFigure.attachment`, the gun hand of
## the kit's clips), so it moves with the gun clips and a melee swing; the legs keep walking under
## a swing because the figure plays it on the upper body only.

const CHANNEL := "wo.figure"

## The people a player can be, by the blocky kit's atlas letters (the avatar documents name them).
## Only the letter is read: the people are coloured, not textured.
static var ATLASES: Array[String] = [
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-a.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-b.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-c.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-e.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-f.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-k.png"),
]

## How much of the side's colour goes on the top.
const TEAM_TINT := 0.62

## Which atlas this figure wears, and the side colour on it. Read by the suite.
var atlas: String = ""
var team_colour: Color = Color.WHITE

## Whether the people's art loaded, or a capsule stands in.
var from_art: bool = false

## The clip playing, for the suite and for `describe()`.
var clip: StringName = &""

## The weapon this figure is drawn holding, by id; empty for empty hands. Read by the suite.
var holding: StringName = &""

## The gun in the hand. Built the first time this figure holds anything; see [method hold].
var held: ZeeWorldModel = null

## Whether this figure is drawn carrying something in both hands: a prop on the gravity gun.
## Read by the suite. Drawn as the person's held-gun arms, out in front: with the arms at
## their sides a carried prop read as a crate following somebody about.
var carrying: bool = false:
	set(value):
		carrying = value
		_set_hold_kind()

## The person, under this node.
var person: DotHumanoidFigure = null

var _posed_at_usec: int = -1


func _init() -> void:
	# The caller places it; see the class note.
	top_level = true


## Builds the figure to stand [param height] metres tall, feet at this node's origin, as the
## person [param atlas_path]'s letter is, with [param colour] on the top.
func build(height: float, atlas_path: String, colour: Color) -> void:
	atlas = atlas_path
	team_colour = colour
	clip = &""
	_posed_at_usec = -1
	# The gun hung off the old person's hand and goes with it; [method hold] builds it again on
	# the next frame, from [member holding], which outlives a rebuild.
	held = null
	var look := DotHumanoidLook.from_letter(atlas_path)
	if look == null:
		look = DotHumanoidLook.stock(hash(atlas_path))
	if colour != Color.WHITE:
		look = look.with_side(colour, TEAM_TINT)
	if person != null:
		remove_child(person)
		person.queue_free()
	person = DotHumanoidFigure.new()
	person.name = "Person"
	add_child(person)
	person.build(look, height)
	from_art = person.from_art


## The drawn model, for a death that breaks it apart or falls. Null before [method build].
func body_node() -> Node3D:
	return person


## How the player moves besides its ground speed: `on_floor`, `vertical`, `crouched`, `downed`
## and the rest [method DotHumanoidFigure.set_motion] reads.
func set_motion(motion: Dictionary) -> void:
	if person != null:
		person.set_motion(motion)


## Puts the figure where this frame draws its player, facing [param yaw_radians], moving at
## [param speed] metres a second over the ground.
func pose(at: Vector3, yaw_radians: float, speed: float) -> void:
	global_position = at
	rotation = Vector3(0.0, yaw_radians, 0.0)
	if person == null:
		return
	var now := Time.get_ticks_usec()
	# A figure that was hidden for a minute is not a minute behind: clamped.
	var delta := 0.0 if _posed_at_usec < 0 else clampf((now - _posed_at_usec) / 1e6, 0.0, 0.1)
	_posed_at_usec = now
	person.animate(speed, delta)
	clip = person.clip


## Draws [param id] in the right hand, or nothing for an empty id. [param switching] hides
## it mid-switch, the way [ZeeWorldModel] does.
##
## [b]Asked every frame and cheap when nothing changed[/b]: the model is only re-equipped
## when the id differs from what is drawn.
func hold(id: StringName, switching: bool) -> void:
	holding = id

	if id == &"":
		if held != null:
			held.visible = false
		_set_hold_kind()
		return

	if held == null:
		held = ZeeWorldModel.new()
		held.name = "Held"
		# This game has its own sound for somebody else's shot, by kind, played from the
		# counter (`WoAudio.on_weapon`); the hand draws the flash and the tracer. By name,
		# for a shell older than the property: see its own note.
		held.set(&"sounds", false)

		if not held.attach_to(self):
			held.free()
			held = null
			return

	if held.equipped() != id:
		var art: Variant = ZeeWeaponArtTable.table().get(id)

		if art is ZeeWeaponArt:
			var _drawn := held.equip(art as ZeeWeaponArt)
		else:
			held.clear()

	held.visible = true
	held.on_switching(switching)
	_set_hold_kind()


## The arms the person holds this weapon with: a gun's (the kit's gun clips), a melee weapon's
## (ordinary arms, a slash to swing) or empty hands.
func _set_hold_kind() -> void:
	if person == null:
		return
	if carrying:
		person.set_hold(DotHumanoidFigure.Hold.GUN)
		return
	if holding == &"" or held == null or not held.visible:
		person.set_hold(DotHumanoidFigure.Hold.NONE)
		return
	var art: Variant = ZeeWeaponArtTable.table().get(holding)
	var pose: StringName = (art as ZeeWeaponArt).pose if art is ZeeWeaponArt else ZeeWeaponArtTable.POSE_RIFLE
	if pose == ZeeWeaponArtTable.POSE_MELEE:
		person.set_hold(DotHumanoidFigure.Hold.MELEE)
	elif pose == ZeeWeaponArtTable.POSE_THROWN:
		person.set_hold(DotHumanoidFigure.Hold.NONE)
	else:
		person.set_hold(DotHumanoidFigure.Hold.GUN)


## The weapon in this figure's hand was used [param times] times, as a [ZeeWeaponNet] kind.
## One kick however many, as `ZeeWeaponNet.apply` does: a burst's recoil in one frame reads
## as the gun jumping out of the hand.
func fired(times: int, kind: int) -> void:
	if times <= 0 or held == null or not held.visible:
		return

	held.on_fired(WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)

	# [b]A swing is the arm, not a kick[/b]: the person's slash, over whatever the legs do.
	if kind == ZeeWeaponNet.KIND_SWING and person != null:
		person.swing(DotHumanoidClips.SLASH)


## The node a held weapon hangs from, by the name [ZeeWorldModel] asks for: the person's hand.
func attachment(point: StringName) -> Node3D:
	if person == null:
		return null
	return person.attachment(point)


## How far a watched gun kicks per kind of use, in the recoil's own degrees. The real
## recoil is on an outcome that does not travel, so a watcher's is approximate on purpose;
## game-arena's numbers.
const WATCHED_RECOIL := {
	ZeeWeaponNet.KIND_SWING: Vector2(1.2, 0.0),
	ZeeWeaponNet.KIND_SPAWN: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_THROW: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_BEAM: Vector2(0.05, 0.0),
}


func describe() -> Dictionary:
	return {
		"art": from_art,
		"atlas": atlas.get_file(),
		"visible": visible,
		"clip": String(clip),
		"holding": String(holding),
		"swinging": person != null and person.overlay != &"",
		"carrying": carrying,
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}
