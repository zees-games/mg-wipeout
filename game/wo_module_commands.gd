extends DotGameModule

const WoServices := preload("wo_services.gd")
const WoGame := preload("wo_game.gd")
const WoVote := preload("wo_vote.gd")

## The players' vote for the next course; null when it could not be built.
var vote: WoVote = null


## The courses the SERVER names (its map config, not this game's), added to the catalogue.
## Called after EVERY catalogue load: `load_from` forgets everything read before, so a reload
## that skipped this dropped every delivered course.
func _add_delivered_courses(world: WoGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "courses"):
		read += world.catalogue.add_directory(root)

	return read


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat, run through the console as the person who typed it, so a
## missing flag is refused by the same file that refuses it at the console.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, WoServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_courses(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.course_doc.get("id", "-")))


func _cmd_rotation(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null or not world.catalogue.has_rotation_file():
		ctx.reply("There is no maps.yml; every course rotates.")
		return

	var file := world.catalogue.rotation_file

	if ctx.argc() == 0:
		ctx.reply("Rotations: %s (active: %s)" % [", ".join(file.rotation_names()), file.active_name()])
		return

	var wanted := ctx.arg(0)
	var switched := world.catalogue.switch_rotation(wanted)

	if not switched.ok:
		ctx.reply(switched.error.message)
		return

	if vote != null:
		vote.refresh_courses()

	ctx.reply("Rotation: %s" % wanted)


func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var read := world.load_rotation()

	if vote != null:
		vote.refresh_courses()

	ctx.reply("maps.yml read." if read.ok else read.error.message)


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.course_directory)
	loaded += await _add_delivered_courses(world)
	world.catalogue.apply_rotation(world.config.course_ids)

	if vote != null:
		vote.refresh_courses()

	ctx.reply("%d documents read; %d refused. The next round draws from them." % [
		loaded, world.catalogue.refused.size()])
