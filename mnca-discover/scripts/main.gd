extends Control

@onready var tex_rect: TextureRect = $TextureRect
@onready var ui_root: Control = $UIControl
@onready var top_bar: Control = $UIControl/TopBar
@onready var clear_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/ClearButton
@onready var reset_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/ResetButton
@onready var random_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/RandomizeButton
@onready var rulesets_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/RulesetsButton
@onready var modify_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/ModifyButton
@onready var confirm_btn: Button = $UIControl/SavePanel/MarginContainer/VBoxContainer/HBoxContainer/ConfirmButton
@onready var cancel_btn: Button = $UIControl/SavePanel/MarginContainer/VBoxContainer/HBoxContainer/CancelButton
@onready var save_as_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/SaveAsButton
@onready var save_btn: Button = $UIControl/TopBar/MarginContainer/HBoxContainer/SaveButton
@onready var save_panel: Control = $UIControl/SavePanel
@onready var modify_panel: ModifyPanel = $UIControl/ModifyPanel
@onready var modify_close_btn: Button = $UIControl/ModifyPanel/CloseButton
@onready var undo_redo_container: Control = $UIControl/UndoRedoContainer
@onready var undo_btn: Button = $UIControl/UndoRedoContainer/UndoButton
@onready var redo_btn: Button = $UIControl/UndoRedoContainer/RedoButton
@onready var fps_label: Label = $UIControl/FPSLabel
@onready var name_edit: LineEdit = $UIControl/SavePanel/MarginContainer/VBoxContainer/MarginContainer/NameEdit
@onready var ruleset_popup: PopupPanel = $UIControl/RulesetPopup

var W: int = 1
var H: int = 1
var SCALE: int = 4
const LOCAL_X := 8
const LOCAL_Y := 8
const MAX_RADIUS := 12
const THRESHOLD_DELTA_AMPLITUDE := 0.07
const NEIGHBORHOOD_DELTA_AMPLITUDE := 6.0
const WEIGHT_DELTA_AMPLITUDE := 0.4
const TRACKPAD_SCROLL_SENSITIVITY := 0.06
const RULESET_HISTORY_MAX := 64
const FPS_LABEL_MARGIN_X := 20.0
const FPS_LABEL_MARGIN_Y := 20.0
const UNDO_REDO_X := 50.0
const UNDO_REDO_GAP_Y := 20.0
const THRESHOLD_FLOAT_COUNT := 32
const THRESHOLD_PAIRS_PER_CANDIDATE := 4
const THRESHOLD_VALUES_PER_CANDIDATE := 8
const WEIGHT_COUNT := 16
const WEIGHTS_PER_CANDIDATE := 4
const NEIGHBORHOOD_INT_COUNT := 16
const SAVE_PANEL_DIM_ALPHA := 0.75

var selected_ruleset_index := -1
var ruleset_index_by_key: Dictionary = {} # key:String -> index:int
var ruleset_name_set: Dictionary = {} # lowercase_name:String -> true

var store: DiskStore
var sim: SimGPU
var modify_fade_tween: Tween
var save_fade_tween: Tween
var undo_redo_fade_tween: Tween
var modify_input_blocker: ColorRect
var ruleset_history: Array[Dictionary] = []
var ruleset_history_index := -1
var _applying_history_state := false
var opened_saved_ruleset_index := -1
var _pending_undo_redo_action := "" # "", "undo", "redo"
var sim_paused := false


