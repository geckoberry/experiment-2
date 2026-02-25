# res://scripts/SimGPU.gd
class_name SimGPU
extends RefCounted

# ---- Config ----
var W: int
var H: int
var LOCAL_X: int
var LOCAL_Y: int
var MAX_RADIUS: int
var shader_path: String

# ---- GPU objects ----
var rd: RenderingDevice
var shader_rid: RID
var pipeline_rid: RID

var tex_a: RID
var tex_b: RID
var set_a_to_b: RID
var set_b_to_a: RID

var offsets_buf: RID
var ring_params_buf: RID
var thresholds_buf: RID
var neighborhoods_buf: RID
var weights_buf: RID
var candidates_buf: RID
var brush_buf: RID
var blend_buf: RID
var seed_shader_rid: RID
var seed_pipeline_rid: RID
var seed_params_buf: RID
var seed_luts_buf: RID
var seed_set_a: RID
var seed_set_b: RID
var _seed_gpu_ready := false
var _seed_params_f := PackedFloat32Array()

var current_thresholds: PackedFloat32Array
var current_neighborhoods: PackedInt32Array
var current_weights: PackedFloat32Array
var seed_noise_bias := 1.3
var blend_k := 0.5

var candidate_enabled_i := PackedInt32Array([1, 1, 1, 1])
var brush_i := PackedInt32Array([0, 0, 0, 0])           # active, erase, cx, cy
var brush_f := PackedFloat32Array([20.0, 0.6, 0.0, 0.0]) # radius, strength, _, _

# Ping-pong state
var show_a := true

# Display texture wrapper
var display_tex: Texture2DRD
var _seed_bytes := PackedByteArray()
var _lut_energy_curve := PackedFloat32Array()
var _lut_overlap_power := PackedFloat32Array()
var _lut_tonemap := PackedFloat32Array()
var _seed_luts_ready := false

const SEED_LUT_SIZE := 2048
const SEED_ENERGY_IN_MAX := 2.16
const SEED_POWER_IN_MAX := 3.0
const SEED_TONEMAP_IN_MAX := 8.0
const SEED_SHADER_PATH := "res://shaders/seed_init.glsl"
const SEED_LOCAL_X := 8
const SEED_LOCAL_Y := 8
const SEED0_SCALE := 4.0
const SEED1_SCALE := 4.0
const SEED2_SCALE := 1.0
const THRESHOLD_PAIR_COUNT := 16
const THRESHOLD_FLOAT_COUNT := THRESHOLD_PAIR_COUNT * 2
const RULE_WEIGHT_COUNT := 16
const NEIGHBORHOOD_INT_COUNT := 16


