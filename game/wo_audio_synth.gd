extends Node

## The machinery sounds of WoAudio, synthesised: noise through filters, baked into one-shot streams.

const RATE := 22050


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	return wav


static func _buffer(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(RATE * seconds))
	return out


## Something big going past: noise through a low-pass that opens and closes, swelling to the
## middle. The filter's opening is the pass; without it, it is a hiss.
static func _whoosh() -> AudioStreamWAV:
	var out := _buffer(0.55)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var low := 0.0

	for i in out.size():
		var t := float(i) / RATE
		var u := t / 0.55
		var swell := sin(PI * u)
		low = lerpf(low, rng.randf_range(-1.0, 1.0), lerpf(0.04, 0.22, swell))
		out[i] = low * 2.2 * swell * swell

	return _wav(out)


## A ram arriving: a padded thump and the clack of it reaching its stop.
static func _ram() -> AudioStreamWAV:
	var out := _buffer(0.45)
	var rng := RandomNumberGenerator.new()
	rng.seed = 32

	for i in out.size():
		var t := float(i) / RATE
		var thump := sin(TAU * lerpf(95.0, 55.0, minf(t / 0.2, 1.0)) * t) * exp(-t * 11.0) * 0.85
		var clack := rng.randf_range(-1.0, 1.0) * exp(-t * 70.0) * 0.35
		out[i] = thump + clack

	return _wav(out)


## A tile working loose: a dry rattle at 18 Hz for as long as the red warning lasts.
static func _rattle() -> AudioStreamWAV:
	var seconds := 0.6
	var out := _buffer(seconds)
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	var mid := 0.0

	for i in out.size():
		var t := float(i) / RATE
		mid = lerpf(mid, rng.randf_range(-1.0, 1.0), 0.45)
		var chatter := maxf(0.0, sin(TAU * 18.0 * t)) ** 3.0
		var swell := minf(t / 0.08, 1.0) * clampf((seconds - t) / 0.12, 0.0, 1.0)
		out[i] = mid * 0.8 * chatter * swell

	return _wav(out)
