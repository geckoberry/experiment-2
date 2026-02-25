extends Panel
class_name ModifyPanel

signal candidate_toggled(candidate_index: int, enabled: bool)
signal seed_bias_changed(value: float)
signal seed_bias_committed(value: float)
signal blend_value_changed(value: float)
signal blend_value_committed(value: float)
signal parent_action_pressed(kind: String, candidate_index: int, strength: float)
signal random_delta_requested(target: String, strength: float)

@onready var tree: Tree = $MarginContainer/VBoxContainer/Tree
@onready var delta_slider: HSlider = $MarginContainer/VBoxContainer/DeltaContainer/DeltaSlider
@onready var delta_value: LineEdit = $MarginContainer/VBoxContainer/DeltaContainer/DeltaValue
@onready var all_button: Button = $MarginContainer/VBoxContainer/DeltaButtonContainer/AllButton
@onready var thresh_button: Button = $MarginContainer/VBoxContainer/DeltaButtonContainer/ThreshButton
@onready var nbrhd_button: Button = $MarginContainer/VBoxContainer/DeltaButtonContainer/NbrhdButton
@onready var weights_button: Button = $MarginContainer/VBoxContainer/DeltaButtonContainer/WeightsButton
@onready var seed_bias_slider: HSlider = $MarginContainer/VBoxContainer/SeedBiasContainer/SeedBiasSlider
@onready var seed_bias_value: LineEdit = $MarginContainer/VBoxContainer/SeedBiasContainer/SeedBiasValue
@onready var blend_slider: HSlider = $MarginContainer/VBoxContainer/BlendContainer/BlendBiasSlider
@onready var blend_value: LineEdit = $MarginContainer/VBoxContainer/BlendContainer/BlendValue

var font: Font = preload("res://fonts/PixelOperator.ttf")
var bold_font: Font = preload("res://fonts/PixelOperator-Bold.ttf")
var _thresholds := PackedFloat32Array()
var _neighborhoods := PackedInt32Array()
var _weights := PackedFloat32Array()
var _enabled := PackedInt32Array([1, 1, 1, 1])
var _section_collapsed_by_key: Dictionary = {} # "kind:candidate_index" -> bool
var w := size.x

var icon_checked:= preload("res://icons/checked.png")
var icon_unchecked:= preload("res://icons/unchecked.png")

const ACTION_COL := 1
const CANDIDATE_DELTA_COL := 3
const CHECK_COL := 5

const ACTIVE_COLOR := Color(1, 1, 1, 1)
const DISABLED_COLOR := Color(0.6, 0.6, 0.6, 1)
const ACTION_TEXT_IDLE := Color(1, 1, 1, 0.8)
const ACTION_TEXT_HOVER := Color(1, 1, 1, 1)
const ACTION_TEXT_PRESSED := Color(1, 1, 1, 0.4)
const ACTION_TEXT_DISABLED := Color(1, 1, 1, 0.25)
const DELTA_MIN := 0.0
const DELTA_MAX := 1.0
const THRESHOLD_FLOAT_COUNT := 32
const THRESHOLD_VALUES_PER_CANDIDATE := 8
const WEIGHT_COUNT := 16
const WEIGHTS_PER_CANDIDATE := 4
const NEIGHBORHOOD_INT_COUNT := 16
const SEED_BIAS_MIN := 0.5
const SEED_BIAS_MAX := 2.5
const BLEND_MIN := 0.0
const BLEND_MAX := 1.0
const PANEL_SIZE := Vector2(600, 1210)
const TREE_MIN_HEIGHT := 650.0

var _hover_action_key := ""
var _pressed_action_key := ""