func init(p_rd: RenderingDevice, p_shader_path: String, p_w: int, p_h: int, p_local_x: int, p_local_y: int, p_max_radius: int) -> void:
	rd = p_rd
	shader_path = p_shader_path
	W = p_w
	H = p_h
	LOCAL_X = p_local_x
	LOCAL_Y = p_local_y
	MAX_RADIUS = p_max_radius

	_create_textures()
	_create_params()
	_create_thresholds_buffer()
	_create_neighborhoods_buffer()
	_create_weights_buffer()
	_create_candidates_buffer()
	_create_blend_buffer()

	var shader_file: RDShaderFile = load(shader_path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader_rid = rd.shader_create_from_spirv(spirv)
	pipeline_rid = rd.compute_pipeline_create(shader_rid)

	_create_brush_buffer()
	_create_uniform_sets()
	_init_seed_gpu()

	display_tex = Texture2DRD.new()
	display_tex.texture_rd_rid = tex_a


func free_all() -> void:
	if set_a_to_b.is_valid(): rd.free_rid(set_a_to_b)
	if set_b_to_a.is_valid(): rd.free_rid(set_b_to_a)
	if offsets_buf.is_valid(): rd.free_rid(offsets_buf)
	if ring_params_buf.is_valid(): rd.free_rid(ring_params_buf)
	if thresholds_buf.is_valid(): rd.free_rid(thresholds_buf)
	if neighborhoods_buf.is_valid(): rd.free_rid(neighborhoods_buf)
	if weights_buf.is_valid(): rd.free_rid(weights_buf)
	if candidates_buf.is_valid(): rd.free_rid(candidates_buf)
	if brush_buf.is_valid(): rd.free_rid(brush_buf)
	if blend_buf.is_valid(): rd.free_rid(blend_buf)
	if seed_set_a.is_valid(): rd.free_rid(seed_set_a)
	if seed_set_b.is_valid(): rd.free_rid(seed_set_b)
	if seed_params_buf.is_valid(): rd.free_rid(seed_params_buf)
	if seed_luts_buf.is_valid(): rd.free_rid(seed_luts_buf)
	if seed_pipeline_rid.is_valid(): rd.free_rid(seed_pipeline_rid)
	if seed_shader_rid.is_valid(): rd.free_rid(seed_shader_rid)
	if tex_a.is_valid(): rd.free_rid(tex_a)
	if tex_b.is_valid(): rd.free_rid(tex_b)

	# Pipeline / shader
	if pipeline_rid.is_valid(): rd.free_rid(pipeline_rid)
	if shader_rid.is_valid(): rd.free_rid(shader_rid)


func get_display_texture() -> Texture2DRD:
	return display_tex


func step() -> void:
	# One compute step + swap display
	if show_a:
		_dispatch(set_a_to_b)
		show_a = false
		display_tex.texture_rd_rid = tex_b
	else:
		_dispatch(set_b_to_a)
		show_a = true
		display_tex.texture_rd_rid = tex_a


# ---------------- Public sim controls ----------------

func seed_random() -> void:
	_seed_random(tex_a)
	show_a = true
	display_tex.texture_rd_rid = tex_a

func seed_empty() -> void:
	_seed_empty(tex_a)
	show_a = true
	display_tex.texture_rd_rid = tex_a

func reset_state() -> void:
	# Just re-seed random with existing params
	seed_random()

func randomize_params_and_reset() -> void:
	# Stop using old sets (they reference old buffers)
	if set_a_to_b.is_valid(): rd.free_rid(set_a_to_b)
	if set_b_to_a.is_valid(): rd.free_rid(set_b_to_a)

	# Free old parameter buffers
	if thresholds_buf.is_valid(): rd.free_rid(thresholds_buf)
	if neighborhoods_buf.is_valid(): rd.free_rid(neighborhoods_buf)
	if weights_buf.is_valid(): rd.free_rid(weights_buf)

	# Recreate random params
	_create_thresholds_buffer()
	_create_neighborhoods_buffer()
	_create_weights_buffer()

	# Recreate sets
	_create_uniform_sets()

	# Reset sim
	seed_random()

func apply_ruleset(
	thr: PackedFloat32Array,
	nh: PackedInt32Array,
	weights: PackedFloat32Array = PackedFloat32Array(),
	candidate_enableds: PackedInt32Array = PackedInt32Array([1, 1, 1, 1]),
	p_seed_noise_bias: float = 1.3,
	p_blend_k: float = 0.5
	) -> bool:
	if thr.size() != THRESHOLD_FLOAT_COUNT or nh.size() != NEIGHBORHOOD_INT_COUNT or weights.size() != RULE_WEIGHT_COUNT:
		push_error("Bad ruleset format (expected thresholds=32 floats, neighborhoods=16 ints, weights=16 floats).")
		return false

	current_thresholds = thr
	current_neighborhoods = nh
	current_weights = weights

	rd.buffer_update(thresholds_buf, 0, thr.to_byte_array().size(), thr.to_byte_array())
	rd.buffer_update(neighborhoods_buf, 0, nh.to_byte_array().size(), nh.to_byte_array())
	rd.buffer_update(weights_buf, 0, weights.to_byte_array().size(), weights.to_byte_array())
	set_candidate_enableds(candidate_enableds)
	set_seed_noise_bias(p_seed_noise_bias)
	set_blend_k(p_blend_k)

	seed_random()
	return true

func get_current_thresholds() -> PackedFloat32Array:
	return current_thresholds

func get_current_neighborhoods() -> PackedInt32Array:
	return current_neighborhoods

func get_current_weights() -> PackedFloat32Array:
	return current_weights

func set_thresholds(thr: PackedFloat32Array) -> bool:
	if thr.size() != THRESHOLD_FLOAT_COUNT:
		push_error("Bad thresholds format (expected 32 floats).")
		return false
	current_thresholds = thr
	var bytes := current_thresholds.to_byte_array()
	rd.buffer_update(thresholds_buf, 0, bytes.size(), bytes)
	return true

func set_neighborhoods(nh: PackedInt32Array) -> bool:
	if nh.size() != NEIGHBORHOOD_INT_COUNT:
		push_error("Bad neighborhoods format (expected 16 ints).")
		return false
	current_neighborhoods = nh.duplicate()
	var bytes := current_neighborhoods.to_byte_array()
	rd.buffer_update(neighborhoods_buf, 0, bytes.size(), bytes)
	return true

func set_weights(weights: PackedFloat32Array) -> bool:
	if weights.size() != RULE_WEIGHT_COUNT:
		push_error("Bad weights format (expected 16 floats).")
		return false
	current_weights = weights
	var bytes := current_weights.to_byte_array()
	rd.buffer_update(weights_buf, 0, bytes.size(), bytes)
	return true

func get_seed_noise_bias() -> float:
	return seed_noise_bias

func set_seed_noise_bias(v: float) -> void:
	seed_noise_bias = clampf(v, 0.5, 2.5)

func get_blend_k() -> float:
	return blend_k

func set_blend_k(v: float) -> void:
	blend_k = clampf(v, 0.0, 1.0)
	_update_blend_gpu()

# Brush controls
func set_brush_active(active: bool, erase: bool) -> void:
	brush_i[0] = 1 if active else 0
	brush_i[1] = 1 if erase else 0
	_update_brush_gpu()

func set_brush_center(cx: int, cy: int) -> void:
	brush_i[2] = cx
	brush_i[3] = cy
	_update_brush_gpu()

func adjust_brush_radius(delta: float, min_r := 10.0, max_r := 128.0) -> void:
	brush_f[0] = clampf(brush_f[0] + delta, min_r, max_r)
	_update_brush_gpu()


# ---------------- GPU SETUP ----------------

func _create_textures() -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = W
	fmt.height = H
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var view := RDTextureView.new()
	tex_a = rd.texture_create(fmt, view, [])
	tex_b = rd.texture_create(fmt, view, [])


func _create_uniform_sets() -> void:
	set_a_to_b = _make_set(tex_a, tex_b)
	set_b_to_a = _make_set(tex_b, tex_a)


func _make_set(src_tex: RID, dst_tex: RID) -> RID:
	var u_src := RDUniform.new()
	u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_src.binding = 0
	u_src.add_id(src_tex)

	var u_dst := RDUniform.new()
	u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_dst.binding = 1
	u_dst.add_id(dst_tex)

	var u_offsets := RDUniform.new()
	u_offsets.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_offsets.binding = 2
	u_offsets.add_id(offsets_buf)

	var u_ring_params := RDUniform.new()
	u_ring_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_ring_params.binding = 3
	u_ring_params.add_id(ring_params_buf)

	var u_thr := RDUniform.new()
	u_thr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_thr.binding = 4
	u_thr.add_id(thresholds_buf)

	var u_nh := RDUniform.new()
	u_nh.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_nh.binding = 5
	u_nh.add_id(neighborhoods_buf)

	var u_weights := RDUniform.new()
	u_weights.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_weights.binding = 9
	u_weights.add_id(weights_buf)

	var u_brush := RDUniform.new()
	u_brush.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_brush.binding = 6
	u_brush.add_id(brush_buf)

	var u_candidates := RDUniform.new()
	u_candidates.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_candidates.binding = 7
	u_candidates.add_id(candidates_buf)

	var u_blend := RDUniform.new()
	u_blend.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_blend.binding = 8
	u_blend.add_id(blend_buf)

	return rd.uniform_set_create(
		[u_src, u_dst, u_offsets, u_ring_params, u_thr, u_nh, u_brush, u_candidates, u_blend, u_weights],
		shader_rid,
		0
	)


func _dispatch(uset: RID) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uset, 0)

	var gx := int(ceil(float(W) / float(LOCAL_X)))
	var gy := int(ceil(float(H) / float(LOCAL_Y)))
	rd.compute_list_dispatch(cl, gx, gy, 1)

	rd.compute_list_end()

