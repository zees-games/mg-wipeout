extends DotGameCheckSuite

## A stand-in climbs: on a toy level whose platform only a ladder reaches, WoIoBot walks to the foot, climbs without
## hopping at it, and steps off at the top. The toy body climbs as the controller's ladder mode does (forward into the
## ladder's face is up). The shipped courses have no ladder-only goal, so the level is built here.

const WoIoBot := preload("../game/wo_io_bot.gd")
const TICK := 1.0 / 64.0
const LADDER := AABB(Vector3(-0.2, 0.0, -0.5), Vector3(0.2, 4.0, 1.0))
const GOAL := Vector3(5.0, 4.0, -3.0)


class FakeIo extends RefCounted:
	var destinations := {}
	var entities: Array = []


class FakeVolumes extends RefCounted:
	var nodes: Array = []


class FakeWorld extends RefCounted:
	var io := FakeIo.new()
	var volumes := FakeVolumes.new()
	var ladders: Array[AABB] = []

	func ladder_boxes() -> Array[AABB]:
		return ladders


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: a stand-in climbs a ladder")
	var root := Node3D.new()
	add_child(root)
	var still := StaticBody3D.new()
	root.add_child(still)
	for centre: Vector3 in [Vector3(-5.0, 0.0, 0.0), Vector3(5.0, 4.0, 0.0)]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10.0, 0.2, 10.0)
		shape.shape = box
		shape.position = centre + Vector3(0.0, -0.1, 0.0)
		still.add_child(shape)
	await get_tree().physics_frame

	var fake := FakeWorld.new()
	fake.ladders.append(LADDER)
	var links := DotBotLinks.read(fake)
	_check(links.ladders.size() == 1, "the map's ladder box is read")
	var bot := WoIoBot.new()
	var finish := AABB(GOAL - Vector3(1.0, 1.0, 1.0), Vector3(2.0, 2.0, 2.0))
	bot.setup(null, root, finish, {"radius": 0.35, "height": 1.0, "climb": 0.4}, links)
	var waited := 0.0
	while not bot.is_ready() and waited < 60.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_check(bot.is_ready(), "the mesh baked")
	_check(bot.reaches_finish(Vector3(-6.0, 0.0, 0.0)), "the ladder joins the platform to the finish")

	var foot_hops := 0
	var climbed := false
	var feet := Vector3(-6.0, 0.0, 0.0)
	var yaw := 0.0
	var top := 0.0
	var reached_tick := -1
	var vy := 0.0
	var air := false
	for tick in range(64 * 40):
		var cmd := DotFpsCommand.new()
		cmd.yaw = yaw
		bot.steer(feet, not air and vy == 0.0, tick, &"bot", cmd)
		yaw = cmd.yaw
		var jumped := cmd.buttons & DotFpsCommand.BUTTON_JUMP != 0
		var y := deg_to_rad(yaw)
		var forward := Vector3(-sin(y), 0.0, -cos(y))
		var right := Vector3(cos(y), 0.0, -sin(y))
		var wish := (right * cmd.move.x + forward * cmd.move.y) * 3.81
		var hull := AABB(feet - Vector3(0.4, 0.0, 0.4), Vector3(0.8, 1.8, 0.8))
		if hull.intersects(LADDER) and wish.x > 0.1 and feet.y < 4.0:
			feet.y += wish.x * TICK
			climbed = true
			vy = 0.0
			air = false
			if jumped and feet.y < 3.9:
				foot_hops += 1
		else:
			if jumped and feet.y < 0.01 and not climbed:
				foot_hops += 1
			feet += wish * TICK
			if feet.y < 3.9:
				feet.x = minf(feet.x, -0.55)
			var floor_y := 4.0 if feet.y >= 3.9 and feet.x > -0.6 else 0.0
			feet.y = maxf(floor_y, feet.y - 10.0 * TICK)
		top = maxf(top, feet.y)
		if feet.distance_to(GOAL) < 1.5 and reached_tick < 0:
			reached_tick = tick
			break
	_check(climbed and top >= 3.9, "it climbs the ladder", "top %.2f" % top)
	_check(foot_hops == 0, "it never hops at the ladder's foot", "%d hops" % foot_hops)
	_check(reached_tick >= 0, "it reaches the platform only the ladder leads to", "ended at %s" % str(feet))
	bot.clear()
	root.queue_free()
	_report(6)