func _ready() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	tree.custom_minimum_size.y = TREE_MIN_HEIGHT

	tree.columns = 6
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.focus_mode = Control.FOCUS_NONE

	tree.set_column_expand(0, false) # label
	tree.set_column_expand(1, false) # action
	tree.set_column_expand(2, false) # spacer
	tree.set_column_expand(3, false) # candidate delta
	tree.set_column_expand(4, false) # spacer
	tree.set_column_expand(5, false) # checkbox

	tree.set_column_custom_minimum_width(0, w - 210.0)
	tree.set_column_custom_minimum_width(1, 42)
	tree.set_column_custom_minimum_width(2, 20)
	tree.set_column_custom_minimum_width(3, 42)
	tree.set_column_custom_minimum_width(4, 20)
	tree.set_column_custom_minimum_width(5, 30)

	tree.add_theme_font_override("font", font)
	tree.add_theme_font_size_override("font_size", 40)

	var empty := StyleBoxEmpty.new()
	tree.add_theme_stylebox_override("selected", empty)
	tree.add_theme_stylebox_override("cursor", empty)
	tree.add_theme_stylebox_override("cursor_unfocused", empty)

	var custom_btn := StyleBoxFlat.new()
	custom_btn.bg_color = Color(0.5, 0.5, 0.5, 0.25)
	custom_btn.border_width_left = 2
	custom_btn.border_width_top = 2
	custom_btn.border_width_right = 0
	custom_btn.border_width_bottom = 0
	custom_btn.border_blend = true
	custom_btn.border_color = Color(1, 1, 1, 0.25)
	custom_btn.content_margin_left = 0
	custom_btn.content_margin_right = 0
	custom_btn.content_margin_top = 0
	custom_btn.content_margin_bottom = 0

	var custom_btn_hover := custom_btn.duplicate()
	custom_btn_hover.bg_color = Color(0.5, 0.5, 0.5, 0.35)

	var custom_btn_pressed := custom_btn.duplicate()
	custom_btn_pressed.bg_color = Color(0.3, 0.3, 0.3, 0.35)
	custom_btn_pressed.border_color = Color(0.3, 0.3, 0.3, 0.35)

	tree.add_theme_stylebox_override("custom_button", custom_btn)
	tree.add_theme_stylebox_override("custom_button_hover", custom_btn_hover)
	tree.add_theme_stylebox_override("custom_button_pressed", custom_btn_pressed)

	tree.add_theme_icon_override("checked", icon_checked)
	tree.add_theme_icon_override("unchecked", icon_unchecked)

	if not tree.item_edited.is_connected(_on_tree_item_edited):
		tree.item_edited.connect(_on_tree_item_edited)
	if not tree.gui_input.is_connected(_on_tree_gui_input):
		tree.gui_input.connect(_on_tree_gui_input)
	if not delta_slider.value_changed.is_connected(_on_delta_slider_value_changed):
		delta_slider.value_changed.connect(_on_delta_slider_value_changed)
	if not delta_value.text_submitted.is_connected(_on_delta_value_submitted):
		delta_value.text_submitted.connect(_on_delta_value_submitted)
	if not delta_value.focus_exited.is_connected(_on_delta_value_focus_exited):
		delta_value.focus_exited.connect(_on_delta_value_focus_exited)
	if not all_button.pressed.is_connected(_on_all_button_pressed):
		all_button.pressed.connect(_on_all_button_pressed)
	if not thresh_button.pressed.is_connected(_on_thresh_button_pressed):
		thresh_button.pressed.connect(_on_thresh_button_pressed)
	if not nbrhd_button.pressed.is_connected(_on_nbrhd_button_pressed):
		nbrhd_button.pressed.connect(_on_nbrhd_button_pressed)
	if not weights_button.pressed.is_connected(_on_weights_button_pressed):
		weights_button.pressed.connect(_on_weights_button_pressed)
	if not seed_bias_slider.value_changed.is_connected(_on_seed_bias_slider_value_changed):
		seed_bias_slider.value_changed.connect(_on_seed_bias_slider_value_changed)
	if not seed_bias_slider.drag_ended.is_connected(_on_seed_bias_slider_drag_ended):
		seed_bias_slider.drag_ended.connect(_on_seed_bias_slider_drag_ended)
	if not seed_bias_value.text_submitted.is_connected(_on_seed_bias_value_submitted):
		seed_bias_value.text_submitted.connect(_on_seed_bias_value_submitted)
	if not seed_bias_value.focus_exited.is_connected(_on_seed_bias_value_focus_exited):
		seed_bias_value.focus_exited.connect(_on_seed_bias_value_focus_exited)
	if not blend_slider.value_changed.is_connected(_on_blend_slider_value_changed):
		blend_slider.value_changed.connect(_on_blend_slider_value_changed)
	if not blend_slider.drag_ended.is_connected(_on_blend_slider_drag_ended):
		blend_slider.drag_ended.connect(_on_blend_slider_drag_ended)
	if not blend_value.text_submitted.is_connected(_on_blend_value_submitted):
		blend_value.text_submitted.connect(_on_blend_value_submitted)
	if not blend_value.focus_exited.is_connected(_on_blend_value_focus_exited):
		blend_value.focus_exited.connect(_on_blend_value_focus_exited)

	delta_slider.min_value = DELTA_MIN
	delta_slider.max_value = DELTA_MAX
	delta_slider.step = 0.01
	delta_slider.set_value_no_signal(0.25)
	delta_value.text = "%.2f" % delta_slider.value
	seed_bias_slider.min_value = SEED_BIAS_MIN
	seed_bias_slider.max_value = SEED_BIAS_MAX
	seed_bias_slider.step = 0.02
	blend_slider.min_value = BLEND_MIN
	blend_slider.max_value = BLEND_MAX
	blend_slider.step = 0.01
	blend_slider.set_value_no_signal(0.5)
	blend_value.text = "%.2f" % blend_slider.value

	_rebuild_tree()