func _init_seed_gpu() -> void:
	_seed_gpu_ready = false
	_ensure_seed_luts()

	var shader_file: RDShaderFile = load(SEED_SHADER_PATH)
	if shader_file == null:
		push_warning("Seed shader not found: " + SEED_SHADER_PATH)
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	seed_shader_rid = rd.shader_create_from_spirv(spirv)
	if not seed_shader_rid.is_valid():
		push_warning("Failed to create seed shader RID.")
		return
	seed_pipeline_rid = rd.compute_pipeline_create(seed_shader_rid)
	if not seed_pipeline_rid.is_valid():
		push_warning("Failed to create seed compute pipeline.")
		return

	_seed_params_f.resize(36)
	var params_bytes := _seed_params_f.to_byte_array()
	seed_params_buf = rd.storage_buffer_create(params_bytes.size(), params_bytes)

	var lut_bytes := PackedByteArray()
	lut_bytes.append_array(_lut_energy_curve.to_byte_array())
	lut_bytes.append_array(_lut_overlap_power.to_byte_array())
	lut_bytes.append_array(_lut_tonemap.to_byte_array())
	seed_luts_buf = rd.storage_buffer_create(lut_bytes.size(), lut_bytes)

	seed_set_a = _make_seed_set(tex_a)
	seed_set_b = _make_seed_set(tex_b)
	_seed_gpu_ready = seed_set_a.is_valid() and seed_set_b.is_valid()

