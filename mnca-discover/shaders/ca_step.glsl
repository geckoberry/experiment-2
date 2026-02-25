#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int MAX_RADIUS = 12;
const int LOCAL_SIZE_X = 8;
const int LOCAL_SIZE_Y = 8;
const int TILE_W = LOCAL_SIZE_X + MAX_RADIUS * 2;
const int TILE_H = LOCAL_SIZE_Y + MAX_RADIUS * 2;
const int TILE_PIXELS = TILE_W * TILE_H;
const int WG_THREADS = LOCAL_SIZE_X * LOCAL_SIZE_Y;

layout(set = 0, binding = 0, r8) uniform readonly image2D src;
layout(set = 0, binding = 1, r8) uniform writeonly image2D dst;

// Offsets for all rings concatenated
layout(set = 0, binding = 2, std430) readonly buffer Offsets {
    ivec2 off[];
} offsets;

// Per-ring ranges into offsets.off[]
layout(set = 0, binding = 3, std430) readonly buffer RingParams {
    int base[12];
    int count[12];
} ring_params;

// Random thresholds (dvmd[32]) provided by CPU
layout(set = 0, binding = 4, std430) readonly buffer Thresholds {
    float dvmd[32];
} T;

layout(set = 0, binding = 5, std430) readonly buffer Neighborhoods {
    ivec2 nh[8];
} N;

layout(set = 0, binding = 6, std430) readonly buffer Brush {
    ivec4 brush_i;
    vec4  brush_f;
} B;

layout(set = 0, binding = 7, std430) readonly buffer CandidateMask {
    ivec4 enabled;
} C;

layout(set = 0, binding = 8, std430) readonly buffer BlendParams {
    vec4 blend;
} BK;

layout(set = 0, binding = 9, std430) readonly buffer RuleWeights {
    float w[16];
} WG;

// ---------- helpers ----------
ivec2 wrap_pos(ivec2 p, ivec2 size) {
    p.x = (p.x % size.x + size.x) % size.x;
    p.y = (p.y % size.y + size.y) % size.y;
    return p;
}

float sample_r(ivec2 p) { return imageLoad(src, p).r; }

// ring accumulation (sum over exact-radius offsets)
struct RingData { float value; float total; };

shared float s_tile[TILE_H][TILE_W];

RingData ring_accum(ivec2 origin_local, int ring_index) {
    int base  = ring_params.base[ring_index];
    int count = ring_params.count[ring_index];

    float sum = 0.0;
    for (int i = 0; i < count; i++) {
        ivec2 q = origin_local + offsets.off[base + i];
        sum += s_tile[q.y][q.x];
    }
    return RingData(sum, float(max(count, 1)));
}

