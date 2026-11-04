extends "wo_course_base.gd"
## The crowd, stands, banners, screens and confetti beside a course: client-side meshes only, built from the document's `dressing`.


## Raises the crowd by [param amount] (0..1). The announcer calls it; it falls back by itself.
func cheer(amount: float) -> void:
	excitement = clampf(maxf(excitement, CALM) + amount, 0.0, 1.0)

	if amount >= 0.6:
		for burst in _confetti:
			if is_instance_valid(burst):
				burst.restart()


## Writes [param text] on every big screen this course has.
func show_on_screens(text: String) -> void:
	for screen in _screens:
		if is_instance_valid(screen):
			screen.text = text


func screen_count() -> int:
	return _screens.size()


func _process(delta: float) -> void:
	if not draw_world:
		return

	excitement = maxf(excitement - COOL_PER_SECOND * delta, CALM)

	for material in _crowd_materials:
		material.set_shader_parameter(&"excite", excitement)

	var t := float(Time.get_ticks_msec()) / 1000.0
	for index in range(_flags.size()):
		var flag := _flags[index]
		if is_instance_valid(flag):
			flag.rotation.y = 0.35 * sin(t * 2.3 + float(index) * 0.9)


func _build_dressing() -> void:
	set_process(true)
	excitement = CALM
	var dressing: Array = doc.get("dressing", [])
	var crowd := {"bodies": [], "seed": 1}

	for item: Dictionary in dressing:
		match str(item["kind"]):
			"stands":
				_stands(item, crowd["bodies"])
			"banner":
				_banner(item)
			"lights":
				_light_tower(item)
			"screen":
				_screen(item)
			"flags":
				_flag_row(item)

	if not (crowd["bodies"] as Array).is_empty():
		_crowd(crowd["bodies"])

	if is_course():
		_finish_confetti()


func _box_at(parent: Node3D, size: Vector3, at: Vector3, colour: Color, glow: float = 0.0) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.8
	if glow > 0.0:
		material.emission_enabled = true
		material.emission = colour
		material.emission_energy_multiplier = glow
	mesh.material_override = material
	parent.add_child(mesh)
	return mesh