func set_data(
	thresholds: PackedFloat32Array,
	neighborhoods: PackedInt32Array,
	weights: PackedFloat32Array,
	enabled: PackedInt32Array,
	seed_bias: float,
	blend_k: float
) -> void:
	_thresholds = thresholds.duplicate()
	_neighborhoods = neighborhoods.duplicate()
	_weights = weights.duplicate()
	_enabled = enabled.duplicate()
	if _neighborhoods.size() != NEIGHBORHOOD_INT_COUNT:
		_neighborhoods.resize(NEIGHBORHOOD_INT_COUNT)
		for i in range(NEIGHBORHOOD_INT_COUNT):
			_neighborhoods[i] = 0
	if _thresholds.size() != THRESHOLD_FLOAT_COUNT:
		var normalized_t := PackedFloat32Array()
		normalized_t.resize(THRESHOLD_FLOAT_COUNT)
		for i in range(min(_thresholds.size(), THRESHOLD_FLOAT_COUNT)):
			normalized_t[i] = _thresholds[i]
		_thresholds = normalized_t
	if _enabled.size() != 4:
		_enabled.resize(4)
		for i in range(4):
			_enabled[i] = 1
	if _weights.size() != WEIGHT_COUNT:
		var normalized_w := PackedFloat32Array()
		normalized_w.resize(WEIGHT_COUNT)
		for i in range(min(_weights.size(), WEIGHT_COUNT)):
			normalized_w[i] = _weights[i]
		_weights = normalized_w

	var bias := clampf(seed_bias, SEED_BIAS_MIN, SEED_BIAS_MAX)
	seed_bias_slider.set_value_no_signal(bias)
	seed_bias_value.text = "%.2f" % bias
	var blend := clampf(blend_k, BLEND_MIN, BLEND_MAX)
	blend_slider.set_value_no_signal(blend)
	blend_value.text = "%.2f" % blend
	_rebuild_tree()

func collapse_sections_for_open() -> void:
	for c in range(4):
		_section_collapsed_by_key[_section_key("neighborhoods", c)] = true
		_section_collapsed_by_key[_section_key("thresholds", c)] = true
		_section_collapsed_by_key[_section_key("weights", c)] = true
	_rebuild_tree()