void main() {
    ivec2 size = imageSize(src);

    ivec2 wg_origin = ivec2(gl_WorkGroupID.xy) * ivec2(LOCAL_SIZE_X, LOCAL_SIZE_Y);
    ivec2 tile_origin = wg_origin - ivec2(MAX_RADIUS);
    ivec2 lid2 = ivec2(gl_LocalInvocationID.xy);
    int lid = lid2.y * LOCAL_SIZE_X + lid2.x;

    for (int idx = lid; idx < TILE_PIXELS; idx += WG_THREADS) {
        int tx = idx % TILE_W;
        int ty = idx / TILE_W;
        ivec2 g = wrap_pos(tile_origin + ivec2(tx, ty), size);
        s_tile[ty][tx] = sample_r(g);
    }
    barrier();

    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= size.x || p.y >= size.y) return;
    ivec2 p_local = lid2 + ivec2(MAX_RADIUS);
    float res_r = s_tile[p_local.y][p_local.x];

    if (B.brush_i.x != 0) { // active
        ivec2 c = ivec2(B.brush_i.z, B.brush_i.w);
        float radius   = B.brush_f.x;
        float strength = B.brush_f.y; // 0..1-ish

        // Safety
        radius   = max(radius, 0.0001);
        strength = clamp(strength, 0.0, 1.0);

        // Distance in pixel units
        vec2 dp = vec2(p - c);
        float d = length(dp);

        if (d <= radius) {
            float falloff = 1.0 - (d / radius);      // linear soft edge
            falloff = clamp(falloff, 0.0, 1.0);

            float a = strength * falloff;
            float target = (B.brush_i.y != 0) ? 0.0 : 1.0; // erase ? black : white

            // Mix current value toward target
            res_r = mix(res_r, target, a);
        }
    }

    // Build 12 rings (r = 1..12)
    RingData rings[MAX_RADIUS];
    for (int i = 0; i < MAX_RADIUS; i++) {
        rings[i] = ring_accum(p_local, i);
    }

    // Prefix sums indexed by radius in [0..MAX_RADIUS], so annulus (inner, outer]
    // can be evaluated in O(1): prefix[outer] - prefix[inner].
    float ring_prefix_sum[MAX_RADIUS + 1];
    float ring_prefix_tot[MAX_RADIUS + 1];
    ring_prefix_sum[0] = 0.0;
    ring_prefix_tot[0] = 0.0;
    for (int ri = 1; ri <= MAX_RADIUS; ri++) {
        int idx = ri - 1;
        ring_prefix_sum[ri] = ring_prefix_sum[ri - 1] + rings[idx].value;
        ring_prefix_tot[ri] = ring_prefix_tot[ri - 1] + rings[idx].total;
    }

    // 8 neighborhoods on RED
    float nhdt[8];
    for (int i = 0; i < 8; i++) {
        int outer_r = N.nh[i].x;
        int inner_r = N.nh[i].y;
        outer_r = clamp(outer_r, 1, MAX_RADIUS);
        inner_r = clamp(inner_r, 0, outer_r - 1);

        float sum = ring_prefix_sum[outer_r] - ring_prefix_sum[inner_r];
        float tot = ring_prefix_tot[outer_r] - ring_prefix_tot[inner_r];
        nhdt[i] = (tot > 0.0) ? (sum / tot) : 0.0;
    }

    // 4 candidates
    float rslt[4];
    rslt[0] = res_r;
    rslt[1] = res_r;
    rslt[2] = res_r;
    rslt[3] = res_r;

    float wv[16];
    for (int wi = 0; wi < 16; wi++) {
        wv[wi] = clamp(WG.w[wi], -1.0, 1.0);
    }

    // 4 candidates, 2 neighborhoods per candidate, 2 rules per neighborhood.
    for (int c = 0; c < 4; c++) {
        int nh_base = c * 2;
        int rule_base = c * 4;
        int thr_base = c * 8;

        for (int n = 0; n < 2; n++) {
            float nv = nhdt[nh_base + n];
            int local_base = n * 2;
            for (int r = 0; r < 2; r++) {
                int rule_i = rule_base + local_base + r;
                int thr_i = thr_base + (local_base + r) * 2;
                if (nv >= T.dvmd[thr_i] && nv <= T.dvmd[thr_i + 1]) {
                    rslt[c] += wv[rule_i] * 0.075;
                }
            }
        }
    }

    float blend_k = clamp(BK.blend.x, 0.0, 1.0);

    float sb[4];
    for (int c = 0; c < 4; c++) {
        float s = 0.0;
        int wb = c * 4;
        for (int wi = 0; wi < 4; wi++) {
            s += abs(wv[wb + wi]);
        }
        sb[c] = s * 0.01875;
    }

    for (int c = 0; c < 4; c++) {
        int nh_base = c * 2;
        rslt[c] = (rslt[c] + nhdt[nh_base] * sb[c] * blend_k + nhdt[nh_base + 1] * sb[c] * blend_k) / (1.0 + sb[c] * (2.0 * blend_k));
    }

    // Variance selection
    int von = -1;
    float best = -1.0;
    for (int i = 0; i < 4; i++) {
        if (C.enabled[i] == 0) {
            continue;
        }
        float v = abs(res_r - rslt[i]);
        if (v > best) {
            best = v;
            von = i;
        }
    }
    if (von >= 0) {
        res_r = rslt[von];
    }

    // Grayscale output
    vec4 outc = vec4(res_r, 0.0, 0.0, 1.0);
    imageStore(dst, p, outc);
}
