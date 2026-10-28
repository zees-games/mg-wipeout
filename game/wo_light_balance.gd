extends RefCounted
## Keeps an imported map's baked light from tinting the whole course: the same channel-ratio bound dot-map puts on its floor light, applied to the lightmap itself.

const CHANNEL := "wo_light_balance"
## The strongest ratio of brightest to dimmest channel the mean bake keeps; tighter than dot-map's 2.5 for its floor, because here it is every surface, not the dark ones.
const MAX_RATIO := 1.6


## The albedo multiplier that brings a bake of mean colour [param mean] within [constant MAX_RATIO]; white when it already is.
static func tint_for(mean: Color) -> Color:
	var g := (mean.r + mean.g + mean.b) / 3.0
	var hi := maxf(mean.r, maxf(mean.g, mean.b))
	var lo := minf(mean.r, minf(mean.g, mean.b))
	var denom := hi + (MAX_RATIO - 1.0) * g - MAX_RATIO * lo
	if g <= 0.0 or lo <= 0.0 or denom <= 0.0:
		return Color.WHITE
	var k := minf(1.0, (MAX_RATIO - 1.0) * g / denom)
	var want := Color(g + (mean.r - g) * k, g + (mean.g - g) * k, g + (mean.b - g) * k)
	var gain := Color(want.r / mean.r, want.g / mean.g, want.b / mean.b)
	var peak := maxf(gain.r, maxf(gain.g, gain.b))
	return Color(gain.r / peak, gain.g / peak, gain.b / peak)


## The mean colour of a lightmap page, black texels included (only the ratio of the channels is used).
static func mean_of(page: Texture2D) -> Color:
	var img := page.get_image()
	if img == null or img.is_empty():
		return Color.BLACK
	img.convert(Image.FORMAT_RGBAF)
	img.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var sum := Color(0, 0, 0, 1)
	for y in 16:
		for x in 16:
			var c := img.get_pixel(x, y)
			sum += Color(c.r, c.g, c.b, 0.0)
	return Color(sum.r / 256.0, sum.g / 256.0, sum.b / 256.0)


## Multiplies the `tint` of every lightmapped material under [param root] by [method tint_for] its page; returns how many it changed.
static func apply(root: Node) -> int:
	var changed := 0
	var seen := {}
	var balance := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s)
			if not m is ShaderMaterial or seen.has(m.get_instance_id()):
				continue
			seen[m.get_instance_id()] = true
			var page: Variant = (m as ShaderMaterial).get_shader_parameter("lightmap")
			if not page is Texture2D:
				continue
			if not balance.has(page):
				balance[page] = tint_for(mean_of(page as Texture2D))
			var t: Color = balance[page]
			if t == Color.WHITE:
				continue
			var old: Variant = (m as ShaderMaterial).get_shader_parameter("tint")
			var v: Vector3 = old if old is Vector3 else Vector3.ONE
			(m as ShaderMaterial).set_shader_parameter("tint", Vector3(v.x * t.r, v.y * t.g, v.z * t.b))
			changed += 1
	if changed > 0:
		DotLog.debug(CHANNEL, "bake rebalanced", {"materials": changed})
	return changed
