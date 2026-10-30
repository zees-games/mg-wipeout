extends DotNetMessage

const WoEvents := preload("wo_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only: three kinds, none a per-tick intent
## (firing is a BUTTON, ordered against its movement) but each happening once and not to be lost ("my world exists",
## "into that chopper", "the other side").

const NAME := &"wo.request"
const KIND_BITS := 4
const MAX_BODY := 256

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## Built with `new(kind, body)`; this file does not preload itself. A script that `extends DotNetMessage` and preloads
## ITSELF, first loaded from a module a running [DotServer] loads at runtime, leaks the whole script graph at exit on
## Godot 4.7.2. The registry decodes with a bare `new()`, so both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= WoEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


## Whether every [enum WoEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(WoEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "WoRequest(%s, %d bytes)" % [WoEvents.ask_name(kind), body.size()]
