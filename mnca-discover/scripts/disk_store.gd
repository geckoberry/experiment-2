# res://scripts/RulesetStore.gd
class_name DiskStore
extends RefCounted

var rulesets: Array = []
var file_path: String = "user://rulesets.json"
const THRESHOLD_FLOAT_COUNT := 32
const WEIGHT_COUNT := 16
const EXPANDED_THRESHOLD_FLOAT_COUNT := 64
const EXPANDED_WEIGHT_COUNT := 32
const THRESHOLD_VALUES_PER_CANDIDATE := 8
const EXPANDED_THRESHOLD_VALUES_PER_CANDIDATE := 16
const WEIGHTS_PER_CANDIDATE := 4
const EXPANDED_WEIGHTS_PER_CANDIDATE := 8

func load_from_disk() -> void:
	if not FileAccess.file_exists(file_path):
		rulesets = []
		return

	var f := FileAccess.open(file_path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()

	var data = JSON.parse_string(text)
	rulesets = data if typeof(data) == TYPE_ARRAY else []
	if _migrate_compact_rulesets():
		save_to_disk()


func save_to_disk() -> void:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		push_error("Failed to open rulesets file for writing: " + file_path)
		return
	f.store_string(JSON.stringify(rulesets, "\t"))
	f.close()


func add_ruleset(
	name: String,
	thresholds: PackedFloat32Array,
	neighborhoods: PackedInt32Array,
	weights: PackedFloat32Array,
	disabled_candidates: PackedInt32Array,
	seed_bias: float,
	blend_k: float
) -> void:
	var rs := {
		"name": name,
		"thresholds": Array(thresholds),
		"neighborhoods": Array(neighborhoods),
		"weights": Array(weights),
		"disabled_candidates": Array(disabled_candidates),
		"seed_bias": seed_bias,
		"blend_k": blend_k,
		"favorite": false
	}
	rulesets.append(rs)

func update_ruleset(
	index: int,
	thresholds: PackedFloat32Array,
	neighborhoods: PackedInt32Array,
	weights: PackedFloat32Array,
	disabled_candidates: PackedInt32Array,
	seed_bias: float,
	blend_k: float
) -> void:
	if index < 0 or index >= rulesets.size():
		return
	var rs_var: Variant = rulesets[index]
	if typeof(rs_var) != TYPE_DICTIONARY:
		return
	var rs: Dictionary = rs_var
	rs["thresholds"] = Array(thresholds)
	rs["neighborhoods"] = Array(neighborhoods)
	rs["weights"] = Array(weights)
	rs["disabled_candidates"] = Array(disabled_candidates)
	rs["seed_bias"] = seed_bias
	rs["blend_k"] = blend_k
	rulesets[index] = rs


func remove_ruleset(index: int) -> void:
	if index < 0 or index >= rulesets.size():
		return
	rulesets.remove_at(index)

func _compact_thresholds(expanded: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(THRESHOLD_FLOAT_COUNT)
	for c in range(4):
		var src_base := c * EXPANDED_THRESHOLD_VALUES_PER_CANDIDATE
		var dst_base := c * THRESHOLD_VALUES_PER_CANDIDATE
		for i in range(THRESHOLD_VALUES_PER_CANDIDATE):
			out[dst_base + i] = expanded[src_base + i]
	return out

func _compact_weights(expanded: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(WEIGHT_COUNT)
	for c in range(4):
		var src_base := c * EXPANDED_WEIGHTS_PER_CANDIDATE
		var dst_base := c * WEIGHTS_PER_CANDIDATE
		for i in range(WEIGHTS_PER_CANDIDATE):
			out[dst_base + i] = expanded[src_base + i]
	return out

func _migrate_compact_rulesets() -> bool:
	var changed := false
	for i in range(rulesets.size()):
		var rs_var: Variant = rulesets[i]
		if typeof(rs_var) != TYPE_DICTIONARY:
			continue
		var rs: Dictionary = rs_var
		var rs_changed := false

		var thr := PackedFloat32Array(rs.get("thresholds", []))
		if thr.size() == EXPANDED_THRESHOLD_FLOAT_COUNT:
			rs["thresholds"] = Array(_compact_thresholds(thr))
			rs_changed = true
		elif thr.size() > THRESHOLD_FLOAT_COUNT:
			var compact_thr := PackedFloat32Array()
			compact_thr.resize(THRESHOLD_FLOAT_COUNT)
			for t in range(THRESHOLD_FLOAT_COUNT):
				compact_thr[t] = thr[t]
			rs["thresholds"] = Array(compact_thr)
			rs_changed = true

		var weights := PackedFloat32Array(rs.get("weights", []))
		if weights.size() == EXPANDED_WEIGHT_COUNT:
			rs["weights"] = Array(_compact_weights(weights))
			rs_changed = true
		elif weights.size() > WEIGHT_COUNT:
			var compact_weights := PackedFloat32Array()
			compact_weights.resize(WEIGHT_COUNT)
			for w in range(WEIGHT_COUNT):
				compact_weights[w] = weights[w]
			rs["weights"] = Array(compact_weights)
			rs_changed = true

		if rs_changed:
			rulesets[i] = rs
			changed = true
	return changed
