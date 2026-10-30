extends RefCounted

const WoPaths := preload("wo_paths.gd")

## The prototype textures every surface is drawn with, and the grid that stands in when they are missing: a pattern of
## a known size is what tells a player how far a jump is. A role, not a colour. Kenney's Prototype Textures 1.0, CC0
## (`textures/prototype/LICENSE.txt`, unchanged); only the light grid, the orange and the red are vendored.

const CHANNEL := "wo.textures"

## What a surface is FOR, which is what decides how it is drawn.
enum Role {
	## Ground that stays still. What most of a course is.
	DECK,
	## Supports, frames and gantries. Darker than a deck, so a deck reads against it.
	PILLAR,
	## Ground that MOVES: a turntable, a mover, a roller, a tile. The colour that says "this
	## will not be where it is now".
	CANNON,
	## A final death's floor.
	ARENA,
	## Anything that throws you: an arm, a pendulum, a pusher.
	HAZARD,
	## A start pad, a checkpoint, a bouncer, the finish's lounge.
	SAFE,
}

## The file each role loads; dropping a different PNG in is the whole of a re-skin. `texture_02` from each colour
## folder, not `texture_13`: Kenney's numbering differs per colour and several `texture_13`s have `WALL / 1 x 1 meter`
## painted in the corner, repeating every eight metres.
const ROLE_FILES := {
	Role.DECK: "deck.png",
	Role.PILLAR: "deck.png",
	Role.CANNON: "cannon.png",
	Role.ARENA: "deck.png",
	Role.HAZARD: "hazard.png",
	Role.SAFE: "deck.png",
}

## A colour an INSTALLED texture is multiplied by, for a role drawn from the light deck. Only what a player must react
## to keeps a saturated tile (orange moves, red throws you); the rest is pastel. The deck is a hair under white (full
## white clipped and lost the grid). The arena is lavender, not Kenney's purple, which the warm sun made a magenta floor.
const INSTALLED_TINTS := {
	Role.DECK: Color(0.96, 0.96, 1.00),
	Role.PILLAR: Color(0.70, 0.64, 0.92),
	Role.ARENA: Color(0.80, 0.70, 1.00),
	Role.SAFE: Color(0.58, 0.96, 0.78),
}

## What the generated fallback grid is tinted with, per role, when no set is installed.
const ROLE_COLOURS := {
	Role.DECK: Color(0.90, 0.90, 0.95),
	Role.PILLAR: Color(0.70, 0.64, 0.92),
	Role.CANNON: Color(0.86, 0.48, 0.18),
	Role.ARENA: Color(0.80, 0.70, 1.00),
	Role.HAZARD: Color(0.72, 0.27, 0.26),
	Role.SAFE: Color(0.58, 0.96, 0.78),
}

## How many squares are across one tile of the installed set. Eight, measured: the ramp's lines alternate STRONG and
## FAINT, so a threshold picked to ignore compression noise finds four and draws every surface at half scale.
const INSTALLED_SQUARES_PER_TILE := 8

## How many squares are across one tile of the generated grid.
const GENERATED_SQUARES_PER_TILE := 4

## How big one square is in the world, in metres. One metre: the unit every course is judged in, counted by a player
## deciding whether a jump is on.
const METRES_PER_SQUARE := 1.0

## Pixels per square in the generated tile.
const GENERATED_PIXELS_PER_SQUARE := 128

## How much darker an alternate square is in the composited checker. Ink is the only thing that survives a mipmap and
## Kenney's tile has almost none (97% one colour), so from across a gap the grid is gone. A checker is half the image,
## so it survives being averaged.
const CHECKER := 0.93

## How much darker a grid line is in the generated tile.
const LINE := 0.70

## Where a texture set is looked for. A missing directory is a supported state.
static var TEXTURE_DIR := WoPaths.rebase("res://textures/prototype")

## Built materials, by role. One per role for the whole map — a map is a few hundred
## boxes and a material each would be a few hundred shader compilations for one texture.
static var _materials: Dictionary = {}

## Composited installed textures, by role. Null means "looked for it and it is not here".
static var _installed: Dictionary = {}

## Composited installed textures, by file, which several roles share.
static var _by_path: Dictionary = {}

## The one generated tile, shared by every role and tinted per role.
static var _grid: ImageTexture = null