func _rebuild_tree() -> void:
	_capture_section_collapsed_state()
	tree.clear()
	var root := tree.create_item()

	for c in range(4):
		var parent := tree.create_item(root)

		# Column 0: expandable row text.
		parent.set_text(0, " Candidate %d" % (c))
		parent.set_custom_minimum_height(60)
		parent.set_metadata(0, {"kind": "candidate", "candidate_index": c})
		parent.collapsed = bool(_section_collapsed_by_key.get(_section_key("candidate", c), false))

		# Column 1: action ("Adv.")
		_setup_action_cell(parent)
		# Column 2: candidate-level delta button (thresholds + neighborhoods + weights).
		_setup_candidate_delta_cell(parent)
		# Column 3: checkbox.
		parent.set_cell_mode(CHECK_COL, TreeItem.CELL_MODE_CHECK)
		parent.set_editable(CHECK_COL, true)
		parent.set_checked(CHECK_COL, _enabled[c] != 0)
		parent.set_text(CHECK_COL, "")

		var neighborhoods_node := tree.create_item(parent)
		neighborhoods_node.set_text(0, " Neighborhoods")
		neighborhoods_node.set_selectable(0, false)
		neighborhoods_node.collapsed = bool(_section_collapsed_by_key.get(_section_key("neighborhoods", c), true))
		neighborhoods_node.set_metadata(0, {"kind": "neighborhoods", "candidate_index": c})
		_setup_action_cell(neighborhoods_node)

		for n in range(2):
			var nh_row := tree.create_item(neighborhoods_node)
			nh_row.set_selectable(0, false)
			var idx := c * 2 + n
			var x := 0
			var y := 0
			if idx * 2 + 1 < _neighborhoods.size():
				x = _neighborhoods[idx * 2]
				y = _neighborhoods[idx * 2 + 1]
			var label := "A" if n == 0 else "B"
			nh_row.set_text(0, " Nbrhd %s = (%d, %d)" % [label, x, y])
			nh_row.set_custom_font_size(0, 35)
			nh_row.set_custom_minimum_height(1)

		var thresholds_node := tree.create_item(parent)
		thresholds_node.set_text(0, " Thresholds")
		thresholds_node.set_selectable(0, false)
		thresholds_node.collapsed = bool(_section_collapsed_by_key.get(_section_key("thresholds", c), true))
		thresholds_node.set_metadata(0, {"kind": "thresholds", "candidate_index": c})
		_setup_action_cell(thresholds_node)

		for t in range(THRESHOLD_VALUES_PER_CANDIDATE):
			var idx := c * THRESHOLD_VALUES_PER_CANDIDATE + t
			var row := tree.create_item(thresholds_node)
			row.set_selectable(0, false)
			var v := 0.0
			if idx < _thresholds.size():
				v = _thresholds[idx]
			var labels := ["loA1", "hiA1", "loA2", "hiA2", "loB1", "hiB1", "loB2", "hiB2"]
			row.set_text(0, " %s = %.4f" % [labels[t], v])
			row.set_custom_font_size(0, 35)
			row.set_custom_minimum_height(1)

		var weights_node := tree.create_item(parent)
		weights_node.set_text(0, " Weights")
		weights_node.set_selectable(0, false)
		weights_node.collapsed = bool(_section_collapsed_by_key.get(_section_key("weights", c), true))
		weights_node.set_metadata(0, {"kind": "weights", "candidate_index": c})
		_setup_action_cell(weights_node)

		for w_i in range(WEIGHTS_PER_CANDIDATE):
			var idx_w := c * WEIGHTS_PER_CANDIDATE + w_i
			var w_row := tree.create_item(weights_node)
			w_row.set_selectable(0, false)
			var wv := 0.0
			if idx_w < _weights.size():
				wv = _weights[idx_w]
			var w_labels := ["A1", "A2", "B1", "B2"]
			w_row.set_text(0, " w%s = %.4f" % [w_labels[w_i], wv])
			w_row.set_custom_font_size(0, 35)
			w_row.set_custom_minimum_height(1)
		parent.set_custom_font(0, bold_font)
		neighborhoods_node.set_custom_font(0, font)
		neighborhoods_node.set_custom_font_size(0, 40)
		thresholds_node.set_custom_font(0, font)
		thresholds_node.set_custom_font_size(0, 40)
		weights_node.set_custom_font(0, font)
		weights_node.set_custom_font_size(0, 40)
		_apply_candidate_visual_state(parent, _enabled[c] != 0)

func _capture_section_collapsed_state() -> void:
	var root := tree.get_root()
	if root == null:
		return
	var candidate := root.get_first_child()
	while candidate != null:
		var candidate_meta: Variant = candidate.get_metadata(0)
		var c := -1
		if typeof(candidate_meta) == TYPE_DICTIONARY:
			c = int(candidate_meta.get("candidate_index", -1))
		if c >= 0 and c < 4:
			_section_collapsed_by_key[_section_key("candidate", c)] = candidate.collapsed
			var child := candidate.get_first_child()
			while child != null:
				var meta: Variant = child.get_metadata(0)
				if typeof(meta) == TYPE_DICTIONARY:
					var kind := str(meta.get("kind", ""))
					if kind == "neighborhoods" or kind == "thresholds" or kind == "weights":
						_section_collapsed_by_key[_section_key(kind, c)] = child.collapsed
				child = child.get_next()
		candidate = candidate.get_next()

func _section_key(kind: String, candidate_index: int) -> String:
	return kind + ":" + str(candidate_index)