func _ready() -> void:
	var proj_w := int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	var proj_h := int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	if proj_w <= 0 or proj_h <= 0:
		var win_size: Vector2i = get_window().size
		proj_w = win_size.x
		proj_h = win_size.y
	W = maxi(1, int(floor(float(proj_w) / float(SCALE))))
	H = maxi(1, int(floor(float(proj_h) / float(SCALE))))
	tex_rect.set_anchors_preset(Control.PRESET_TOP_LEFT)
	tex_rect.offset_left = 0.0
	tex_rect.offset_top = 0.0
	tex_rect.offset_right = float(W * SCALE)
	tex_rect.offset_bottom = float(H * SCALE)
	_layout_top_bars()
	_layout_save_panel_centered()
	_layout_undo_redo_container()

	# Modules
	store = DiskStore.new()
	store.load_from_disk()
	_rebuild_ruleset_index_map()

	var rd := RenderingServer.get_rendering_device()
	sim = SimGPU.new()
	sim.init(rd, "res://shaders/ca_step.glsl", W, H, LOCAL_X, LOCAL_Y, MAX_RADIUS)

	# Display
	tex_rect.texture = sim.get_display_texture()
	sim.seed_random()

	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	if not modify_panel.candidate_toggled.is_connected(_on_modify_candidate_toggled):
		modify_panel.candidate_toggled.connect(_on_modify_candidate_toggled)
	if not modify_panel.seed_bias_changed.is_connected(_on_modify_seed_bias_changed):
		modify_panel.seed_bias_changed.connect(_on_modify_seed_bias_changed)
	if not modify_panel.seed_bias_committed.is_connected(_on_modify_seed_bias_committed):
		modify_panel.seed_bias_committed.connect(_on_modify_seed_bias_committed)
	if not modify_panel.blend_value_changed.is_connected(_on_modify_blend_value_changed):
		modify_panel.blend_value_changed.connect(_on_modify_blend_value_changed)
	if not modify_panel.blend_value_committed.is_connected(_on_modify_blend_value_committed):
		modify_panel.blend_value_committed.connect(_on_modify_blend_value_committed)
	if not modify_panel.random_delta_requested.is_connected(_on_modify_random_delta_requested):
		modify_panel.random_delta_requested.connect(_on_modify_random_delta_requested)
	if not modify_panel.parent_action_pressed.is_connected(_on_modify_parent_action_pressed):
		modify_panel.parent_action_pressed.connect(_on_modify_parent_action_pressed)

	# UI
	modify_input_blocker = ColorRect.new()
	modify_input_blocker.name = "InputBlocker"
	modify_input_blocker.color = Color(0, 0, 0, 0) # invisible
	modify_input_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	modify_input_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	modify_input_blocker.visible = false
	modify_input_blocker.z_index = 1000
	modify_panel.add_child(modify_input_blocker)
	modify_panel.visible = false
	if undo_redo_container != null:
		undo_redo_container.visible = false
	ruleset_popup.ruleset_selected.connect(_on_ruleset_selected)
	ruleset_popup.ruleset_delete_pressed.connect(_on_ruleset_delete_from_popup)
	ruleset_popup.ruleset_favorite_toggled.connect(_on_ruleset_favorite_toggled)
	_rebuild_ruleset_menu()

	selected_ruleset_index = -1
	_history_reset_to_current_state()
	_update_button_states()

	# (Optional) connect signals in code if not connected in editor
	if not clear_btn.pressed.is_connected(_on_clear_button_pressed):
		clear_btn.pressed.connect(_on_clear_button_pressed)
	if not reset_btn.pressed.is_connected(_on_reset_button_pressed):
		reset_btn.pressed.connect(_on_reset_button_pressed)
	if not random_btn.pressed.is_connected(_on_randomize_button_pressed):
		random_btn.pressed.connect(_on_randomize_button_pressed)
	if not modify_btn.pressed.is_connected(_on_modify_button_pressed):
		modify_btn.pressed.connect(_on_modify_button_pressed)
	if not save_as_btn.pressed.is_connected(_on_save_as_button_pressed):
		save_as_btn.pressed.connect(_on_save_as_button_pressed)
	if not save_btn.pressed.is_connected(_on_save_ruleset_button_pressed):
		save_btn.pressed.connect(_on_save_ruleset_button_pressed)
	if not confirm_btn.pressed.is_connected(_on_save_as_confirm_pressed):
		confirm_btn.pressed.connect(_on_save_as_confirm_pressed)
	if not cancel_btn.pressed.is_connected(_on_save_cancel_pressed):
		cancel_btn.pressed.connect(_on_save_cancel_pressed)
	if modify_close_btn != null and not modify_close_btn.pressed.is_connected(_on_modify_close_pressed):
		modify_close_btn.pressed.connect(_on_modify_close_pressed)
	if undo_btn != null and not undo_btn.pressed.is_connected(_on_undo_button_pressed):
		undo_btn.pressed.connect(_on_undo_button_pressed)
	if redo_btn != null and not redo_btn.pressed.is_connected(_on_redo_button_pressed):
		redo_btn.pressed.connect(_on_redo_button_pressed)

	_update_fps_label()


func _exit_tree() -> void:
	# Important: release GPU resources
	if sim != null:
		sim.free_all()


func _process(_dt: float) -> void:
	if not sim_paused:
		sim.step()
	_update_fps_label()


# ---------------- RULESETS MENU / STORE ----------------

func _load_rulesets_menu_items(popup: PopupMenu) -> void:
	popup.clear()
	for i in range(store.rulesets.size()):
		popup.add_item(store.rulesets[i].get("name", "Ruleset " + str(i)), i)


func _rebuild_ruleset_menu() -> void:
	ruleset_popup.rebuild(store.rulesets, selected_ruleset_index)


func _on_ruleset_selected(id: int) -> void:
	if id < 0 or id >= store.rulesets.size():
		return

	var rs: Dictionary = store.rulesets[id]
	var thr := _thresholds_from_saved(rs)
	var nh := PackedInt32Array(rs.get("neighborhoods", []))
	var weights := _weights_from_saved(rs)
	var enabled := _disabled_candidates_to_enabled(rs.get("disabled_candidates", []))
	var seed_bias := float(rs.get("seed_bias", 1.3))
	var blend_k := float(rs.get("blend_k", 0.5))

	if not sim.apply_ruleset(thr, nh, weights, enabled, seed_bias, blend_k):
		return

	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	opened_saved_ruleset_index = id
	_sync_selected_ruleset_index_from_current_state()
	_history_reset_to_current_state()


# ---------------- BUTTONS ----------------

func _on_reset_button_pressed() -> void:
	sim.reset_state()
	# selection stays the same

func _on_randomize_button_pressed() -> void:
	sim.randomize_params_and_reset()
	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	opened_saved_ruleset_index = -1
	_sync_selected_ruleset_index_from_current_state()
	_history_reset_to_current_state()

func _on_clear_button_pressed() -> void:
	sim.seed_empty()

func _on_save_as_button_pressed() -> void:
	_layout_save_panel_centered()
	save_fade_tween = _fade_in_panel(save_panel, save_fade_tween)
	name_edit.grab_focus()
	name_edit.text = ""
	_set_modify_interaction_enabled(false)
	_set_save_panel_dim(true)
	_update_button_states()