## The material for a role. Cached; call it per box. [param moving] maps the texture to the BODY: a world-space grid
## is right for what stands still and wrong for what turns, where a turntable would look like a disc that is not
## turning.
static func surface(role: Role, moving: bool = false) -> StandardMaterial3D:
	var key := int(role) * 2 + (1 if moving else 0)

	if _materials.has(key):
		return _materials[key]

	var material := StandardMaterial3D.new()
	var texture := installed(role)
	var squares := INSTALLED_SQUARES_PER_TILE

	if texture == null:
		texture = grid_texture()
		squares = GENERATED_SQUARES_PER_TILE
		# The generated tile is greyscale and is multiplied by the role's colour. An
		# installed set brings its own colour and is drawn white, because multiplying
		# Kenney's orange by a role tint is a double tint that produces mud.
		material.albedo_color = ROLE_COLOURS.get(role, Color.WHITE)
	else:
		material.albedo_color = INSTALLED_TINTS.get(role, Color.WHITE)

	material.albedo_texture = texture

	# World-space triplanar, without which none of the numbers above mean anything: a [BoxMesh] maps every face to
	# the same 0..1 square, so a 10.5 m platform and a 1 m step would show the same squares and the pattern would
	# stop carrying scale.
	material.uv1_triplanar = true
	material.uv1_world_triplanar = not moving

	var metres_per_tile := METRES_PER_SQUARE * float(squares)
	var scale := 1.0 / maxf(metres_per_tile, 0.001)
	material.uv1_scale = Vector3(scale, scale, scale)

	material.roughness = 0.94
	material.metallic = 0.0

	# Nearest, which is a decision rather than a default: a prototype grid is meant to be
	# read as discrete squares at distance, and filtering blurs the lines out at exactly
	# the range a player is judging a jump from.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS

	_materials[key] = material
	return material


## The installed texture for a role, checkered, or null if no set is installed.
static func installed(role: Role) -> Texture2D:
	if _installed.has(role):
		return _installed[role]

	var path := "%s/%s" % [TEXTURE_DIR, ROLE_FILES.get(role, "deck.png")]

	# [method ResourceLoader.exists] rather than [method FileAccess.file_exists]: an imported texture in an exported
	# build is a `.ctex` with no `.png` shipped, so the filesystem answers "no" in exactly the build that matters.
	if not ResourceLoader.exists(path, "Texture2D"):
		DotLog.debug(CHANNEL, "no texture installed for a role", {
			"role": Role.keys()[role], "looked_at": path,
		})
		_installed[role] = null
		return null

	var loaded: Resource = ResourceLoader.load(path, "Texture2D")

	if not (loaded is Texture2D):
		_installed[role] = null
		return null

	# Four roles share the light deck, so the checker is composited once per file, not per
	# role: it is a million-pixel loop in GDScript.
	if not _by_path.has(path):
		var checkered := _with_checker(loaded as Texture2D)
		_by_path[path] = checkered if checkered != null else loaded as Texture2D
	_installed[role] = _by_path[path]
	return _installed[role]


## The installed tile with a checker composited onto it (see [constant CHECKER]). Null when the pixels could not be
## read, which is not an error: the caller uses the tile as it came.
static func _with_checker(source: Texture2D) -> ImageTexture:
	var image := source.get_image()

	if image == null or image.is_empty():
		return null

	image = image.duplicate() as Image

	if image.is_compressed():
		# A compressed import cannot be written into. Decompressing is cheap for six
		# 1024-pixel tiles and happens once for the life of the process.
		if image.decompress() != OK:
			return null

	var width := image.get_width()
	var height := image.get_height()

	if width <= 0 or height <= 0:
		return null

	var square_w := maxi(width / INSTALLED_SQUARES_PER_TILE, 1)
	var square_h := maxi(height / INSTALLED_SQUARES_PER_TILE, 1)

	for y in range(height):
		for x in range(width):
			# Alternate squares, which is `(column + row) & 1`. Half the image, which is
			# the point — see [constant CHECKER].
			if ((x / square_w) + (y / square_h)) % 2 == 0:
				continue

			var pixel := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(
				pixel.r * CHECKER, pixel.g * CHECKER, pixel.b * CHECKER, pixel.a
			))

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## The generated one-metre grid: a line every square, a checker underneath. What is drawn when no texture set is
## installed, a supported state: the map stays playable with an empty `textures/` directory.
static func grid_texture() -> ImageTexture:
	if _grid != null:
		return _grid

	var side := GENERATED_PIXELS_PER_SQUARE * GENERATED_SQUARES_PER_TILE
	var image := Image.create_empty(side, side, true, Image.FORMAT_RGB8)

	for y in range(side):
		for x in range(side):
			var shade := 1.0
			var column := x / GENERATED_PIXELS_PER_SQUARE
			var row := y / GENERATED_PIXELS_PER_SQUARE

			if (column + row) % 2 == 1:
				shade *= CHECKER

			# Three pixels, because one pixel of ink on a 128-pixel square is 0.8% of the
			# image and a mipmap has eaten it by the second level.
			if x % GENERATED_PIXELS_PER_SQUARE < 3 or y % GENERATED_PIXELS_PER_SQUARE < 3:
				shade *= LINE

			image.set_pixel(x, y, Color(shade, shade, shade))

	image.generate_mipmaps()
	_grid = ImageTexture.create_from_image(image)
	return _grid


## Forgets every cached material and texture, for a test that changes the install. Not called `reset_state`:
## `Resource` already has one and GDScript takes the redefinition without a warning, so calls would bind to the
## engine's.
static func forget_cache() -> void:
	_materials.clear()
	_installed.clear()
	_by_path.clear()
	_grid = null


static func describe() -> Dictionary:
	var installed_count := 0

	for role in ROLE_FILES:
		if installed(role) != null:
			installed_count += 1

	return {
		"directory": TEXTURE_DIR,
		"installed": "%d of %d roles" % [installed_count, ROLE_FILES.size()],
		"metres_per_square": METRES_PER_SQUARE,
	}
