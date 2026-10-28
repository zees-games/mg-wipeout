extends Label
## A course's one-paragraph introduction, top left: wrapped to a fixed share of the screen, outlined, gone after a few seconds.

const CHANNEL := "wo_blurb"
const MARGIN := Vector2(16.0, 72.0)
const MAX_WIDTH := 420.0
## The widest share of the view it may take, so a narrow or 4:3 window keeps the middle (the runner) clear.
const MAX_SHARE := 0.28
const MAX_CHARS := 260

var _left: float = 0.0


func _init() -> void:
	name = "Blurb"
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_size_override("font_size", 17)
	add_theme_constant_override("outline_size", 6)
	visible = false


## Where the blurb sits in a view of [param view]: top left, never wider than [constant MAX_SHARE] of it.
static func rect_for(view: Vector2, lines: int = 7, line_height: float = 24.0) -> Rect2:
	var width := minf(MAX_WIDTH, view.x * MAX_SHARE)
	return Rect2(MARGIN, Vector2(width, line_height * float(lines)))


## Shows [param text] for [param seconds]; empty text hides it.
func show_blurb(text: String, seconds: float = 9.0) -> void:
	text = text.strip_edges()
	if text.length() > MAX_CHARS:
		text = text.substr(0, MAX_CHARS - 1).strip_edges() + "…"
	self.text = text
	_left = seconds if text != "" else 0.0
	visible = _left > 0.0
	layout()


## Takes the rectangle [method rect_for] gives for the current view.
func layout() -> void:
	var r := rect_for(get_viewport_rect().size if is_inside_tree() else Vector2(1280.0, 720.0))
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = r.position
	size = Vector2(r.size.x, 0.0)
	custom_minimum_size = Vector2(r.size.x, 0.0)


func _process(delta: float) -> void:
	if _left <= 0.0:
		return
	_left -= delta
	modulate.a = clampf(_left, 0.0, 1.0)
	if _left <= 0.0:
		visible = false
