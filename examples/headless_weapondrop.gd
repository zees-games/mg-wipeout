extends "headless_run_rig.gd"

const WoWeaponNet := preload("../game/net/wo_weapon_net.gd")

## Dropped guns in the final death: the drop key, pickup, a dead fighter's gun, floor clearing, the
## sv_weapon_drop* cvars, and the same floor on a client.
## Run: godot --headless --path . res://examples/headless_weapondrop.tscn

const SECTIONS := 3
const CHECKS := 14


class FakeBridge extends RefCounted:
	var wire: Array = []

	func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
		wire.append([peer_id, kind, body])

	func _broadcast(kind: int, body: PackedByteArray) -> void:
		wire.append([0, kind, body])

	func announce_armed(_id: StringName, _weapon: StringName) -> void:
		pass

	func session_of(_id: StringName) -> int:
		return 1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-wipeout: weapon drops")
	await _test_throw_and_pickup()
	await _test_death_and_clearing()
	await _test_wire()
	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


## A world in the final death with Ada armed off the floor, Bo on the other side, Cy watching.
func _finale() -> WoGame:
	var game := await _world(func(c: WoConfig) -> void:
		c.countdown_seconds = 0.2
		c.handover_seconds = 0.5
		c.finale_props_per_side = 1
		c.finale_weapons_per_side = 2
	)
	var a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	var _c := game.add_player(&"u3", "Cy")
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	a.place_at(finish["at"], 0.0)
	await _step(game, 2)
	_b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	game.course_elapsed = game.course_limit()
	await _step(game, 2)
	await _step(game, int(0.6 * TICK_RATE))
	var weapon: StringName = game.pickups[game.pickups.keys()[0]]["weapon"]
	var _armed := game.arm(a, weapon)
	return game


func _test_throw_and_pickup() -> void:
	_section("Throw and pickup")
	var game := await _finale()
	var layer = game.weapon_layer
	var ada: WoPlayer = game.players[&"u1"]
	var rules: DotWeaponDropRules = game.drop_rules
	if not _check(game.phase == WoGame.Phase.FINALE and layer != null and ada.weapons != null, "the game builds a layer and Ada is armed in the final death"):
		return
	_check(layer.drops.is_authority, "the server layer is authoritative")

	rules.key_enabled = false
	_check(layer.throw_for(&"u1") == 0, "sv_weapon_drop_key 0 throws nothing")
	rules.key_enabled = true
	_check(layer.throw_for(&"u3") == 0, "a watcher throws nothing")

	var id: int = layer.throw_for(&"u1")
	_check(id > 0 and layer.drops.count() == 1, "the key throws the gun in hand")

	var entry: Dictionary = layer.drops.snapshot()[0]
	ada.controller.state.position = (entry["at"] as Transform3D).origin - Vector3.UP * 0.5
	layer.drops.tick(5.0)
	layer.tick()
	_check(layer.drops.count() == 0, "a fighter in reach takes the gun back")
	_finished()


func _test_death_and_clearing() -> void:
	_section("Death and clearing")
	var game := await _finale()
	var layer = game.weapon_layer
	_fell(game, game.players[&"u1"])
	_check(layer.drops.count() == 1, "a dead fighter leaves the gun lying")
	layer.clear()
	_check(layer.drops.count() == 0, "clearing empties the floor")

	var g2 := await _finale()
	g2.drop_rules.on_death = false
	_fell(g2, g2.players[&"u1"])
	_check(g2.weapon_layer.drops.count() == 0, "sv_weapon_drop_death 0 leaves nothing")
	_finished()


func _test_wire() -> void:
	_section("Wire")
	var game := await _finale()
	var layer = game.weapon_layer
	var bridge := FakeBridge.new()
	var server_net := WoWeaponNet.new()
	var client_net := WoWeaponNet.new()
	var lost: Array = []
	client_net.lost_received.connect(func(session_id: int, weapon_id: StringName) -> void: lost.append([session_id, weapon_id]))
	server_net.attach(bridge)
	server_net.watch(layer)

	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.course_ids = PackedStringArray(["wo_practice"])
	var client := WoGame.new()
	client.name = "Client"
	client.config = config
	client.tick_rate = TICK_RATE
	client.authoritative = false
	client.register_service = false
	add_child(client)
	client.set_physics_process(false)
	_worlds.append(client)
	await _physics_frame()
	await _physics_frame()
	var mirror = client.weapon_layer
	_check(not client_net.apply(WoEvents.Kind.PICKUP, DotNetReader.new(PackedByteArray()), mirror),
		"another game event is left to the bridge")
	var id: int = layer.throw_for(&"u1")
	_check(id > 0 and bridge.wire.size() >= 1, "a throw puts events on the wire", str(bridge.wire.size()))
	for item in bridge.wire:
		var _ok := client_net.apply(item[1], DotNetReader.new(item[2]), mirror)
	bridge.wire.clear()
	_check(mirror.drops.count() == 1 and mirror.drops.has_drop(id), "the client draws the same drop under the same id")
	_check(lost.size() == 1, "the thrower is told the gun left their hands")

	server_net.send_snapshot(7, layer)
	_check(bridge.wire.size() == layer.drops.count(), "a joiner is sent every gun lying")
	layer.clear()
	_finished()


## A fighter dies the way a fall kills: damage from nobody, stamped with the tick.
func _fell(game: WoGame, victim: WoPlayer) -> void:
	var fall := DotDamage.make(0, victim.entity_id, 10000.0, null)
	fall.tick = game._tick
	fall.context = {"why": WoGame.DIED_FELL}
	var _applied := game.combat.apply_damage(fall)