func _on_modify_button_pressed() -> void:
	modify_panel.collapse_sections_for_open()
	_layout_undo_redo_container()
	modify_fade_tween = _fade_in_panel(modify_panel, modify_fade_tween)
	if undo_redo_container != null:
		undo_redo_fade_tween = _fade_in_panel(undo_redo_container, undo_redo_fade_tween)
	_update_button_states()

func _on_modify_close_pressed() -> void:
	modify_fade_tween = _fade_out_panel(modify_panel, modify_fade_tween)
	if undo_redo_container != null:
		undo_redo_fade_tween = _fade_out_panel(undo_redo_container, undo_redo_fade_tween)

func _on_save_cancel_pressed() -> void:
	save_fade_tween = _fade_out_panel(save_panel, save_fade_tween)
	save_fade_tween.finished.connect(func():
		_set_modify_interaction_enabled(true)
		_set_save_panel_dim(false)
		_update_button_states()
	)

func _on_save_as_confirm_pressed() -> void:
	var ruleset_name := name_edit.text.strip_edges()
	if ruleset_name.is_empty():
		ruleset_name = "Unnamed Ruleset"
	if ruleset_name != "Unnamed Ruleset" and _ruleset_name_exists(ruleset_name):
		push_warning("Ruleset name already exists: " + ruleset_name)
		name_edit.text = "Already exists!"
		name_edit.grab_focus()
		name_edit.select_all()
		return
	var thr := sim.get_current_thresholds()
	var nh := sim.get_current_neighborhoods()
	var weights := sim.get_current_weights()
	var enabled := _normalize_candidate_enableds(sim.get_candidate_enableds())
	var disabled := _enabled_to_disabled_candidates(enabled)
	var seed_bias := sim.get_seed_noise_bias()
	var blend_k := sim.get_blend_k()
	if thr.size() != THRESHOLD_FLOAT_COUNT or nh.size() != NEIGHBORHOOD_INT_COUNT or weights.size() != WEIGHT_COUNT:
		push_error("Nothing valid to save yet (thresholds/neighborhoods/weights not ready).")
		return
	store.add_ruleset(ruleset_name, thr, nh, weights, disabled, seed_bias, blend_k)
	opened_saved_ruleset_index = store.rulesets.size() - 1
	store.save_to_disk()
	_rebuild_ruleset_index_map()
	_rebuild_ruleset_menu()
	save_fade_tween = _fade_out_panel(save_panel, save_fade_tween)
	save_fade_tween.finished.connect(func():
		_set_modify_interaction_enabled(true)
		_set_save_panel_dim(false)
		_update_button_states()
	)
	_sync_selected_ruleset_index_from_current_state()

func _on_save_ruleset_button_pressed() -> void:
	if not _can_save_over_original_ruleset():
		return
	var idx := opened_saved_ruleset_index
	if idx < 0 or idx >= store.rulesets.size():
		return

	var thr := sim.get_current_thresholds()
	var nh := sim.get_current_neighborhoods()
	var weights := sim.get_current_weights()
	var enabled := _normalize_candidate_enableds(sim.get_candidate_enableds())
	var disabled := _enabled_to_disabled_candidates(enabled)
	var seed_bias := sim.get_seed_noise_bias()
	var blend_k := sim.get_blend_k()
	if thr.size() != THRESHOLD_FLOAT_COUNT or nh.size() != NEIGHBORHOOD_INT_COUNT or weights.size() != WEIGHT_COUNT:
		push_error("Nothing valid to save yet (thresholds/neighborhoods/weights not ready).")
		return

	store.update_ruleset(idx, thr, nh, weights, disabled, seed_bias, blend_k)
	store.save_to_disk()
	_rebuild_ruleset_index_map()
	_rebuild_ruleset_menu()
	_sync_selected_ruleset_index_from_current_state()


func _update_button_states() -> void:
	var blocked := save_panel.visible
	clear_btn.disabled = blocked
	reset_btn.disabled = blocked
	random_btn.disabled = blocked
	save_as_btn.disabled = (selected_ruleset_index != -1 or blocked)
	save_btn.disabled = blocked or not _can_save_over_original_ruleset()
	rulesets_btn.disabled = blocked
	modify_btn.disabled = save_panel.visible or modify_panel.visible
	if undo_btn != null:
		undo_btn.disabled = blocked or not modify_panel.visible or not _can_undo()
	if redo_btn != null:
		redo_btn.disabled = blocked or not modify_panel.visible or not _can_redo()

func _set_save_panel_dim(dimmed: bool) -> void:
	var dim_alpha := SAVE_PANEL_DIM_ALPHA if dimmed else 1.0
	if modify_panel != null:
		modify_panel.modulate.a = dim_alpha
	if undo_redo_container != null:
		undo_redo_container.modulate.a = dim_alpha

func _on_rulesets_button_pressed() -> void:
	_rebuild_ruleset_menu()
	var r := rulesets_btn.get_global_rect()
	ruleset_popup.position = Vector2i(r.position.x, r.position.y + r.size.y)
	ruleset_popup.popup()

func _on_ruleset_delete_from_popup(id: int) -> void:
	if id < 0 or id >= store.rulesets.size():
		return
	if opened_saved_ruleset_index == id:
		opened_saved_ruleset_index = -1
	elif id < opened_saved_ruleset_index:
		opened_saved_ruleset_index -= 1
	store.remove_ruleset(id)
	store.save_to_disk()
	_rebuild_ruleset_index_map()
	_rebuild_ruleset_menu()
	_sync_selected_ruleset_index_from_current_state()

