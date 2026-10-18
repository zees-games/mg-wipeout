extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the setting
## that stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen (H) lists them with the key each is on now. Until 2026-10-11 these
## were keycodes in `WoClient._unhandled_input`, which no page could show or move.
##
## [b]Walk is Shift[/b], for beams and the tops of balls: dot-player-controller's own walk
## action, so the sampler reads this row. H is help, in every game of the family (dot-menu
## adds the row), so nothing here may default to it.

const GRAB := &"wo_grab"
const RELOAD := &"wo_reload"
const VIEW := &"wo_view"
const SCOREBOARD := &"wo_scoreboard"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"
const CHAT_TEAM := &"chat_open_team"
## Slots 1 to 5, the weapon pack's.
const SLOTS: Array[StringName] = [&"wo_slot_1", &"wo_slot_2", &"wo_slot_3", &"wo_slot_4", &"wo_slot_5"]


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch, under a high arm")
	keys.add(&"dot_fps_walk", &"bind_walk", "Walk, for beams and the tops of balls", "Shift", "Movement")
	keys.add(GRAB, &"bind_grab", "Pick up or put down a prop (hold)", "E", "Hands")
	keys.add(RELOAD, &"bind_reload", "Reload", "R", "Hands")
	for i in range(SLOTS.size()):
		keys.add(SLOTS[i], StringName("bind_slot_%d" % (i + 1)), "Weapon slot %d" % (i + 1), str(i + 1), "Hands")
	keys.add_wheel_weapons()
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(CHAT_TEAM, &"bind_chat_team", "Chat to your side", "U", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
