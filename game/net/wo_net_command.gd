extends DotNetInput

const WoNetCommand := preload("wo_net_command.gd")

## One tick of a player's intent on the wire: a movement command and a weapon slot. The same command walks a player
## and flies a chopper. The game buttons ride in [member DotFpsCommand.buttons], ordered against the movement they
## were aimed with; the slot is its own field ([member WoPlayer.wanted_slot]).

## Fire, and the chopper's drop. `BUTTON_USER_0`, which dot-player-controller reserves.
const BUTTON_FIRE := DotFpsCommand.BUTTON_USER_0

## The alt-fire, which on every blaster in the pack is a bash.
const BUTTON_ALT := DotFpsCommand.BUTTON_USER_1

const BUTTON_RELOAD := DotFpsCommand.BUTTON_USER_2

## How many bits the slot takes. Eight slots is one more than the pack uses.
const SLOT_BITS := 3

var move: DotFpsCommand = DotFpsCommand.new()

## Which weapon the player has asked for, or zero for "leave it alone".
var slot: int = 0

## Whether the grab key is held: pick up, or put down, what the player is looking at. In this game's own message, not
## [DotFpsCommand], whose spare buttons are taken and whose widening would break every game for a key only this one
## has. The server turns the held state into an edge (`WoGame._advance_grabs`).
var grab: bool = false


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	writer.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	writer.write_bool(grab)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)
	slot = reader.read_uint(SLOT_BITS)
	grab = reader.read_bool()


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — which in this
## game is 41% more load on the platform somebody else is standing on.
func _sanitise() -> void:
	move.sanitise()
	slot = clampi(slot, 0, (1 << SLOT_BITS) - 1)


func _equals(other: DotNetInput) -> bool:
	var them := other as WoNetCommand
	return them != null and slot == them.slot and grab == them.grab and move.equals(them.move)
