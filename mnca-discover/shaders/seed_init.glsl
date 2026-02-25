#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const float NOISE_ZOOM = 2.0;
const int SEED_LUT_SIZE = 2048;
const float SEED_ENERGY_IN_MAX = 2.16;
const float SEED_POWER_IN_MAX = 3.0;
const float SEED_TONEMAP_IN_MAX = 8.0;
const float OVERLAP_THRESHOLD = 0.24;
const float OVERLAP_BOOST = 20.0;

layout(set = 0, binding = 0, r8) uniform writeonly image2D dst;

layout(set = 0, binding = 1, std430) readonly buffer SeedParams {
    vec4 seed;
    vec4 octaves;
    vec4 scale;
    vec4 lacunarity;
    vec4 gain;
    vec4 offset_x;
    vec4 offset_y;
    vec4 weight;
    vec4 misc;
} P;

layout(set = 0, binding = 2, std430) readonly buffer SeedLuts {
    float energy_curve[SEED_LUT_SIZE];
    float overlap_power[SEED_LUT_SIZE];
    float tonemap[SEED_LUT_SIZE];
} L;

vec4 mod289(vec4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 permute(vec4 x) {
    return mod289(((x * 34.0) + 10.0) * x);
}

vec2 fade(vec2 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Classic Perlin 2D Noise by Stefan Gustavson (adapted for compute path)
float cnoise(vec2 pos) {
    vec4 pi = floor(pos.xyxy) + vec4(0.0, 0.0, 1.0, 1.0);
    vec4 pf = fract(pos.xyxy) - vec4(0.0, 0.0, 1.0, 1.0);
    pi = mod(pi, 289.0);
    vec4 ix = pi.xzxz;
    vec4 iy = pi.yyww;
    vec4 fx = pf.xzxz;
    vec4 fy = pf.yyww;
    vec4 i = permute(permute(ix) + iy);
    vec4 gx = 2.0 * fract(i * 0.0243902439) - 1.0;
    vec4 gy = abs(gx) - 0.5;
    vec4 tx = floor(gx + 0.5);
    gx = gx - tx;
    vec2 g00 = vec2(gx.x, gy.x);
    vec2 g10 = vec2(gx.y, gy.y);
    vec2 g01 = vec2(gx.z, gy.z);
    vec2 g11 = vec2(gx.w, gy.w);
    vec4 norm = 1.79284291400159 - 0.85373472095314 *
        vec4(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11));
    g00 *= norm.x;
    g01 *= norm.y;
    g10 *= norm.z;
    g11 *= norm.w;
    float n00 = dot(g00, vec2(fx.x, fy.x));
    float n10 = dot(g10, vec2(fx.y, fy.y));
    float n01 = dot(g01, vec2(fx.z, fy.z));
    float n11 = dot(g11, vec2(fx.w, fy.w));
    vec2 fade_xy = fade(pf.xy);
    vec2 n_x = mix(vec2(n00, n01), vec2(n10, n11), fade_xy.x);
    float n_xy = mix(n_x.x, n_x.y, fade_xy.y);
    return 2.3 * n_xy;
}

uint hash(uint key, uint seed_value) {
    uint k = key;
    k *= 0x27d4eb2fu;
    k ^= k >> 16;
    k *= 0x85ebca77u;
    uint h = seed_value;
    h ^= k;
    h ^= h >> 16;
    h *= 0x9e3779b1u;
    return h;
}

vec2 octave_seed_offset(uint s) {
    uint a = hash(0x9e3779b9u, s);
    uint b = hash(0x85ebca77u, s ^ 0x27d4eb2fu);
    return vec2(float(a & 1023u), float(b & 1023u)) * (1.0 / 37.0);
}

float perlin_noise(vec2 position, int octave_count, float persistence, float lacunarity, uint seed_value) {
    float value = 0.0;
    float amplitude = 1.0;
    float amplitude_sum = 0.0;
    int octv = clamp(octave_count, 1, 8);

    for (int i = 0; i < 8; i++) {
        if (i >= octv) {
            break;
        }
        uint s = hash(uint(i), seed_value);
        vec2 off = octave_seed_offset(s);
        value += cnoise(position + off) * amplitude;
        amplitude_sum += amplitude;
        amplitude *= persistence;
        position *= lacunarity;
    }

    return (amplitude_sum > 0.0) ? (value / amplitude_sum) : 0.0;
}

float sample_energy(float x) {
    float pos = clamp(x, 0.0, SEED_ENERGY_IN_MAX) * (float(SEED_LUT_SIZE - 1) / SEED_ENERGY_IN_MAX);
    int i0 = int(pos);
    int i1 = min(i0 + 1, SEED_LUT_SIZE - 1);
    float t = pos - float(i0);
    return mix(L.energy_curve[i0], L.energy_curve[i1], t);
}

float sample_power(float x) {
    float pos = clamp(x, 0.0, SEED_POWER_IN_MAX) * (float(SEED_LUT_SIZE - 1) / SEED_POWER_IN_MAX);
    int i0 = int(pos);
    int i1 = min(i0 + 1, SEED_LUT_SIZE - 1);
    float t = pos - float(i0);
    return mix(L.overlap_power[i0], L.overlap_power[i1], t);
}

float sample_tonemap(float x) {
    float pos = clamp(x, 0.0, SEED_TONEMAP_IN_MAX) * (float(SEED_LUT_SIZE - 1) / SEED_TONEMAP_IN_MAX);
    int i0 = int(pos);
    int i1 = min(i0 + 1, SEED_LUT_SIZE - 1);
    float t = pos - float(i0);
    return mix(L.tonemap[i0], L.tonemap[i1], t);
}

float seed_layer(int index, vec2 uv, float bias_gamma) {
    uint seed_value = uint(int(P.seed[index]));
    vec2 offset = vec2(P.offset_x[index], P.offset_y[index]);
    vec2 pos = (uv + offset) * (P.scale[index] * NOISE_ZOOM);

    float v = perlin_noise(
        pos,
        int(P.octaves[index]),
        P.gain[index],
        P.lacunarity[index],
        seed_value
    );

    float weighted = clamp(v * 0.5 + 0.5, 0.0, 1.0) * max(P.weight[index], 1e-6);
    v = clamp(weighted / max(P.weight[index], 1e-6), 0.0, 1.0);
    return pow(v, bias_gamma);
}

void main() {
    ivec2 size = imageSize(dst);
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= size.x || p.y >= size.y) {
        return;
    }

    vec2 uv = vec2(p) / float(size.y);
    float bias_gamma = clamp(P.misc.x, 0.5, 2.5);

    float v0 = seed_layer(0, uv, bias_gamma);
    float v1 = seed_layer(1, uv, bias_gamma);
    float v2 = seed_layer(2, uv, bias_gamma);

    float base = v0 * v1 * v2;
    float ov_sum = max(0.0, v0 - OVERLAP_THRESHOLD) +
                   max(0.0, v1 - OVERLAP_THRESHOLD) +
                   max(0.0, v2 - OVERLAP_THRESHOLD);

    float energy = sample_energy(ov_sum);
    float pval = sample_power(energy);

    float v = base * (1.0 + OVERLAP_BOOST * pval);
    v = sample_tonemap(v);
    v = clamp(v, 0.0, 1.0);

    // Expand middle band [0.05, 0.9] to [0, 1] and clamp extremes.
    v = clamp((v - 0.05) / 0.85, 0.0, 1.0);

    imageStore(dst, p, vec4(v, 0.0, 0.0, 1.0));
}