func _on_ruleset_favorite_toggled(index: int, is_favorite: bool) -> void:
	if index < 0 or index >= store.rulesets.size():
		return
	store.rulesets[index]["favorite"] = is_favorite
	store.save_to_disk()
	ruleset_popup.rebuild(store.rulesets, selected_ruleset_index)

func _on_modify_candidate_toggled(candidate_index: int, enabled: bool) -> void:
	sim.set_candidate_enabled(candidate_index, enabled)
	_sync_selected_ruleset_index_from_current_state()
	_record_current_ruleset_state()

func _on_modify_seed_bias_changed(value: float) -> void:
	sim.set_seed_noise_bias(value)
	_sync_selected_ruleset_index_from_current_state()

func _on_modify_seed_bias_committed(_value: float) -> void:
	_record_current_ruleset_state()

func _on_modify_blend_value_changed(value: float) -> void:
	sim.set_blend_k(value)
	_sync_selected_ruleset_index_from_current_state()

func _on_modify_blend_value_committed(_value: float) -> void:
	_record_current_ruleset_state()

func _on_modify_random_delta_requested(target: String, strength: float) -> void:
	var s := clampf(strength, 0.0, 1.0)
	if s <= 0.0:
		return

	var apply_thr := (target == "all" or target == "thresholds")
	var apply_nh := (target == "all" or target == "neighborhoods")
	var apply_w := (target == "all" or target == "weights")
	if not apply_thr and not apply_nh and not apply_w:
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var thr := sim.get_current_thresholds().duplicate()
	var nh := sim.get_current_neighborhoods().duplicate()
	var weights := sim.get_current_weights().duplicate()

	if apply_thr:
		_apply_random_delta_to_thresholds(thr, rng, s)
		if not sim.set_thresholds(thr):
			return

	if apply_nh:
		_apply_random_delta_to_neighborhoods(nh, rng, s)
		if not sim.set_neighborhoods(nh):
			return

	if apply_w:
		_apply_random_delta_to_weights(weights, rng, s)
		if not sim.set_weights(weights):
			return

	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	_sync_selected_ruleset_index_from_current_state()
	_record_current_ruleset_state()

func _on_modify_parent_action_pressed(kind: String, candidate_index: int, strength: float) -> void:
	if candidate_index < 0 or candidate_index >= 4:
		return
	var s := clampf(strength, 0.0, 1.0)
	if s <= 0.0:
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var thr := sim.get_current_thresholds().duplicate()
	var nh := sim.get_current_neighborhoods().duplicate()
	var weights := sim.get_current_weights().duplicate()
	var ok := true

	if kind == "all":
		_apply_random_delta_to_thresholds_candidate(thr, rng, s, candidate_index)
		_apply_random_delta_to_neighborhoods_candidate(nh, rng, s, candidate_index)
		_apply_random_delta_to_weights_candidate(weights, rng, s, candidate_index)
		ok = sim.set_thresholds(thr)
		ok = ok and sim.set_neighborhoods(nh)
		ok = ok and sim.set_weights(weights)
		if not ok:
			return
	elif kind == "thresholds":
		_apply_random_delta_to_thresholds_candidate(thr, rng, s, candidate_index)
		if not sim.set_thresholds(thr):
			return
	elif kind == "neighborhoods":
		_apply_random_delta_to_neighborhoods_candidate(nh, rng, s, candidate_index)
		if not sim.set_neighborhoods(nh):
			return
	elif kind == "weights":
		_apply_random_delta_to_weights_candidate(weights, rng, s, candidate_index)
		if not sim.set_weights(weights):
			return
	else:
		return

	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	_sync_selected_ruleset_index_from_current_state()
	_record_current_ruleset_state()

func _on_undo_button_pressed() -> void:
	if not _can_undo():
		return
	ruleset_history_index -= 1
	_apply_history_snapshot(ruleset_history[ruleset_history_index])

func _on_redo_button_pressed() -> void:
	if not _can_redo():
		return
	ruleset_history_index += 1
	_apply_history_snapshot(ruleset_history[ruleset_history_index])

func _set_modify_interaction_enabled(enabled: bool) -> void:
	if modify_input_blocker != null:
		modify_input_blocker.visible = not enabled

# ---------------- TWEEN ----------------

const PANEL_FADE_IN_SEC := 0.08
const PANEL_FADE_OUT_SEC := 0.05

func _fade_in_panel(panel: Control, tween_ref: Tween, duration := PANEL_FADE_IN_SEC) -> Tween:
	if tween_ref and tween_ref.is_valid():
		tween_ref.kill()

	panel.visible = true
	panel.move_to_front()
	panel.modulate.a = 0.0

	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, duration) \
		.set_trans(Tween.TRANS_SINE) \
		.set_ease(Tween.EASE_OUT)
	return tw

func _fade_out_panel(panel: Control, tween_ref: Tween, duration := PANEL_FADE_OUT_SEC) -> Tween:
	if tween_ref and tween_ref.is_valid():
		tween_ref.kill()

	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_SINE) \
		.set_ease(Tween.EASE_IN)
	tw.finished.connect(func():
		panel.visible = false
		panel.modulate.a = 1.0
		_update_button_states()
	)
	return tw

