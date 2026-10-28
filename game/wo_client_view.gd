extends Node
## The client's state, its weapons drawn and picked up, and the HUD, board and chat it builds.

const WoAnnouncer := preload("wo_announcer.gd")
const WoAudio := preload("wo_audio.gd")
const WoWeaponIcons := preload("wo_weapon_icons.gd")
const WoBindings := preload("wo_bindings.gd")
const WoFigure := preload("wo_figure.gd")
const WoKillcam := preload("wo_killcam.gd")
const WoSettings := preload("wo_settings.gd")
const WoServices := preload("wo_services.gd")
const WoPlayerNet := preload("net/wo_player_net.gd")
const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoNetCommand := preload("net/wo_net_command.gd")
const WoEvents := preload("net/wo_events.gd")
const WoConfig := preload("wo_config.gd")
const WoGame := preload("wo_game.gd")
const WoWeatherView := preload("wo_weather_view.gd")
const WoHud := preload("wo_hud.gd")
const WoBlurb := preload("wo_blurb.gd")
const WoPaths := preload("wo_paths.gd")
const WoPlayer := preload("wo_player.gd")

const CHANNEL := "wo.client"

var game: WoGame = null

var player: WoPlayer = null

var camera: Camera3D = null

## Rain and lightning, drawn. See [WoWeatherView].
var weather: WoWeatherView = null

var hud: WoHud = null

## The course introduction, top left (under [member hud]).
var blurb_label: WoBlurb = null

## The Tab board, the menu's. See [method _wire_board].
var board: DotMenuScoreboard = null

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()

var chat: DotGameChatClient = null

## What the game sounds like. See [WoAudio].
var audio: WoAudio = null

## The show's voice: lines, the announcer and the crowd. See [WoAnnouncer].
var announcer: WoAnnouncer = null

## The player's own settings and the screen Escape opens. See [WoSettings].
var settings: WoSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null

## The weapons in this player's own hands, once they have picked one up in a final death.
## Drawn, never decided: every shot that matters is the server's; the rig is for a view model
## that moves, as a weapon that never animates reads as a texture stuck to the screen.
var weapons: ZeeWeaponRig = null

var view_model: ZeeViewModel = null

var net: DotNetManager = null

## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null

## The tuning panel's host: F9 solo, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null

var bridge: WoNetBridge = null

var link: Node = null

var _offline: bool = true

## The final killcam ([WoKillcam]) and the winner reveal, which play in the intermission.
var killcam: WoKillcam = null

var winner_reveal: DotWinnerReveal = null

var _reveal_hid: Dictionary = {}

var _sampler: DotFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null

var _roam_look: Vector2 = Vector2.ZERO

## Which session this client is, once the server has said. -1 until then, so nothing matches
## before it does.
var _watch_id: int = -1

## The stage last introduced, and when, so one stage is introduced once. See [method _on_stage].
var _introduced: StringName = &""

var _introduced_msec: int = -1000000

## The course time this frame drew the obstacles at, or a negative before the first.
var _stage_seconds: float = -1.0

## The camera rig, in third person. Null in first.
var _arm: DotCameraBoom = null

var _fade: DotCameraFade = null

## How far above the player's feet the camera, or in third person the arm, is hung.
var _rig_height: float = 0.0

## Held buttons, read once a tick rather than sampled from an event queue.
var _firing: bool = false

var _alt: bool = false

var _reloading: bool = false

var _slot: int = 0

## The grab key, held. Picks up or puts down a prop in a final death; see `WoGame._advance_grabs`.
var _grab: bool = false

## pickup id -> the model spinning where a weapon lies. Client side.
var _pickup_nodes: Dictionary = {}

## The knocks this client last saw on its own player, so a new one shakes the screen once.
var _knocks_seen: int = 0

## The last whole second of the countdown a beep was played for.
var _beeped: int = -1

## Keeps the screen covered, and the local body, the keys and the clocks still, until the course
## is built, the local player exists and its camera is current.
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null

## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null

## Simulated seconds the drawn gun has gone without a trigger, a reload or a switch.
var _drawn_quiet: float = 0.0


## Overridden by the node, which owns the camera.
func _build_camera() -> void:
	pass


## dot-game's chat box and microphone, with this game's channels and voice format, and dot-server's
## own lines (arriving on the shell's client link, not the bridge). Static so a suite builds the
## same box the client does.
static func new_chat() -> DotGameChatClient:
	var box := DotGameChatClient.new()
	box.name = "Chat"
	box.channels = [
		{"id": WoServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": WoServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": WoServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	box.max_length = WoServices.chat_rules().max_length
	box.voice_config = WoServices.voice_format()
	return box


## A weapon lying in the arena: its own model, spinning a little over the floor. Drawn only.
func _on_pickup(pickup_id: int, weapon_id: StringName, at: Vector3) -> void:
	if _pickup_nodes.has(pickup_id):
		return

	var holder := Node3D.new()
	holder.name = "Pickup_%d" % pickup_id
	add_child(holder)
	holder.global_position = at + Vector3(0.0, 0.3, 0.0)

	var art := ZeeWeaponArtTable.get_art(weapon_id)
	var model: Node3D = ZeeModelCache.instantiate(art.model_path) if art != null and art.model_path != "" else null

	if model == null:
		# A weapon with no art (fists, or a pack whose art did not load) is still a thing to
		# pick up, so something has to stand there.
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.5, 0.2, 0.2)
		box.mesh = mesh
		model = box

	model.scale = Vector3.ONE * 1.6
	holder.add_child(model)

	# A light under it, so a weapon on a grey floor reads from across the arena.
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.4)
	glow.light_energy = 0.8
	glow.omni_range = 2.2
	holder.add_child(glow)
	_pickup_nodes[pickup_id] = holder