func _on_tree_item_edited() -> void:
	var item := tree.get_edited()
	if item == null:
		return

	# Only top-level candidate rows.
	if item.get_parent() != tree.get_root():
		return

	# Only checkbox column edits toggle candidate.
	var col := tree.get_edited_column()
	if col != CHECK_COL:
		return

	var meta: Variant = item.get_metadata(0)
	var idx := -1
	if typeof(meta) == TYPE_DICTIONARY:
		idx = int(meta.get("candidate_index", -1))
	else:
		idx = int(meta)
	if idx < 0 or idx >= 4:
		return
	var on := item.is_checked(CHECK_COL)
	_enabled[idx] = 1 if on else 0
	_apply_candidate_visual_state(item, on)
	_hover_action_key = ""
	_pressed_action_key = ""
	tree.queue_redraw()
	candidate_toggled.emit(idx, on)


func _on_tree_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var pos_motion: Vector2 = ev.position
		var motion_item := tree.get_item_at_position(pos_motion)
		var motion_col := tree.get_column_at_position(pos_motion)
		var new_hover_key := ""
		if motion_item != null:
			var motion_meta: Variant = motion_item.get_metadata(0)
			if typeof(motion_meta) == TYPE_DICTIONARY:
				var motion_kind := str(motion_meta.get("kind", ""))
				if motion_col == ACTION_COL and (motion_kind == "candidate" or motion_kind == "neighborhoods" or motion_kind == "thresholds" or motion_kind == "weights") and _is_action_item_enabled(motion_item):
					new_hover_key = _action_key_for_item(motion_item)
				elif motion_col == CANDIDATE_DELTA_COL and motion_kind == "candidate" and _is_action_item_enabled(motion_item):
					new_hover_key = _candidate_delta_key_for_item(motion_item)
		if new_hover_key != _hover_action_key:
			_hover_action_key = new_hover_key
			tree.queue_redraw()
		return

	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = ev.position
		var item := tree.get_item_at_position(pos)
		var col := tree.get_column_at_position(pos)

		if ev.pressed:
			if item != null and (col == ACTION_COL or col == CANDIDATE_DELTA_COL):
				if not _is_action_item_enabled(item):
					accept_event()
					return
				var meta: Variant = item.get_metadata(0)
				if typeof(meta) == TYPE_DICTIONARY:
					var kind := str(meta.get("kind", ""))
					var candidate_index := int(meta.get("candidate_index", -1))
					if candidate_index >= 0 and candidate_index < 4:
						if col == ACTION_COL and (kind == "candidate" or kind == "neighborhoods" or kind == "thresholds" or kind == "weights"):
							_pressed_action_key = _action_key_for_item(item)
							tree.queue_redraw()
							if kind == "neighborhoods" or kind == "thresholds" or kind == "weights":
								parent_action_pressed.emit(kind, candidate_index, delta_slider.value)
						elif col == CANDIDATE_DELTA_COL and kind == "candidate":
							_pressed_action_key = _candidate_delta_key_for_item(item)
							tree.queue_redraw()
							parent_action_pressed.emit("all", candidate_index, delta_slider.value)
				accept_event()
				return

			if item == null or item.get_parent() != tree.get_root():
				return

			# Only click on column 0 expands/collapses.
			if col == 0:
				item.collapsed = not item.collapsed
				accept_event()
				return
		else:
			if _pressed_action_key != "":
				_pressed_action_key = ""
				tree.queue_redraw()

func _on_seed_bias_slider_value_changed(v: float) -> void:
	seed_bias_value.text = "%.2f" % v
	seed_bias_changed.emit(v)

func _on_seed_bias_slider_drag_ended(value_changed: bool) -> void:
	if not value_changed:
		return
	seed_bias_committed.emit(seed_bias_slider.value)

func _on_blend_slider_value_changed(v: float) -> void:
	blend_value.text = "%.2f" % v
	blend_value_changed.emit(v)

func _on_blend_slider_drag_ended(value_changed: bool) -> void:
	if not value_changed:
		return
	blend_value_committed.emit(blend_slider.value)

func _on_delta_slider_value_changed(v: float) -> void:
	delta_value.text = "%.2f" % v

func _on_delta_value_submitted(_text: String) -> void:
	_commit_delta_value()

func _on_delta_value_focus_exited() -> void:
	_commit_delta_value()

func _commit_delta_value() -> void:
	var v := clampf(delta_value.text.to_float(), DELTA_MIN, DELTA_MAX)
	delta_slider.value = v
	delta_value.text = "%.2f" % v