# ---------------- HASHING RULESETS ----------------

func _ruleset_key_from_parts(
	thr: PackedFloat32Array,
	nh: PackedInt32Array,
	weights: PackedFloat32Array,
	disabled_candidates: PackedInt32Array,
	seed_bias: float,
	blend_k: float
) -> String:
	var parts := PackedStringArray()
	parts.append("t")
	for v in thr:
		# Quantize to avoid tiny float noise mismatches.
		parts.append(str(int(round(v * 1000000.0))))
	parts.append("n")
	for v in nh:
		parts.append(str(v))
	parts.append("w")
	for v in weights:
		parts.append(str(int(round(v * 1000000.0))))
	parts.append("d")
	var d_arr := Array(disabled_candidates)
	d_arr.sort()
	for v in d_arr:
		parts.append(str(int(v)))
	parts.append("s")
	parts.append(str(int(round(seed_bias * 1000000.0))))
	parts.append("b")
	parts.append(str(int(round(blend_k * 1000000.0))))
	return "|".join(parts)


func _ruleset_key_from_saved(rs: Dictionary) -> String:
	var thr := _thresholds_from_saved(rs)
	var nh := PackedInt32Array(rs.get("neighborhoods", []))
	var weights := _weights_from_saved(rs)
	var disabled := PackedInt32Array(rs.get("disabled_candidates", []))
	var seed_bias := float(rs.get("seed_bias", 1.3))
	var blend_k := float(rs.get("blend_k", 0.5))
	return _ruleset_key_from_parts(thr, nh, weights, disabled, seed_bias, blend_k)


func _current_ruleset_key() -> String:
	var thr := sim.get_current_thresholds()
	var nh := sim.get_current_neighborhoods()
	var weights := sim.get_current_weights()
	var enabled := _normalize_candidate_enableds(sim.get_candidate_enableds())
	var disabled := _enabled_to_disabled_candidates(enabled)
	return _ruleset_key_from_parts(thr, nh, weights, disabled, sim.get_seed_noise_bias(), sim.get_blend_k())


func _rebuild_ruleset_index_map() -> void:
	ruleset_index_by_key.clear()
	ruleset_name_set.clear()
	for i in range(store.rulesets.size()):
		var key := _ruleset_key_from_saved(store.rulesets[i])
		# Keep first occurrence if duplicates exist.
		if not ruleset_index_by_key.has(key):
			ruleset_index_by_key[key] = i
		var rs_var: Variant = store.rulesets[i]
		if typeof(rs_var) == TYPE_DICTIONARY:
			var rs: Dictionary = rs_var
			var name_lc := str(rs.get("name", "")).strip_edges().to_lower()
			if not name_lc.is_empty():
				ruleset_name_set[name_lc] = true


func _sync_selected_ruleset_index_from_current_state() -> void:
	var key := _current_ruleset_key()
	selected_ruleset_index = int(ruleset_index_by_key.get(key, -1))
	_update_button_states()
	if ruleset_popup.visible:
		_rebuild_ruleset_menu()


# ---------------- CANDIDATE TOGGLING ----------------

