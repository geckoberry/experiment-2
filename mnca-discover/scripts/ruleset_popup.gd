extends PopupPanel
class_name RulesetPopup

signal ruleset_selected(index: int)
signal ruleset_delete_pressed(index: int)
signal ruleset_favorite_toggled(index: int, is_favorite: bool)

@onready var search_edit: LineEdit = $PanelContainer/MarginContainer/VBoxContainer/SearchEdit
@onready var scroll: ScrollContainer = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer
@onready var list: VBoxContainer = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/List
@onready var panel_container: PanelContainer = $PanelContainer
@onready var content_box: VBoxContainer = $PanelContainer/MarginContainer/VBoxContainer
@onready var flat: StyleBoxFlat = StyleBoxFlat.new()
@onready var hover_pressed: StyleBoxFlat = StyleBoxFlat.new()
@onready var disabled: StyleBoxFlat = StyleBoxFlat.new()

var font: Font = load("res://fonts/PixelOperator.ttf")
var fav_font: Font = load("res://fonts/PixelOperator-Bold.ttf")
var font_size: int = 35
var icon: Texture2D = preload("res://icons/delete.png")
var _rulesets: Array = []
var _selected_index: int = -1
var _prefix: String = ""
var _fit_queued: bool = false
var _ordered_indices: Array[int] = []
var _row_infos: Dictionary = {} # index:int -> {"root": Control, "name_lc": String}

func _ready() -> void:
	if search_edit != null and not search_edit.text_changed.is_connected(_on_search_text_changed):
		search_edit.text_changed.connect(_on_search_text_changed)
	if not about_to_popup.is_connected(_on_about_to_popup):
		about_to_popup.connect(_on_about_to_popup)

func rebuild(rulesets: Array, selected_index: int = -1) -> void:
	_rulesets = rulesets
	_selected_index = selected_index
	_rebuild_rows()
	_apply_filter_only()

func _ensure_row_styles() -> void:
	flat.bg_color = Color(0.2, 0.2, 0.2)
	hover_pressed.bg_color = Color(0.3, 0.3, 0.3)
	disabled.bg_color = Color(0.15, 0.15, 0.15)

func _rebuild_rows() -> void:
	_ensure_row_styles()

	for c in list.get_children():
		c.free()

	_ordered_indices.clear()
	_row_infos.clear()

	# 1) favorites in original order
	for j in range(_rulesets.size()):
		var rs_fav_var: Variant = _rulesets[j]
		if typeof(rs_fav_var) != TYPE_DICTIONARY:
			continue
		var rs_fav: Dictionary = rs_fav_var
		if bool(rs_fav.get("favorite", false)):
			_ordered_indices.append(j)

	# 2) non-favorites in original order
	for j in range(_rulesets.size()):
		var rs_nonfav_var: Variant = _rulesets[j]
		if typeof(rs_nonfav_var) != TYPE_DICTIONARY:
			continue
		var rs_nonfav: Dictionary = rs_nonfav_var
		if not bool(rs_nonfav.get("favorite", false)):
			_ordered_indices.append(j)

	for i in _ordered_indices:
		var rs_var: Variant = _rulesets[i]
		if typeof(rs_var) != TYPE_DICTIONARY:
			continue
		var rs: Dictionary = rs_var
		var rs_name: String = str(rs.get("name", "Ruleset %d" % i))
		var is_fav: bool = bool(rs.get("favorite", false))
		var name_lc: String = rs_name.to_lower()

		var row_root: Control = _create_row(i, rs_name, is_fav)
		list.add_child(row_root)
		_row_infos[i] = {"root": row_root, "name_lc": name_lc}