func _on_all_button_pressed() -> void:
	random_delta_requested.emit("all", delta_slider.value)

func _on_thresh_button_pressed() -> void:
	random_delta_requested.emit("thresholds", delta_slider.value)

func _on_nbrhd_button_pressed() -> void:
	random_delta_requested.emit("neighborhoods", delta_slider.value)

func _on_weights_button_pressed() -> void:
	random_delta_requested.emit("weights", delta_slider.value)

func _on_seed_bias_value_submitted(_text: String) -> void:
	_commit_seed_bias_value()

func _on_seed_bias_value_focus_exited() -> void:
	_commit_seed_bias_value()

func _on_blend_value_submitted(_text: String) -> void:
	_commit_blend_value()

func _on_blend_value_focus_exited() -> void:
	_commit_blend_value()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return

	var mouse_pos: Vector2 = mb.position
	var over_delta := delta_value.get_global_rect().has_point(mouse_pos)
	var over_seed := seed_bias_value.get_global_rect().has_point(mouse_pos)
	var over_blend := blend_value.get_global_rect().has_point(mouse_pos)
	if over_delta or over_seed or over_blend:
		return

	if delta_value.has_focus():
		delta_value.release_focus()
	if seed_bias_value.has_focus():
		seed_bias_value.release_focus()
	if blend_value.has_focus():
		blend_value.release_focus()

func _commit_seed_bias_value() -> void:
	var v := clampf(seed_bias_value.text.to_float(), SEED_BIAS_MIN, SEED_BIAS_MAX)
	seed_bias_slider.value = v
	seed_bias_value.text = "%.2f" % v
	seed_bias_committed.emit(v)

func _commit_blend_value() -> void:
	var v := clampf(blend_value.text.to_float(), BLEND_MIN, BLEND_MAX)
	blend_slider.value = v
	blend_value.text = "%.2f" % v
	blend_value_committed.emit(v)

func _setup_action_cell(item: TreeItem) -> void:
	item.set_cell_mode(ACTION_COL, TreeItem.CELL_MODE_CUSTOM)
	item.set_editable(ACTION_COL, false)
	item.set_selectable(ACTION_COL, false)
	item.set_text(ACTION_COL, "")
	item.set_custom_draw_callback(ACTION_COL, Callable(self, "_draw_action_cell"))

func _setup_candidate_delta_cell(item: TreeItem) -> void:
	item.set_cell_mode(CANDIDATE_DELTA_COL, TreeItem.CELL_MODE_CUSTOM)
	item.set_editable(CANDIDATE_DELTA_COL, false)
	item.set_selectable(CANDIDATE_DELTA_COL, false)
	item.set_text(CANDIDATE_DELTA_COL, "")
	item.set_custom_draw_callback(CANDIDATE_DELTA_COL, Callable(self, "_draw_candidate_delta_cell"))

func _draw_action_cell(_item: TreeItem, rect: Rect2) -> void:
	var canvas := tree.get_canvas_item()
	var meta: Variant = _item.get_metadata(0)
	var kind := ""
	if typeof(meta) == TYPE_DICTIONARY:
		kind = str(meta.get("kind", ""))
	if kind == "candidate":
		var adv_key := _action_key_for_item(_item)
		var text_color_adv := ACTION_TEXT_IDLE if _is_action_item_enabled(_item) else ACTION_TEXT_DISABLED
		if adv_key != "" and _is_action_item_enabled(_item):
			if adv_key == _pressed_action_key:
				text_color_adv = ACTION_TEXT_PRESSED
			elif adv_key == _hover_action_key:
				text_color_adv = ACTION_TEXT_HOVER
		var adv_text := "Adv."
		var adv_size := 25
		var adv_y := rect.position.y + (rect.size.y + float(adv_size)) * 0.5 - 2.0
		var adv_w := font.get_string_size(adv_text, HORIZONTAL_ALIGNMENT_CENTER, -1, adv_size).x
		font.draw_string(
			canvas,
			Vector2(rect.position.x, adv_y),
			adv_text,
			HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x,
			adv_size,
			text_color_adv
		)
		var cx := rect.position.x + rect.size.x * 0.5
		var underline_y := adv_y + 2.0
		var x0 := cx - adv_w * 0.5
		var x1 := cx + adv_w * 0.5
		tree.draw_line(Vector2(x0, underline_y), Vector2(x1, underline_y), text_color_adv, 1.0)
		return

	var key := _action_key_for_item(_item)
	var style_name := "custom_button"
	var enabled := _is_action_item_enabled(_item)
	var text_color := ACTION_TEXT_IDLE if enabled else ACTION_TEXT_DISABLED
	if key != "" and enabled:
		if key == _pressed_action_key:
			style_name = "custom_button_pressed"
			text_color = ACTION_TEXT_PRESSED
		elif key == _hover_action_key:
			style_name = "custom_button_hover"
			text_color = ACTION_TEXT_HOVER
	var bg := tree.get_theme_stylebox(style_name)
	if bg != null:
		bg.draw(canvas, rect.grow(-2.0))
	var text := "∆"
	var font_size := 26
	var baseline_y := rect.position.y + (rect.size.y + float(font_size)) * 0.5 - 3.0
	bold_font.draw_string(
		canvas,
		Vector2(rect.position.x, baseline_y),
		text,
		HORIZONTAL_ALIGNMENT_CENTER,
		rect.size.x,
		font_size,
		text_color
	)

