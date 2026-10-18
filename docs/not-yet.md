# Not yet

What this game does not do yet.

- **Workshop maps are listed, not playable.** `provides.json` accepts subscribed maps of `map_kind` `obstacle` and `race`; the solo course menu (M) and the course vote list them as `Name [Pack]`, but a choice answers "Wipeout cannot play Workshop maps yet". A course here is a JSON document (`WoCourseDoc`, built into pieces that are a function of the tick, with checkpoints, route flags and a final-death arena), and a pack's map is a scene. Playing one needs a loader that turns a scene into a course document (pieces, checkpoints, finish) or a document format a pack can ship, which is the game's design question, not a small change. [design](design.md)
