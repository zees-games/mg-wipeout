extends GSGameNetIo

## The stage's toys on the wire: one replicated entity per toy, and letting them all go at once.

const WoToyNet := preload("wo_toy_net.gd")

const CHANNEL := "wo.net"

## Server only: whether `server_tick` is on the stack, and the net ids released during it.
## A round re-laid mid-tick would otherwise let `record` recreate a history track per body.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []

## The stage's toys on the wire, one behaviour per toy in toy order (the TOYS event that names
## their net ids is kept for a joiner beside it, in the bridge).
var _toy_nets: Array = []

## Client: where the mirrors live, which is not under the toys: they are registered before this
## end's stage may exist, and stay registered through a stage change.
var _toy_holder: Node3D = null


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0 allocates one: the server).
## Null when the registry refused it. The behaviour goes before the identity, which collects behaviours in its
## `_ready`.
func _toy_entity(toy: GSPropBody, parent: Node, net_id: int) -> WoToyNet:
	var behaviour := WoToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := GSNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = GSNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		GSLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		for node: Node in [behaviour, identity]:
			at.remove_child(node)
			node.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry [b]and out of the tree at once[/b]: a new identity on the
## same toy collects every behaviour under it in its `_ready`, and a freed one still found there
## broke the next snapshot (game-playlot found it). A stage change, or a new TOYS.
func _release_toys() -> void:
	for behaviour: WoToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and _toy_holder != null and at.get_parent() == _toy_holder:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()