func _create_row(i: int, rs_name: String, is_fav: bool) -> Control:
		# --- Row root ---
	var row_root := Control.new()
	row_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_root.custom_minimum_size = Vector2(0, 40)

	# Background panel
	var bg := Panel.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	row_root.add_child(bg)

	# Layout
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 0)
	row_root.add_child(row)

	var empty := StyleBoxEmpty.new()

	# --- Select button ---
	var select_btn := Button.new()
	select_btn.text = (" ") + rs_name
	select_btn.custom_minimum_size = Vector2.ZERO
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

	# Make select take remaining width + truncate long names
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_btn.size_flags_stretch_ratio = 1.0
	select_btn.clip_text = true
	select_btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING

	# Transparent button bg (panel draws bg)
	select_btn.add_theme_stylebox_override("normal", empty)
	select_btn.add_theme_stylebox_override("hover", empty)
	select_btn.add_theme_stylebox_override("pressed", empty)
	select_btn.add_theme_stylebox_override("disabled", empty)
	select_btn.add_theme_stylebox_override("focus", empty)

	if font:
		select_btn.add_theme_font_override("font", font)
		select_btn.add_theme_font_size_override("font_size", font_size)
	if fav_font and is_fav:
		select_btn.add_theme_font_override("font", fav_font)
		select_btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.4, 1.0))
		select_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.5, 1.0))
		select_btn.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 0.8, 1.0))
		select_btn.add_theme_color_override("font_disabled_color", Color(0.8, 0.8, 0.3, 0.7))

	# --- Delete button ---
	var del_btn := Button.new()
	del_btn.icon = icon
	del_btn.text = ""
	del_btn.expand_icon = false
	del_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	del_btn.focus_mode = Control.FOCUS_NONE

	# Keep delete from being pushed out
	del_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	del_btn.size_flags_stretch_ratio = 0.0

	var del_width: float = 40.0
	del_btn.custom_minimum_size = Vector2(0, 40) # start collapsed (0 width, fixed height)
	del_btn.modulate.a = 0.0

	# Transparent bg
	del_btn.add_theme_stylebox_override("normal", empty)
	del_btn.add_theme_stylebox_override("hover", empty)
	del_btn.add_theme_stylebox_override("pressed", empty)
	del_btn.add_theme_stylebox_override("disabled", empty)
	del_btn.add_theme_stylebox_override("focus", empty)

	# Icon tint states
	del_btn.add_theme_color_override("icon_normal_color", Color(1, 1, 1, 0.4))
	del_btn.add_theme_color_override("icon_hover_color", Color(1, 1, 1, 0.6))
	del_btn.add_theme_color_override("icon_pressed_color", Color(1, 1, 1, 1.0))
	del_btn.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.05))

	row.add_child(select_btn)
	row.add_child(del_btn)

	# --- Initial background ---
	if i == _selected_index:
		select_btn.disabled = true
		bg.add_theme_stylebox_override("panel", disabled)
	else:
		bg.add_theme_stylebox_override("panel", flat)
	if is_fav:
		del_btn.disabled = true

	var row_index: int = i

	# --- Actions ---
	select_btn.pressed.connect(func():
		ruleset_selected.emit(row_index)
		hide()
	)

	del_btn.pressed.connect(func():
		ruleset_delete_pressed.emit(row_index)
	)

	select_btn.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			var new_fav: bool = not is_fav
			ruleset_favorite_toggled.emit(row_index, new_fav)
			get_viewport().set_input_as_handled()
	)

	# --- Hover enter (show delete + hover bg) ---
	select_btn.mouse_entered.connect(func():
		if not is_instance_valid(del_btn):
			return
		if not select_btn.disabled:
			bg.add_theme_stylebox_override("panel", hover_pressed)
		del_btn.custom_minimum_size.x = del_width
		del_btn.modulate.a = 1.0
		row.queue_sort()
	)

	del_btn.mouse_entered.connect(func():
		if not is_instance_valid(del_btn):
			return
		if not select_btn.disabled:
			bg.add_theme_stylebox_override("panel", hover_pressed)
		del_btn.custom_minimum_size.x = del_width
		del_btn.modulate.a = 1.0
		row.queue_sort()
	)

	# --- Hover exit (hide only if mouse left the whole row) ---
	select_btn.mouse_exited.connect(func():
		await get_tree().process_frame
		if not is_instance_valid(row_root):
			return
		if not row_root.get_global_rect().has_point(get_viewport().get_mouse_position()):
			bg.add_theme_stylebox_override("panel", disabled if select_btn.disabled else flat)
			if is_instance_valid(del_btn):
				del_btn.custom_minimum_size.x = 0.0
				del_btn.modulate.a = 0.0
				row.queue_sort()
	)

	del_btn.mouse_exited.connect(func():
		await get_tree().process_frame
		if not is_instance_valid(row_root):
			return
		if not row_root.get_global_rect().has_point(get_viewport().get_mouse_position()):
			bg.add_theme_stylebox_override("panel", disabled if select_btn.disabled else flat)
			if is_instance_valid(del_btn):
				del_btn.custom_minimum_size.x = 0.0
				del_btn.modulate.a = 0.0
				row.queue_sort()
	)

	return row_root

func _apply_filter_only() -> void:
	var needle: String = _prefix.strip_edges().to_lower()
	var visible_pos: int = 0
	for i in _ordered_indices:
		var info_var: Variant = _row_infos.get(i, null)
		if typeof(info_var) != TYPE_DICTIONARY:
			continue
		var info: Dictionary = info_var
		var root_var: Variant = info.get("root", null)
		if typeof(root_var) != TYPE_OBJECT:
			continue
		var row_root: Control = root_var as Control
		if row_root == null:
			continue
		var name_lc: String = str(info.get("name_lc", ""))
		var visible_match: bool = needle.is_empty() or name_lc.begins_with(needle)
		row_root.visible = visible_match
		if visible_match:
			list.move_child(row_root, visible_pos)
			visible_pos += 1
	_queue_popup_fit()

func _on_search_text_changed(new_text: String) -> void:
	_prefix = new_text
	_apply_filter_only()

func _on_about_to_popup() -> void:
	_prefix = ""
	if search_edit != null:
		search_edit.text = ""
		search_edit.call_deferred("grab_focus")
	_apply_filter_only()

func _queue_popup_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	call_deferred("_fit_popup_size")

func _fit_popup_size() -> void:
	_fit_queued = false
	var max_popup_h: float = ProjectSettings.get_setting("display/window/size/viewport_height") / 2.0
	var list_content_h: float = list.get_combined_minimum_size().y
	var search_h: float = search_edit.get_combined_minimum_size().y
	var v_sep := float(content_box.get_theme_constant("separation"))

	# Keep list scrollable while allowing the popup itself to match true content size.
	var max_list_h: float = maxf(0.0, max_popup_h - search_h - v_sep)
	var list_visible_h: float = minf(list_content_h, max_list_h)
	scroll.custom_minimum_size.y = list_visible_h

	# Let Godot compute final minimums (including container/theme paddings), then apply.
	var content_min: Vector2 = panel_container.get_combined_minimum_size()
	size.x = content_min.x
	size.y = content_min.y