func _on_pickup_gone(pickup_id: int, _by: int) -> void:
	var holder: Node3D = _pickup_nodes.get(pickup_id)
	_pickup_nodes.erase(pickup_id)

	if holder != null and is_instance_valid(holder):
		if audio != null:
			var _heard := audio.on_pickup(holder.global_position)
		holder.queue_free()


func _clear_pickups() -> void:
	for pickup_id: int in _pickup_nodes.keys():
		var holder: Node3D = _pickup_nodes[pickup_id]

		if is_instance_valid(holder):
			holder.queue_free()

	_pickup_nodes.clear()



## Builds a view model for this player's own hands when they pick a weapon up. Drawn, never
## decided (`authority` is false): the server owns every shot, and a gun that never deploys,
## reloads or kicks cannot be told from one that is not ready.
func _arm_locally(weapon_id: StringName = &"") -> void:
	if player == null:
		return

	if weapons != null:
		_give_locally(weapon_id)
		_select_locally(weapon_id)
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.tick_rate = game.tick_rate
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {
			"why": ready_now.error.message,
		})
		_disarm_locally()
		return

	# Only what the server armed, one weapon as each is armed (`player_armed` / ARMED), never the
	# whole pack: `give_everything` filled five slots, so the drawn gun was not the one the server
	# fired.
	_give_locally(weapon_id)

	# Your own shots, from your own rig: a predicted use, heard the tick it happens rather
	# than when the server's snapshot says it did. At the camera, so it is at full volume.
	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(
				camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)
			)
	)

	_select_locally(weapon_id)


## Puts the weapon just picked up in hand, on its own slot, here and in what is sent.
func _select_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return

	var def := weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		_slot = def.slot


func _give_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return
	if weapons.arsenal != null and weapons.arsenal.carries(weapon_id):
		return
	var given := weapons.give(weapon_id)
	if not given.ok:
		DotLog.warn(CHANNEL, "the drawn rig refused a weapon", {"weapon": String(weapon_id), "why": given.error.message})


func _disarm_locally() -> void:
	if weapons != null:
		player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


func _build_hud() -> void:
	hud = WoHud.new()
	# The counter reads the gun this player sees (corrected from the server's by correct_drawn).
	hud.weapons_fn = func() -> ZeeWeaponRig: return weapons
	hud.name = "Hud"
	add_child(hud)
	blurb_label = WoBlurb.new()
	hud.add_child(blurb_label)



## The Tab board: dot-menu's, with this game's columns. Built once the menu exists (see
## [method _build_settings]). Online it is the server's roster (names, pings, time on) with this
## game's replicated numbers joined in by id; offline it is [method board_snapshot], all local.
func _dress_board() -> void:
	if board == null:
		return
	board.title_text = "Wipeout"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"place", "title": "Place", "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_with = func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("points", 0)) != int(b.get("points", 0)):
			return int(a.get("points", 0)) > int(b.get("points", 0))
		return str(a.get("name", "")) < str(b.get("name", ""))
	board.decorate = _decorate_row
	board.prepare = _prepare_board


## This game's numbers onto a row of the server's roster, by id.
func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var who: WoPlayer = game.players.get(WoNetBridge.player_key(int(row.get("id", 0))))
	if who == null:
		who = game.players.get(StringName(str(row.get("id", ""))))
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["place"] = str(who.place) if who.finished else ("out" if who.watching else "-")
	row["team"] = who.team
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The course in the header, and the sides when the round has them.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Course": str(game.course_doc.get("name", ""))}
	if game.config.teams():
		var sides: Array = []
		for side in range(1, game.config.team_count + 1):
			sides.append({"id": side, "name": game.side_name(side), "color": game.side_colour(side)})
		snap["teams"] = sides


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var players: Array = []
	if game != null:
		for id in game.players:
			var who: WoPlayer = game.players[id]
			players.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Wipeout", "game": "offline"}, "players": players}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


## The player's face for the board: their figure's head, rendered once per skin. Every Blocky
## Character is one mesh and the six people `WoFigure` draws are six atlases, so six 64-pixel
## portraits cover everyone; the board asks every frame, so each is rendered once and kept.
var _portraits: Dictionary = {}

func _face(who: WoPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := WoFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# In front of the face (a figure looks down -Z) and a touch above it, looking back.
	eye.look_at_from_position(Vector3(0.0, 1.55, -1.6), Vector3(0.0, 1.45, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


## The chat box, before the netcode and before any player exists. Built in both halves and attached
## to the bridge afterwards: a box built after the first line arrived would miss the backlog.
func _build_chat() -> void:
	chat = new_chat()
	add_child(chat)


## Walking off and on: typing, or the settings screen up. Both samplers, because offline the
## player samples for themselves and connected the client does.
func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
