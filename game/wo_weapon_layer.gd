extends Node

## Guns lying in the world: dot-weapon's drop layer under the `sv_weapon_drop*` rules, built on the
## server (simulates; hands a gun to a fighter with a free slot) and on a client (draws what it is told).
## In the final death a fighter throws the gun in hand with the drop key, and a dead one leaves it where they fell.

const WoPlayer := preload("wo_player.gd")

## A gun left a fighter's hands (a throw or a death); the net layer tells the clients.
signal lost(player_id: StringName, weapon_id: StringName)
## A fighter took [param weapon_id] off the floor, ammunition as it lay; the net layer arms the clients.
signal picked(player_id: StringName, weapon_id: StringName)

## How far in front of the eye a thrown gun starts, so it clears the thrower's own body.
const REACH := 0.6

var drops: DotWeaponDrops = null
var game: Node = null


## Names itself and joins [param owner_game], on either side.
func setup(owner_game: Node) -> void:
	game = owner_game
	name = "WeaponLayer"
	game.add_child(self)
	drops = DotWeaponDrops.new()
	drops.name = "WeaponDrops"
	drops.rules = game.drop_rules
	drops.is_authority = game.authoritative
	drops.draws = DisplayServer.get_name() != "headless"
	drops.collision_mask = game.ragdoll_rules.collision_mask
	add_child(drops)
	game.world_clearing.connect(clear)
	game.round_began.connect(func(_number: int, _map: StringName) -> void: clear())


## The drop key. Server side. Returns the drop's id, or 0 when nothing was thrown.
func throw_for(player_id: StringName) -> int:
	var r: DotWeaponDropRules = game.drop_rules.resolve(null)
	var player: WoPlayer = game.players.get(player_id)
	if drops == null or player == null or not r.enabled or not r.key_enabled or not _may_carry(player):
		return 0
	var state := _take_gun(player)
	if state.is_empty():
		return 0
	var aim: Vector3 = player.aim_direction()
	var velocity: Vector3 = player.controller.state.velocity + aim * r.throw_force + Vector3.UP * r.throw_up
	var id := drops.spawn(state, player.eye_position() + aim * REACH, velocity, _entity(player_id), r)
	lost.emit(player_id, StringName(state["id"]))
	return id


## A living fighter with a rig and a free slot takes the gun at their feet. Server side.
func tick() -> void:
	if drops == null or not drops.is_authority or drops.count() == 0:
		return
	for player_id: StringName in game.players:
		var player: WoPlayer = game.players[player_id]
		if player.weapons == null or not _may_carry(player):
			continue
		var at: Vector3 = player.controller.state.position + Vector3.UP * 0.5
		var before := _held(player)
		if drops.take_for(player.weapons.arsenal, at, _entity(player_id)) != 0:
			for held_id: StringName in _held(player):
				if not before.has(held_id):
					picked.emit(player_id, held_id)


## Called as a fighter dies: the gun in hand stays on the floor. Server side.
func drop_dead(player_id: StringName) -> void:
	var r: DotWeaponDropRules = game.drop_rules.resolve(null)
	var player: WoPlayer = game.players.get(player_id)
	if drops == null or player == null or not r.enabled or not r.on_death or game.phase != game.Phase.FINALE:
		return
	var state := _take_gun(player)
	if state.is_empty():
		return
	var velocity: Vector3 = player.controller.state.velocity * 0.5 + Vector3.UP * 2.0 + player.aim_direction()
	var _id := drops.spawn(state, player.controller.state.position + Vector3.UP, velocity, _entity(player_id), r)
	lost.emit(player_id, StringName(state["id"]))


func clear() -> void:
	if drops != null:
		drops.clear()


func describe() -> Dictionary:
	return {"drops": drops.count() if drops != null else 0, "authority": drops != null and drops.is_authority}


## Whether the fighter may throw or take a gun now: in the final death, alive, in play. (An io course's sidearm is
## not a floor gun: it is dropped when the course ends.)
func _may_carry(player: WoPlayer) -> bool:
	return game.phase == game.Phase.FINALE and player.is_alive() and not player.watching


func _take_gun(player: WoPlayer) -> Dictionary:
	var rig: ZeeWeaponRig = player.weapons
	if rig == null or not is_instance_valid(rig) or rig.arsenal == null:
		return {}
	var empty: Array[int] = []
	return rig.arsenal.drop_current(empty)


## The weapon ids in the player's hands and on their shelves.
func _held(player: WoPlayer) -> Array[StringName]:
	var out: Array[StringName] = []
	for slot: int in range(1, 16):
		for w in player.weapons.arsenal.weapons_in(slot):
			out.append(w.id())
	return out


func _entity(player_id: StringName) -> int:
	return game.entities.id_for_key(player_id)