func _draw_candidate_delta_cell(_item: TreeItem, rect: Rect2) -> void:
	var canvas := tree.get_canvas_item()
	var meta: Variant = _item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var kind := str(meta.get("kind", ""))
	if kind != "candidate":
		return

	var key := _candidate_delta_key_for_item(_item)
	var style_name := "custom_button"
	var enabled := _is_action_item_enabled(_item)
	var text_color := ACTION_TEXT_IDLE if enabled else ACTION_TEXT_DISABLED
	if key != "" and enabled:
		if key == _pressed_action_key:
			style_name = "custom_button_pressed"
			text_color = ACTION_TEXT_PRESSED
		elif key == _hover_action_key:
			style_name = "custom_button_hover"
			text_color = ACTION_TEXT_HOVER

	var button_h := 45.0
	var button_rect := Rect2(
		rect.position.x,
		rect.position.y + (rect.size.y - button_h) * 0.5,
		rect.size.x,
		button_h
	)

	var bg := tree.get_theme_stylebox(style_name)
	if bg != null:
		bg.draw(canvas, button_rect.grow(-2.0))

	var text := "∆"
	var font_size := 26
	var baseline_y := button_rect.position.y + (button_rect.size.y + float(font_size)) * 0.5 - 3.0
	bold_font.draw_string(
		canvas,
		Vector2(button_rect.position.x, baseline_y),
		text,
		HORIZONTAL_ALIGNMENT_CENTER,
		button_rect.size.x,
		font_size,
		text_color
	)

func _is_action_item_enabled(item: TreeItem) -> bool:
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return true
	var candidate_index := int(meta.get("candidate_index", -1))
	if candidate_index < 0 or candidate_index >= _enabled.size():
		return true
	return _enabled[candidate_index] != 0

func _action_key_for_item(item: TreeItem) -> String:
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return ""
	var kind := str(meta.get("kind", ""))
	if kind != "candidate" and kind != "neighborhoods" and kind != "thresholds" and kind != "weights":
		return ""
	var candidate_index := int(meta.get("candidate_index", -1))
	if candidate_index < 0 or candidate_index >= 4:
		return ""
	return kind + ":" + str(candidate_index)

func _candidate_delta_key_for_item(item: TreeItem) -> String:
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return ""
	var kind := str(meta.get("kind", ""))
	if kind != "candidate":
		return ""
	var candidate_index := int(meta.get("candidate_index", -1))
	if candidate_index < 0 or candidate_index >= 4:
		return ""
	return "candidate_delta:" + str(candidate_index)

func _apply_candidate_visual_state(parent: TreeItem, enabled: bool) -> void:
	var c := ACTIVE_COLOR if enabled else DISABLED_COLOR
	parent.set_custom_color(0, c)
	# Child rows text
	var child := parent.get_first_child()
	while child != null:
		child.set_custom_color(0, c)
		var grandchild := child.get_first_child()
		while grandchild != null:
			grandchild.set_custom_color(0, c)
			var great_grandchild := grandchild.get_first_child()
			while great_grandchild != null:
				great_grandchild.set_custom_color(0, c)
				great_grandchild = great_grandchild.get_next()
			grandchild = grandchild.get_next()
		child = child.get_next()