func _normalize_candidate_enableds(mask: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array([1, 1, 1, 1])
	for i in range(min(mask.size(), 4)):
		out[i] = 1 if mask[i] != 0 else 0
	return out

func _disabled_candidates_to_enabled(disabled_raw: Variant) -> PackedInt32Array:
	var enabled := PackedInt32Array([1, 1, 1, 1])
	if typeof(disabled_raw) != TYPE_ARRAY and typeof(disabled_raw) != TYPE_PACKED_INT32_ARRAY:
		return enabled

	var disabled := PackedInt32Array(disabled_raw)
	for idx in disabled:
		if idx >= 0 and idx < 4:
			enabled[idx] = 0
	return enabled

func _weights_from_saved(rs: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array(rs.get("weights", []))
	if out.size() != WEIGHT_COUNT:
		return PackedFloat32Array()
	return out

func _thresholds_from_saved(rs: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array(rs.get("thresholds", []))
	if out.size() != THRESHOLD_FLOAT_COUNT:
		return PackedFloat32Array()
	return out

func _enabled_to_disabled_candidates(enabled: PackedInt32Array) -> PackedInt32Array:
	var e := _normalize_candidate_enableds(enabled)
	var out := PackedInt32Array()
	for i in range(4):
		if e[i] == 0:
			out.append(i)
	return out

func _ruleset_name_exists(rs_name: String) -> bool:
	var needle := rs_name.strip_edges().to_lower()
	if needle.is_empty():
		return false
	return ruleset_name_set.has(needle)

func _can_save_over_original_ruleset() -> bool:
	var idx := opened_saved_ruleset_index
	if idx < 0 or idx >= store.rulesets.size():
		return false
	var current_key := _current_ruleset_key()
	var origin_key := _ruleset_key_from_saved(store.rulesets[idx])
	return current_key != origin_key

func _make_ruleset_snapshot() -> Dictionary:
	return {
		"thresholds": sim.get_current_thresholds().duplicate(),
		"neighborhoods": sim.get_current_neighborhoods().duplicate(),
		"weights": sim.get_current_weights().duplicate(),
		"enabled": _normalize_candidate_enableds(sim.get_candidate_enableds()),
		"seed_bias": sim.get_seed_noise_bias(),
		"blend_k": sim.get_blend_k()
	}

func _snapshot_key(snapshot: Dictionary) -> String:
	var thr := PackedFloat32Array(snapshot.get("thresholds", PackedFloat32Array()))
	var nh := PackedInt32Array(snapshot.get("neighborhoods", PackedInt32Array()))
	var weights := PackedFloat32Array(snapshot.get("weights", PackedFloat32Array()))
	var enabled := _normalize_candidate_enableds(PackedInt32Array(snapshot.get("enabled", PackedInt32Array([1, 1, 1, 1]))))
	var disabled := _enabled_to_disabled_candidates(enabled)
	var seed_bias := float(snapshot.get("seed_bias", 1.3))
	var blend_k := float(snapshot.get("blend_k", 0.5))
	return _ruleset_key_from_parts(thr, nh, weights, disabled, seed_bias, blend_k)

func _history_reset_to_current_state() -> void:
	ruleset_history.clear()
	ruleset_history_index = -1
	_record_current_ruleset_state()

func _record_current_ruleset_state() -> void:
	if _applying_history_state:
		return
	var snap := _make_ruleset_snapshot()
	var snap_key := _snapshot_key(snap)
	if ruleset_history_index >= 0 and ruleset_history_index < ruleset_history.size():
		if _snapshot_key(ruleset_history[ruleset_history_index]) == snap_key:
			_update_button_states()
			return

	while ruleset_history.size() - 1 > ruleset_history_index:
		ruleset_history.remove_at(ruleset_history.size() - 1)

	ruleset_history.append(snap)
	ruleset_history_index = ruleset_history.size() - 1

	if ruleset_history.size() > RULESET_HISTORY_MAX:
		ruleset_history.remove_at(0)
		ruleset_history_index -= 1

	_update_button_states()

func _apply_history_snapshot(snapshot: Dictionary) -> void:
	var thr := PackedFloat32Array(snapshot.get("thresholds", PackedFloat32Array()))
	var nh := PackedInt32Array(snapshot.get("neighborhoods", []))
	var weights := PackedFloat32Array(snapshot.get("weights", PackedFloat32Array()))
	var enabled := _normalize_candidate_enableds(PackedInt32Array(snapshot.get("enabled", [1, 1, 1, 1])))
	var seed_bias := float(snapshot.get("seed_bias", 1.3))
	var blend_k := float(snapshot.get("blend_k", 0.5))
	if thr.size() != THRESHOLD_FLOAT_COUNT or nh.size() != NEIGHBORHOOD_INT_COUNT or weights.size() != WEIGHT_COUNT:
		return

	_applying_history_state = true
	var ok := sim.set_thresholds(thr)
	ok = ok and sim.set_neighborhoods(nh)
	ok = ok and sim.set_weights(weights)
	sim.set_candidate_enableds(enabled)
	sim.set_seed_noise_bias(seed_bias)
	sim.set_blend_k(blend_k)
	_applying_history_state = false
	if not ok:
		return

	modify_panel.set_data(
		sim.get_current_thresholds(),
		sim.get_current_neighborhoods(),
		sim.get_current_weights(),
		sim.get_candidate_enableds(),
		sim.get_seed_noise_bias(),
		sim.get_blend_k()
	)
	_sync_selected_ruleset_index_from_current_state()
	_update_button_states()

func _can_undo() -> bool:
	return ruleset_history_index > 0

func _can_redo() -> bool:
	return ruleset_history_index >= 0 and ruleset_history_index < (ruleset_history.size() - 1)

func _apply_random_delta_to_thresholds(thr: PackedFloat32Array, rng: RandomNumberGenerator, strength: float) -> void:
	var amp := THRESHOLD_DELTA_AMPLITUDE * strength
	for i in range(thr.size()):
		var delta := rng.randf_range(-amp, amp)
		thr[i] = clampf(thr[i] + delta, 0.0, 1.0)

func _apply_random_delta_to_thresholds_candidate(
	thr: PackedFloat32Array,
	rng: RandomNumberGenerator,
	strength: float,
	candidate_index: int
) -> void:
	var base := candidate_index * THRESHOLD_VALUES_PER_CANDIDATE
	var amp := THRESHOLD_DELTA_AMPLITUDE * strength
	for i in range(base, base + THRESHOLD_VALUES_PER_CANDIDATE):
		var delta := rng.randf_range(-amp, amp)
		thr[i] = clampf(thr[i] + delta, 0.0, 1.0)

func _apply_random_delta_to_neighborhoods(nh: PackedInt32Array, rng: RandomNumberGenerator, strength: float) -> void:
	var amp := NEIGHBORHOOD_DELTA_AMPLITUDE * strength
	for pair_idx in range(8):
		var outer_i := pair_idx * 2
		var inner_i := outer_i + 1

		var outer_delta := int(round(rng.randf_range(-amp, amp)))
		var inner_delta := int(round(rng.randf_range(-amp, amp)))

		var outer := nh[outer_i] + outer_delta
		var inner := nh[inner_i] + inner_delta

		outer = clampi(outer, 0, MAX_RADIUS)
		inner = clampi(inner, 0, MAX_RADIUS)
		if outer < inner:
			outer = inner # Maintain outer >= inner.

		nh[outer_i] = outer
		nh[inner_i] = inner

func _apply_random_delta_to_neighborhoods_candidate(
	nh: PackedInt32Array,
	rng: RandomNumberGenerator,
	strength: float,
	candidate_index: int
) -> void:
	var amp := NEIGHBORHOOD_DELTA_AMPLITUDE * strength
	var pair_base := candidate_index * 2
	for local_pair in range(2):
		var pair_idx := pair_base + local_pair
		var outer_i := pair_idx * 2
		var inner_i := outer_i + 1

		var outer_delta := int(round(rng.randf_range(-amp, amp)))
		var inner_delta := int(round(rng.randf_range(-amp, amp)))

		var outer := nh[outer_i] + outer_delta
		var inner := nh[inner_i] + inner_delta

		outer = clampi(outer, 0, MAX_RADIUS)
		inner = clampi(inner, 0, MAX_RADIUS)
		if outer < inner:
			outer = inner

		nh[outer_i] = outer
		nh[inner_i] = inner

func _apply_random_delta_to_weights(weights: PackedFloat32Array, rng: RandomNumberGenerator, strength: float) -> void:
	var amp := WEIGHT_DELTA_AMPLITUDE * strength
	for i in range(weights.size()):
		weights[i] = clampf(weights[i] + rng.randf_range(-amp, amp), -1.0, 1.0)
	_enforce_all_candidate_weight_sums(weights)

func _apply_random_delta_to_weights_candidate(
	weights: PackedFloat32Array,
	rng: RandomNumberGenerator,
	strength: float,
	candidate_index: int
) -> void:
	var amp := WEIGHT_DELTA_AMPLITUDE * strength
	var base := candidate_index * WEIGHTS_PER_CANDIDATE
	for i in range(base, base + WEIGHTS_PER_CANDIDATE):
		weights[i] = clampf(weights[i] + rng.randf_range(-amp, amp), -1.0, 1.0)
	_enforce_candidate_weight_sum_range(weights, candidate_index)

func _enforce_all_candidate_weight_sums(weights: PackedFloat32Array) -> void:
	for c in range(4):
		_enforce_candidate_weight_sum_range(weights, c)

func _enforce_candidate_weight_sum_range(weights: PackedFloat32Array, candidate_index: int) -> void:
	var base := candidate_index * WEIGHTS_PER_CANDIDATE
	if base < 0 or base + WEIGHTS_PER_CANDIDATE > weights.size():
		return
	var s := 0.0
	for i in range(WEIGHTS_PER_CANDIDATE):
		s += weights[base + i]
	if s > -0.5 and s < 0.5:
		return
	var target := clampf(s, -0.49999, 0.49999)
	var remaining := s - target
	var reduce := remaining > 0.0
	remaining = absf(remaining)
	for _pass in range(8):
		if remaining <= 0.00001:
			break
		var active := PackedInt32Array()
		for i in range(WEIGHTS_PER_CANDIDATE):
			var idx: int = base + i
			var cap: float = 0.0
			if reduce:
				cap = weights[idx] + 1.0
			else:
				cap = 1.0 - weights[idx]
			if cap > 0.00001:
				active.append(idx)
		if active.is_empty():
			break
		var share: float = remaining / float(active.size())
		for idx_v in active:
			var idx: int = int(idx_v)
			var cap: float = 0.0
			if reduce:
				cap = weights[idx] + 1.0
			else:
				cap = 1.0 - weights[idx]
			var delta: float = min(share, cap)
			if reduce:
				weights[idx] -= delta
			else:
				weights[idx] += delta
			remaining -= delta

# ---------------- INPUT / BRUSH (still in main) ----------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_SPACE:
			if not _is_text_input_focused():
				sim_paused = not sim_paused
				accept_event()
			return
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_F1:
			if save_panel != null and save_panel.visible:
				accept_event()
				return
			if ui_root != null:
				ui_root.visible = not ui_root.visible
			accept_event()
			return

	if _handle_undo_redo_shortcuts(event):
		return

	if _ui_is_blocking_input():
		sim.set_brush_active(false, false)
		return

	if not (event is InputEventMouseButton or event is InputEventMouseMotion or event is InputEventPanGesture):
		return

	var pos: Vector2
	if event is InputEventPanGesture:
		pos = get_viewport().get_mouse_position()
	else:
		pos = (event as InputEventMouse).position

	if _mouse_over_undo_redo_buttons(pos):
		sim.set_brush_active(false, false)
		return

	if _mouse_over_top_ui(pos):
		sim.set_brush_active(false, false)
		return

	if _mouse_over_modify_panel(pos):
		sim.set_brush_active(false, false)
		return

	if not _mouse_over_texture_rect(pos):
		sim.set_brush_active(false, false)
		return

	if event is InputEventPanGesture:
		var pan := event as InputEventPanGesture
		sim.adjust_brush_radius(-pan.delta.y * TRACKPAD_SCROLL_SENSITIVITY)

	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			sim.set_brush_active(event.pressed, false)
			_set_brush_center(pos)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			sim.set_brush_active(event.pressed, true)
			_set_brush_center(pos)

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			sim.adjust_brush_radius(+1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			sim.adjust_brush_radius(-1.0)

	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_set_brush_center(pos)


func _set_brush_center(screen_pos: Vector2) -> void:
	var t: Vector2i = _screen_to_texel(screen_pos)
	if t.x < 0:
		return
	sim.set_brush_center(t.x, t.y)


func _screen_to_texel(screen_pos: Vector2) -> Vector2i:
	var local := tex_rect.get_global_transform_with_canvas().affine_inverse() * screen_pos
	var rect := tex_rect.get_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return Vector2i(-1, -1)

	var u: float = local.x / rect.size.x
	var v: float = local.y / rect.size.y
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return Vector2i(-1, -1)

	var x := int(floor(u * float(W)))
	var y := int(floor(v * float(H)))
	x = clamp(x, 0, W - 1)
	y = clamp(y, 0, H - 1)
	return Vector2i(x, y)


func _ui_is_blocking_input() -> bool:
	if ui_root != null and not ui_root.visible:
		return false
	if ruleset_popup.visible:
		return true
	if save_panel.visible:
		return true
	return false

func _is_text_input_focused() -> bool:
	var focus_owner := get_viewport().gui_get_focus_owner()
	return (focus_owner is LineEdit) or (focus_owner is TextEdit)


func _mouse_over_texture_rect(screen_pos: Vector2) -> bool:
	var local: Vector2 = tex_rect.get_global_transform_with_canvas().affine_inverse() * screen_pos
	return Rect2(Vector2.ZERO, tex_rect.size).has_point(local)


func _mouse_over_modify_panel(screen_pos: Vector2) -> bool:
	if ui_root != null and not ui_root.visible:
		return false
	if not modify_panel.visible:
		return false
	return modify_panel.get_global_rect().has_point(screen_pos)

func _mouse_over_top_ui(screen_pos: Vector2) -> bool:
	if ui_root != null and not ui_root.visible:
		return false
	if top_bar != null and top_bar.visible and top_bar.get_global_rect().has_point(screen_pos):
		return true
	return false

func _update_fps_label() -> void:
	if fps_label == null:
		return
	var fps := int(round(Engine.get_frames_per_second()))
	var text := "FPS: %03d" % fps
	fps_label.text = text
	fps_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var sz := fps_label.get_combined_minimum_size()
	if sz.x <= 0.0 or sz.y <= 0.0:
		sz = fps_label.size
	var left := FPS_LABEL_MARGIN_X
	var top := size.y - FPS_LABEL_MARGIN_Y - sz.y
	fps_label.offset_left = left
	fps_label.offset_top = top
	fps_label.offset_right = left + sz.x
	fps_label.offset_bottom = top + sz.y

func _mouse_over_undo_redo_buttons(screen_pos: Vector2) -> bool:
	if undo_btn != null and undo_btn.visible and undo_btn.get_global_rect().has_point(screen_pos):
		return true
	if redo_btn != null and redo_btn.visible and redo_btn.get_global_rect().has_point(screen_pos):
		return true
	return false

func _layout_save_panel_centered() -> void:
	if save_panel == null:
		return
	save_panel.set_anchors_preset(Control.PRESET_CENTER)
	var sz := save_panel.custom_minimum_size
	if sz.x <= 0.0 or sz.y <= 0.0:
		sz = save_panel.size
	sz.y = maxf(sz.y, 225.0)
	save_panel.offset_left = -sz.x * 0.5
	save_panel.offset_top = -sz.y * 0.5
	save_panel.offset_right = sz.x * 0.5
	save_panel.offset_bottom = sz.y * 0.5

func _layout_top_bars() -> void:
	if top_bar != null:
		top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
		top_bar.offset_left = 0.0
		top_bar.offset_top = 0.0
		top_bar.offset_right = 0.0

func _layout_undo_redo_container() -> void:
	if undo_redo_container == null or modify_panel == null:
		return
	undo_redo_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var panel_rect := modify_panel.get_global_rect()
	var parent_ci := undo_redo_container.get_parent() as CanvasItem
	if parent_ci == null:
		return
	var local_top_left: Vector2 = parent_ci.get_global_transform_with_canvas().affine_inverse() * panel_rect.position
	undo_redo_container.position = Vector2(UNDO_REDO_X, local_top_left.y + panel_rect.size.y + UNDO_REDO_GAP_Y)

func _handle_undo_redo_shortcuts(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key_event := event as InputEventKey
	if key_event.echo:
		return false
	if key_event.keycode != KEY_Z:
		return false

	if key_event.pressed:
		if not (key_event.meta_pressed or key_event.ctrl_pressed):
			return false
		if save_panel.visible or not modify_panel.visible:
			return false

		if key_event.shift_pressed:
			if _can_redo():
				_pending_undo_redo_action = "redo"
				_set_shortcut_button_visual(redo_btn, true)
				accept_event()
				return true
			return false

		if _can_undo():
			_pending_undo_redo_action = "undo"
			_set_shortcut_button_visual(undo_btn, true)
			accept_event()
			return true
		return false

	# Key release: execute deferred action and clear visual.
	if _pending_undo_redo_action == "undo":
		_set_shortcut_button_visual(undo_btn, false)
		_pending_undo_redo_action = ""
		if _can_undo():
			_on_undo_button_pressed()
			accept_event()
			return true
		return false
	if _pending_undo_redo_action == "redo":
		_set_shortcut_button_visual(redo_btn, false)
		_pending_undo_redo_action = ""
		if _can_redo():
			_on_redo_button_pressed()
			accept_event()
			return true
		return false
	return false

func _set_shortcut_button_visual(btn: BaseButton, pressed: bool) -> void:
	if btn == null:
		return
	btn.toggle_mode = true
	btn.set_pressed_no_signal(pressed)
	if not pressed:
		btn.toggle_mode = false
