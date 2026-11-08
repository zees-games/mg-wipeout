extends RefCounted

## Carries the weapon layer over the link: drop events out, a joiner's snapshot, and a client's events
## into the mirror. Lives beside the bridge to keep it under its size gate; it reaches the bridge's
## send calls by name.

const WoEvents := preload("wo_events.gd")
const EXTENT := WoEvents.WORLD_EXTENT
const POS_BITS := 20

## Client: a hunter's gun left their hands: the session and the weapon id.
signal lost_received(session_id: int, weapon_id: StringName)

var _bridge: Object = null
var _watched: DotWeaponDrops = null


func attach(bridge: Object) -> void:
	_bridge = bridge


## Server: follows [param layer]'s drops and the guns that leave and enter hands.
func watch(layer: Node) -> void:
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == null or drops == _watched:
		return
	_watched = drops
	drops.dropped.connect(_on_dropped)
	drops.settled.connect(_on_settled)
	drops.removed.connect(_on_removed)
	layer.lost.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		_bridge._broadcast(WoEvents.Kind.WEAPON_LOST, WoEvents.write_armed(_bridge.session_of(player_id), weapon_id)))
	layer.picked.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		_bridge.announce_armed(player_id, weapon_id))


## Every gun lying about, at rest where it lies, for a joiner.
func send_snapshot(peer_id: int, layer: Node) -> void:
	if layer == null or layer.drops == null:
		return
	for entry: Dictionary in layer.drops.snapshot():
		_bridge._tell(peer_id, WoEvents.Kind.WEAPON_DROP,
			_drop_body(entry["state"], int(entry["id"]), entry["at"], Vector3.ZERO, float(entry["life"]), bool(entry["rest"])))


## Client: whether [param kind] was a weapon-drop event, applied to the layer's mirror.
func apply(kind: int, reader: DotNetReader, layer: Node) -> bool:
	if kind < WoEvents.Kind.WEAPON_DROP or kind > WoEvents.Kind.WEAPON_LOST:
		return false
	if kind == WoEvents.Kind.WEAPON_LOST:
		var lost := WoEvents.read_armed(reader)
		if bool(lost["ok"]):
			lost_received.emit(int(lost["player_id"]), lost["weapon_id"])
		return true
	var drops: DotWeaponDrops = layer.drops if layer != null else null
	if drops == null:
		return true
	match kind:
		WoEvents.Kind.WEAPON_DROP:
			var d := read_drop(reader)
			if bool(d["ok"]):
				drops.mirror_drop(int(d["id"]), {"id": StringName(d["weapon"]),
					"magazine": int(d["magazine"]), "reserve": int(d["reserve"])},
					d["at"], d["velocity"], float(d["seconds"]), bool(d["rest"]))
		WoEvents.Kind.WEAPON_SETTLED:
			var s := read_settled(reader)
			if bool(s["ok"]):
				drops.mirror_settled(int(s["id"]), s["at"])
		_:
			var gone := read_gone(reader)
			if bool(gone["ok"]):
				drops.mirror_removed(int(gone["id"]))
	return true


func _on_dropped(id: int, state: Dictionary, at: Transform3D, velocity: Vector3, _owner: int) -> void:
	_bridge._broadcast(WoEvents.Kind.WEAPON_DROP, _drop_body(state, id, at, velocity, _watched.rules.lifetime, false))


func _on_settled(id: int, at: Transform3D) -> void:
	_bridge._broadcast(WoEvents.Kind.WEAPON_SETTLED, write_settled(id, at))


func _on_removed(id: int, _taker: int) -> void:
	var w := DotNetWriter.new()
	w.write_varint(id)
	_bridge._broadcast(WoEvents.Kind.WEAPON_GONE, w.to_bytes())


func _drop_body(state: Dictionary, id: int, at: Transform3D, velocity: Vector3, seconds: float, rest: bool) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	w.write_string(String(state["id"]), WoEvents.ID_BYTES)
	w.write_varint(maxi(0, int(state.get("magazine", 0))))
	w.write_varint(maxi(0, int(state.get("reserve", 0))))
	_write_pose(w, at)
	w.write_vector3_range(velocity, -64.0, 64.0, 12)
	w.write_varint(ceili(maxf(seconds, 0.0)))
	w.write_bool(rest)
	return w.to_bytes()


static func write_settled(id: int, at: Transform3D) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(id)
	_write_pose(w, at)
	return w.to_bytes()


static func read_drop(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "weapon": reader.read_string(WoEvents.ID_BYTES),
		"magazine": reader.read_varint(), "reserve": reader.read_varint()}
	out["at"] = _read_pose(reader)
	out["velocity"] = reader.read_vector3_range(-64.0, 64.0, 12)
	out["seconds"] = reader.read_varint()
	out["rest"] = reader.read_bool()
	out["ok"] = reader.ok()
	return out


static func read_settled(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "at": _read_pose(reader)}
	out["ok"] = reader.ok()
	return out


static func read_gone(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint()}
	out["ok"] = reader.ok()
	return out


static func _write_pose(w: DotNetWriter, at: Transform3D) -> void:
	w.write_vector3_range(at.origin, -EXTENT, EXTENT, POS_BITS)
	w.write_quaternion(at.basis.get_rotation_quaternion(), 9)


static func _read_pose(reader: DotNetReader) -> Transform3D:
	var origin := reader.read_vector3_range(-EXTENT, EXTENT, POS_BITS)
	return Transform3D(Basis(reader.read_quaternion(9)), origin)