func _make_seed_set(dst_tex: RID) -> RID:
	if not seed_shader_rid.is_valid():
		return RID()
	var u_dst := RDUniform.new()
	u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_dst.binding = 0
	u_dst.add_id(dst_tex)

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 1
	u_params.add_id(seed_params_buf)

	var u_luts := RDUniform.new()
	u_luts.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_luts.binding = 2
	u_luts.add_id(seed_luts_buf)

	return rd.uniform_set_create([u_dst, u_params, u_luts], seed_shader_rid, 0)

func _dispatch_seed(uset: RID) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, seed_pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var gx := int(ceil(float(W) / float(SEED_LOCAL_X)))
	var gy := int(ceil(float(H) / float(SEED_LOCAL_Y)))
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()


func _create_params() -> void:
	var bases := PackedInt32Array()
	var counts := PackedInt32Array()
	bases.resize(MAX_RADIUS)
	counts.resize(MAX_RADIUS)

	var all := PackedInt32Array() # x,y,x,y,...
	var cursor := 0

	for r in range(1, MAX_RADIUS + 1):
		var ring := _build_exact_radius_offsets(r)
		bases[r - 1] = cursor / 2
		counts[r - 1] = ring.size() / 2
		all.append_array(ring)
		cursor += ring.size()

	offsets_buf = rd.storage_buffer_create(all.size() * 4, all.to_byte_array())

	var rp := PackedInt32Array()
	rp.resize(MAX_RADIUS * 2)
	for i in range(MAX_RADIUS):
		rp[i] = bases[i]
		rp[MAX_RADIUS + i] = counts[i]

	ring_params_buf = rd.storage_buffer_create(rp.size() * 4, rp.to_byte_array())