## A grandstand: steps rising away from the course from `at` (the middle of its front edge, at
## the height of the first row), `size` = length, height, depth; a back wall with the show's
## colour along it. The people on the steps go into [param bodies] as transforms.
func _stands(item: Dictionary, bodies: Array) -> void:
	var root := Node3D.new()
	root.name = "Stands"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)

	var size: Vector3 = item["size"]
	var rows := clampi(int(size.z / 0.9), 3, 12)
	var depth := size.z / float(rows)
	var rise := size.y / float(rows)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	var tint: Color = item["tint"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(item["seed"]) * 7919 + 17

	for row in range(rows):
		var top := float(row) * rise
		var height := top - bottom
		var step := _box_at(root, Vector3(size.x, height, depth), Vector3(0.0, bottom + height * 0.5, (float(row) + 0.5) * depth),
			Color(0.80, 0.82, 0.88) if row % 2 == 0 else Color(0.70, 0.72, 0.80))
		step.name = "Row%d" % row

		var seat := -size.x * 0.5 + 0.4
		while seat < size.x * 0.5 - 0.3:
			if rng.randf() > 0.12:
				var at := Vector3(seat + rng.randf_range(-0.08, 0.08), top, (float(row) + 0.45) * depth)
				bodies.append({"at": root.transform * at, "basis": root.transform.basis, "rng": rng.randi()})
			seat += 0.62

	var wall_height := size.y + 3.0
	_box_at(root, Vector3(size.x + 0.4, wall_height - bottom, 0.4), Vector3(0.0, (wall_height + bottom) * 0.5, size.z + 0.2), Color(0.30, 0.32, 0.42))
	_box_at(root, Vector3(size.x + 0.5, 1.1, 0.5), Vector3(0.0, wall_height - 0.4, size.z + 0.1), tint, 0.6)
	# A rail along the front, so the first row does not read as standing on the water's edge.
	_box_at(root, Vector3(size.x, 0.9, 0.12), Vector3(0.0, 0.45 - rise * 0.5, 0.05), Color(0.95, 0.95, 0.98))

	if str(item["text"]) != "":
		var words := Label3D.new()
		words.text = str(item["text"])
		words.font_size = 160
		words.pixel_size = 0.006
		words.outline_size = 24
		words.modulate = Color(1.0, 1.0, 1.0)
		words.position = Vector3(0.0, wall_height - 0.4, size.z - 0.2)
		# A Label3D reads from its +Z side, and the crowd (and the course) is on the -Z side.
		words.rotation = Vector3(0.0, PI, 0.0)
		root.add_child(words)


## The people, as three MultiMeshes over every stand on the course.
func _crowd(bodies: Array) -> void:
	if _crowd_shader == null:
		_crowd_shader = Shader.new()
		_crowd_shader.code = CROWD_SHADER

	_crowd_materials.clear()
	var parts := [
		{"name": "Bodies", "mesh": _crowd_box(Vector3(0.44, 0.62, 0.3)), "lift": 0.31, "arms": 0.0, "palette": SHIRTS},
		{"name": "Heads", "mesh": _crowd_head(), "lift": 0.78, "arms": 0.0, "palette": SKINS},
		{"name": "Arms", "mesh": _crowd_box(Vector3(0.62, 0.5, 0.1)), "lift": 0.86, "arms": 1.0, "palette": SKINS},
	]

	for part: Dictionary in parts:
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = true
		multi.use_custom_data = true
		multi.mesh = part["mesh"]
		multi.instance_count = bodies.size()
		var palette: Array = part["palette"]

		for index in range(bodies.size()):
			var body: Dictionary = bodies[index]
			var seed := int(body["rng"])
			var basis: Basis = body["basis"]
			var at: Vector3 = (body["at"] as Vector3) + basis * Vector3(0.0, float(part["lift"]), 0.0)
			multi.set_instance_transform(index, Transform3D(basis, at))
			var shade: Color = palette[(seed >> (3 if palette == SKINS else 0)) % palette.size()]
			multi.set_instance_color(index, shade)
			multi.set_instance_custom_data(index, Color(float(seed % 997) / 997.0, float((seed >> 4) % 89) / 89.0,
				float((seed >> 9) % 71) / 71.0 * 0.9, 0.0))

		var material := ShaderMaterial.new()
		material.shader = _crowd_shader
		material.set_shader_parameter(&"arms", float(part["arms"]))
		material.set_shader_parameter(&"excite", excitement)
		_crowd_materials.append(material)

		var node := MultiMeshInstance3D.new()
		node.name = "Crowd" + str(part["name"])
		node.multimesh = multi
		node.material_override = material
		add_child(node)


static func _crowd_box(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


static func _crowd_head() -> SphereMesh:
	var head := SphereMesh.new()
	head.radius = 0.15
	head.height = 0.3
	head.radial_segments = 8
	head.rings = 4
	return head


## A banner on two poles: the show's colour and a word on both faces.
func _banner(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Banner"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var size: Vector3 = item["size"]
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y

	for side in [-1.0, 1.0]:
		_box_at(root, Vector3(0.3, size.y + 2.0 - bottom, 0.3), Vector3(side * size.x * 0.5, (size.y + 2.0 + bottom) * 0.5, 0.0), Color(0.85, 0.86, 0.9))
	_box_at(root, Vector3(size.x, size.y, 0.2), Vector3(0.0, 2.0 + size.y * 0.5 - 0.5, 0.0), item["tint"], 0.35)

	var text := str(item["text"]) if str(item["text"]) != "" else str(doc.get("name", ""))
	for face in [1.0, -1.0]:
		var words := Label3D.new()
		words.text = text
		words.font_size = 200
		words.pixel_size = clampf(size.y * 0.55 / 200.0, 0.002, 0.05)
		words.outline_size = 28
		words.position = Vector3(0.0, 2.0 + size.y * 0.5 - 0.5, 0.12 * face)
		words.rotation = Vector3(0.0, 0.0 if face > 0.0 else PI, 0.0)
		words.double_sided = false
		root.add_child(words)


## A light tower: a mast and a bank of lamps facing the course (the tower's -Z).
func _light_tower(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Lights"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var height := maxf((item["size"] as Vector3).y, 6.0)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	_box_at(root, Vector3(0.5, height - bottom, 0.5), Vector3(0.0, (height + bottom) * 0.5, 0.0), Color(0.55, 0.57, 0.62))
	_box_at(root, Vector3(3.4, 2.0, 0.5), Vector3(0.0, height + 0.6, 0.0), Color(0.22, 0.24, 0.30))

	for col in range(4):
		for row in range(2):
			_box_at(root, Vector3(0.62, 0.62, 0.1), Vector3(-1.2 + float(col) * 0.8, height + 0.2 + float(row) * 0.8, -0.3),
				Color(1.0, 0.97, 0.86), 3.0)


## A big screen on legs, facing the course: the course's name, and whatever the client puts
## up ([method show_on_screens]: the leaders).
func _screen(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Screen"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var size: Vector3 = item["size"]
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y
	var lift := 3.0

	for side in [-1.0, 1.0]:
		_box_at(root, Vector3(0.4, lift - bottom, 0.4), Vector3(side * size.x * 0.35, (lift + bottom) * 0.5, 0.3), Color(0.40, 0.42, 0.48))
	_box_at(root, Vector3(size.x + 0.6, size.y + 0.6, 0.5), Vector3(0.0, lift + size.y * 0.5, 0.0), Color(0.12, 0.13, 0.16))
	_box_at(root, Vector3(size.x, size.y, 0.1), Vector3(0.0, lift + size.y * 0.5, -0.27), Color(0.05, 0.10, 0.22), 0.6)
	_box_at(root, Vector3(size.x + 0.6, 0.5, 0.55), Vector3(0.0, lift + size.y + 0.45, 0.0), item["tint"], 0.8)

	var words := Label3D.new()
	words.name = "ScreenText"
	words.text = str(item["text"]) if str(item["text"]) != "" else str(doc.get("name", "")).to_upper()
	words.font_size = 160
	words.pixel_size = clampf(size.y * 0.16 / 160.0, 0.002, 0.05)
	words.outline_size = 12
	words.modulate = Color(1.0, 0.95, 0.70)
	words.position = Vector3(0.0, lift + size.y * 0.5, -0.34)
	words.rotation = Vector3(0.0, PI, 0.0)
	words.width = size.x / words.pixel_size * 0.95
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(words)
	_screens.append(words)


## A row of flags on poles along `size.x`, colours drawn from the seed.
func _flag_row(item: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Flags"
	_not_collided(root)
	root.transform = Transform3D(_yaw_basis(float(item["yaw"])), item["at"])
	add_child(root)
	var length := (item["size"] as Vector3).x
	var count := maxi(int(length / 3.0), 1)
	var bottom := water_height() - 1.0 - (item["at"] as Vector3).y

	for index in range(count + 1):
		var x := -length * 0.5 + float(index) * length / float(count)
		_box_at(root, Vector3(0.14, 5.0 - bottom, 0.14), Vector3(x, (5.0 + bottom) * 0.5, 0.0), Color(0.92, 0.92, 0.95))
		var flag := Node3D.new()
		flag.position = Vector3(x, 4.4, 0.0)
		root.add_child(flag)
		_box_at(flag, Vector3(0.04, 0.9, 1.4), Vector3(0.0, 0.0, 0.72),
			SHIRTS[(int(item["seed"]) + index) % SHIRTS.size()])
		_flags.append(flag)


## Confetti over the finish arch: one-shot bursts, restarted by a big [method cheer].
func _finish_confetti() -> void:
	var finish: Dictionary = doc["finish"]
	var basis := _yaw_basis(float(finish["yaw"]))
	var size: Vector3 = finish["size"]

	for side in [-1.0, 1.0]:
		var burst := CPUParticles3D.new()
		burst.name = "Confetti"
		burst.emitting = false
		burst.one_shot = true
		burst.amount = 140
		burst.lifetime = 3.2
		burst.explosiveness = 0.85
		burst.direction = Vector3(-side * 0.4, 1.0, 0.0)
		burst.spread = 35.0
		burst.initial_velocity_min = 7.0
		burst.initial_velocity_max = 12.0
		burst.gravity = Vector3(0.0, -4.0, 0.0)
		burst.damping_min = 1.0
		burst.damping_max = 2.5
		burst.angular_velocity_min = -360.0
		burst.angular_velocity_max = 360.0
		burst.scale_amount_min = 0.6
		burst.scale_amount_max = 1.2
		var quad := QuadMesh.new()
		quad.size = Vector2(0.14, 0.09)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		quad.material = material
		burst.mesh = quad
		var colours := Gradient.new()
		colours.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
		colours.colors = PackedColorArray([SHIRTS[0], SHIRTS[1], SHIRTS[2], SHIRTS[3], SHIRTS[6]])
		burst.color_initial_ramp = colours
		burst.transform = Transform3D(basis, (finish["at"] as Vector3) + basis * Vector3(side * size.x * 0.5, maxf(size.y, 2.5), 0.0))
		add_child(burst)
		_confetti.append(burst)
