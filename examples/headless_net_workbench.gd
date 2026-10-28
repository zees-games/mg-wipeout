extends "headless_net_rig.gd"

## sv_workbench_remote over the real frames, in the order WoModule and WoClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_finished()
		return
	_workbench_asks(_workbench_rig())


## Two managers wired to each other, the server's workbench with its remote frame, and the client's panel-less one.
func _workbench_rig() -> Dictionary:
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var snet := _make_manager(true, &"wbserver", 1, self, SERVER_TICK_RATE)
	var cnet := _make_manager(false, &"wbclient", 5, self, SERVER_TICK_RATE)
	var sconfig := WoConfig.new()
	var cconfig := WoConfig.new()
	var sbinder := WoConfig.make_binder(sconfig)
	var cbinder := WoConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("players"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("players"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	return {"state": state, "flags": flags, "snet": snet, "cnet": cnet, "sconfig": sconfig, "sbinder": sbinder,
		"set": set, "swb": swb, "cwb": cwb, "crt": crt, "slink": slink, "clink": clink,
		"cremote": cremote, "remote": remote, "cbinder": cbinder, "cconfig": cconfig}


## The admin, guest, plain player and revoked admin against that rig, then frees it.
func _workbench_asks(rig: Dictionary) -> void:
	var state: Dictionary = rig["state"]
	var flags: Dictionary = rig["flags"]
	var snet: DotNetManager = rig["snet"]
	var cnet: DotNetManager = rig["cnet"]
	var sconfig: WoConfig = rig["sconfig"]
	var sbinder: DotGameConfigBinder = rig["sbinder"]
	var set: DotProfileSet = rig["set"]
	var swb: DotGameWorkbench = rig["swb"]
	var cwb: DotGameWorkbench = rig["cwb"]
	var crt: DotProfileRuntime = rig["crt"]
	var slink: DotNetProfileLink = rig["slink"]
	var clink: DotNetProfileLink = rig["clink"]
	var cremote: DotGameWorkbenchRemoteClient = rig["cremote"]
	var remote: DotGameWorkbenchRemote = rig["remote"]
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "checkpoint_heals", "value": false}
	var srt := swb.api.runtime as DotProfileRuntime

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sconfig.checkpoint_heals, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and not sconfig.checkpoint_heals, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": true})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(not sconfig.checkpoint_heals, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and not sconfig.checkpoint_heals, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(not sconfig.checkpoint_heals, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(not sconfig.checkpoint_heals, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_finished()