func _build_exact_radius_offsets(r: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for y in range(-r, r + 1):
		for x in range(-r, r + 1):
			var d := int(round(sqrt(float(x * x + y * y))))
			if d == r:
				out.append(x)
				out.append(y)
	return out


func _create_thresholds_buffer() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var dvmd := PackedFloat32Array()
	dvmd.resize(THRESHOLD_FLOAT_COUNT)
	for pair_i in range(THRESHOLD_PAIR_COUNT):
		var lo := clampf(rng.randf_range(-0.15, 0.65), 0.0, 1.0)
		var hi := clampf(rng.randf_range(-0.15, 0.65), 0.0, 1.0)
		dvmd[pair_i * 2 + 0] = lo
		dvmd[pair_i * 2 + 1] = hi

	thresholds_buf = rd.storage_buffer_create(dvmd.size() * 4, dvmd.to_byte_array())
	current_thresholds = dvmd


func _create_neighborhoods_buffer() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var outer_choices := PackedInt32Array([1, 2, 3, 4, 5, 7, 9, 12])
	var nh := PackedInt32Array()
	nh.resize(NEIGHBORHOOD_INT_COUNT)

	var used := {}
	for i in range(NEIGHBORHOOD_INT_COUNT / 2):
		var inner := 0
		var outer := 0
		var attempts := 0

		while true:
			attempts += 1
			if attempts > 200:
				inner = rng.randi_range(0, MAX_RADIUS - 2)
				outer = inner + 1
				break

			inner = rng.randi_range(0, MAX_RADIUS - 1)

			var candidates := PackedInt32Array()
			for o in outer_choices:
				if o > inner and o <= MAX_RADIUS:
					candidates.append(o)
			if candidates.size() == 0:
				continue

			outer = candidates[rng.randi_range(0, candidates.size() - 1)]
			var key := str(outer) + "," + str(inner)
			if not used.has(key):
				used[key] = true
				break

		nh[i * 2 + 0] = outer
		nh[i * 2 + 1] = inner

	neighborhoods_buf = rd.storage_buffer_create(nh.size() * 4, nh.to_byte_array())
	current_neighborhoods = nh

func _create_weights_buffer() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var weights := PackedFloat32Array()
	weights.resize(RULE_WEIGHT_COUNT)
	var per_candidate := 4
	for c in range(4):
		var base := c * per_candidate
		while true:
			var s := 0.0
			for i in range(per_candidate):
				var v := rng.randf_range(-1.0, 1.0)
				weights[base + i] = v
				s += v
			if s > -0.5 and s < 0.5:
				break
	weights_buf = rd.storage_buffer_create(weights.size() * 4, weights.to_byte_array())
	current_weights = weights

func _create_candidates_buffer() -> void:
	candidates_buf = rd.storage_buffer_create(
		candidate_enabled_i.to_byte_array().size(),
		candidate_enabled_i.to_byte_array()
	)

func _create_blend_buffer() -> void:
	var arr := PackedFloat32Array([blend_k, 0.0, 0.0, 0.0])
	blend_buf = rd.storage_buffer_create(arr.to_byte_array().size(), arr.to_byte_array())

func _update_blend_gpu() -> void:
	if blend_buf.is_valid() == false:
		return
	var arr := PackedFloat32Array([blend_k, 0.0, 0.0, 0.0])
	var bytes := arr.to_byte_array()
	rd.buffer_update(blend_buf, 0, bytes.size(), bytes)

func _update_candidates_gpu() -> void:
	rd.buffer_update(
		candidates_buf,
		0,
		candidate_enabled_i.to_byte_array().size(),
		candidate_enabled_i.to_byte_array()
	)

func get_candidate_enableds() -> PackedInt32Array:
	return candidate_enabled_i.duplicate()

func set_candidate_enabled(index: int, enabled: bool) -> void:
	if index < 0 or index >= 4:
		return
	candidate_enabled_i[index] = 1 if enabled else 0
	_update_candidates_gpu()

func _normalize_candidate_enableds(enabled: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array([1, 1, 1, 1])
	for i in range(min(enabled.size(), 4)):
		out[i] = 1 if enabled[i] != 0 else 0
	return out

func set_candidate_enableds(enabled: PackedInt32Array) -> void:
	candidate_enabled_i = _normalize_candidate_enableds(enabled)
	_update_candidates_gpu()

# ---------------- SEED ----------------

func _seed_random(tex: RID) -> void:
	if not _seed_random_gpu(tex):
		push_warning("Seed GPU path is not ready; seed_random skipped.")

func _seed_random_gpu(tex: RID) -> bool:
	if not _seed_gpu_ready:
		return false
	var seed_set := RID()
	if tex == tex_a:
		seed_set = seed_set_a
	elif tex == tex_b:
		seed_set = seed_set_b
	if not seed_set.is_valid():
		return false

	var bias_gamma := clampf(seed_noise_bias, 0.5, 2.5)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_usec() & 0x7fffffff)

	var seed0 := int(rng.randi()) & 0x00ffffff
	var oct0 := int(rng.randi_range(4, 7))
	var lac0 := rng.randf_range(1.9, 2.5)
	var gain0 := rng.randf_range(0.45, 0.65)
	var ox0 := rng.randf_range(0.0, 1000.0)
	var oy0 := rng.randf_range(0.0, 1000.0)
	var w0 := rng.randf_range(0.75, 1.25)

	var seed1 := int(rng.randi()) & 0x00ffffff
	var oct1 := int(rng.randi_range(4, 7))
	var lac1 := rng.randf_range(1.9, 2.5)
	var gain1 := rng.randf_range(0.45, 0.65)
	var ox1 := rng.randf_range(0.0, 1000.0)
	var oy1 := rng.randf_range(0.0, 1000.0)
	var w1 := rng.randf_range(0.75, 1.25)

	var seed2 := int(rng.randi()) & 0x00ffffff
	var oct2 := int(rng.randi_range(4, 7))
	var lac2 := rng.randf_range(1.9, 2.5)
	var gain2 := rng.randf_range(0.45, 0.65)
	var ox2 := rng.randf_range(0.0, 1000.0)
	var oy2 := rng.randf_range(0.0, 1000.0)
	var w2 := rng.randf_range(0.75, 1.25)

	if _seed_params_f.size() != 36:
		_seed_params_f.resize(36)
	_seed_params_f[0] = float(seed0)
	_seed_params_f[1] = float(seed1)
	_seed_params_f[2] = float(seed2)
	_seed_params_f[3] = 0.0
	_seed_params_f[4] = float(oct0)
	_seed_params_f[5] = float(oct1)
	_seed_params_f[6] = float(oct2)
	_seed_params_f[7] = 0.0
	_seed_params_f[8] = SEED0_SCALE
	_seed_params_f[9] = SEED1_SCALE
	_seed_params_f[10] = SEED2_SCALE
	_seed_params_f[11] = 0.0
	_seed_params_f[12] = lac0
	_seed_params_f[13] = lac1
	_seed_params_f[14] = lac2
	_seed_params_f[15] = 0.0
	_seed_params_f[16] = gain0
	_seed_params_f[17] = gain1
	_seed_params_f[18] = gain2
	_seed_params_f[19] = 0.0
	_seed_params_f[20] = ox0
	_seed_params_f[21] = ox1
	_seed_params_f[22] = ox2
	_seed_params_f[23] = 0.0
	_seed_params_f[24] = oy0
	_seed_params_f[25] = oy1
	_seed_params_f[26] = oy2
	_seed_params_f[27] = 0.0
	_seed_params_f[28] = w0
	_seed_params_f[29] = w1
	_seed_params_f[30] = w2
	_seed_params_f[31] = 0.0
	_seed_params_f[32] = bias_gamma
	_seed_params_f[33] = 0.0
	_seed_params_f[34] = 0.0
	_seed_params_f[35] = 0.0

	var params_bytes := _seed_params_f.to_byte_array()
	rd.buffer_update(seed_params_buf, 0, params_bytes.size(), params_bytes)
	_dispatch_seed(seed_set)
	return true

func _ensure_seed_byte_buffer() -> void:
	var byte_count := W * H
	if _seed_bytes.size() != byte_count:
		_seed_bytes.resize(byte_count)

func _ensure_seed_luts() -> void:
	if _seed_luts_ready:
		return
	_lut_energy_curve.resize(SEED_LUT_SIZE)
	_lut_overlap_power.resize(SEED_LUT_SIZE)
	_lut_tonemap.resize(SEED_LUT_SIZE)

	for i in range(SEED_LUT_SIZE):
		var t := float(i) / float(SEED_LUT_SIZE - 1)

		var e_in := t * SEED_ENERGY_IN_MAX
		_lut_energy_curve[i] = pow(e_in, 1.4)

		var p_in := t * SEED_POWER_IN_MAX
		_lut_overlap_power[i] = pow(p_in, 3.2)

		var tm_in := t * SEED_TONEMAP_IN_MAX
		_lut_tonemap[i] = 1.0 - exp(-2.8 * tm_in)

	_seed_luts_ready = true


func _seed_empty(tex: RID) -> void:
	_ensure_seed_byte_buffer()
	_seed_bytes.fill(0)
	rd.texture_update(tex, 0, _seed_bytes)


# ---------------- BRUSH ----------------

func _create_brush_buffer() -> void:
	var bytes := PackedByteArray()
	bytes.append_array(brush_i.to_byte_array())
	bytes.append_array(brush_f.to_byte_array())
	brush_buf = rd.storage_buffer_create(bytes.size(), bytes)


func _update_brush_gpu() -> void:
	var bytes := PackedByteArray()
	bytes.append_array(brush_i.to_byte_array())
	bytes.append_array(brush_f.to_byte_array())
	rd.buffer_update(brush_buf, 0, bytes.size(), bytes)
