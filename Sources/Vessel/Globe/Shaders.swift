/// Compiled at launch so the app builds with Swift Package Manager alone.
let metalShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float3 eye;
    float pointSize;
    float3 sun;
    float dt;
    float cosG; float sinG;      // GMST rotation, TEME -> Earth-fixed
    float2 viewport;
    float time;
    int filterClass;             // -1 shows everything
    int lockedIndex;             // -1 for none
    int regionMarker;            // 1 draws the marker in the host-region colour
};

// ---- Stars ----
struct StarOut { float4 pos [[position]]; float size [[point_size]]; float b; };
vertex StarOut star_v(uint vid [[vertex_id]], constant float4 *stars [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    StarOut o;
    o.pos = u.viewProj * float4(stars[vid].xyz * 400.0 + u.eye, 1.0);
    o.pos.z = o.pos.w * 0.99999;
    o.b = stars[vid].w;
    o.size = 1.0 + stars[vid].w * 1.6;
    return o;
}
fragment float4 star_f(StarOut i [[stage_in]], float2 pc [[point_coord]]) {
    float a = smoothstep(0.5, 0.15, length(pc - 0.5)) * i.b;
    return float4(float3(0.85, 0.9, 1.0) * a, 1.0);
}

// ---- Earth ----
struct Vtx { float3 pos; float2 uv; };
struct EarthOut { float4 pos [[position]]; float3 world; float2 uv; };

vertex EarthOut earth_v(uint vid [[vertex_id]], constant Vtx *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    EarthOut o;
    o.world = v[vid].pos;
    o.uv = v[vid].uv;
    o.pos = u.viewProj * float4(o.world, 1.0);
    return o;
}

static float3 shade(float3 world, float3 albedo, float3 nightTex, float isWater, constant Uniforms &u) {
    float3 n = normalize(world);
    float3 v = normalize(u.eye - world);
    float3 l = u.sun;
    float ndl = dot(n, l);

    // The night image carries a faint blue land tint; keep only the actual city lights.
    float3 lights = pow(nightTex, 2.2) * smoothstep(0.16, 0.42, max(nightTex.r, max(nightTex.g, nightTex.b)));

    float daylight = smoothstep(-0.12, 0.22, ndl);
    float wrap = saturate(ndl * 0.92 + 0.08);
    float3 c = albedo * wrap * 1.55 + albedo * float3(0.035, 0.045, 0.07);

    // Ocean glint.
    float3 h = normalize(l + v);
    float spec = pow(saturate(dot(n, h)), 420.0) * isWater * saturate(ndl * 4.0);
    c += float3(1.0, 0.93, 0.8) * spec * 0.4;

    // City lights fade in past the terminator.
    c += lights * float3(1.0, 0.82, 0.55) * (1.0 - daylight) * 1.5;

    // Limb scattering inside the disc, warmer along the terminator.
    float rim = pow(1.0 - saturate(dot(n, v)), 3.2);
    float3 sky = mix(float3(0.95, 0.5, 0.25), float3(0.32, 0.6, 1.0), smoothstep(-0.05, 0.35, ndl));
    c = mix(c, sky, rim * saturate(ndl * 1.8 + 0.22) * 0.75);

    // Filmic shoulder, so polar ice does not clip to flat white.
    c = 1.0 - exp(-c * 1.5);
    return pow(c, 1.0 / 2.2);
}

fragment float4 earth_f(EarthOut i [[stage_in]], constant Uniforms &u [[buffer(1)]],
                        texture2d<float> day [[texture(0)]], texture2d<float> night [[texture(1)]],
                        texture2d<float> water [[texture(2)]], sampler s [[sampler(0)]]) {
    float3 albedo = pow(day.sample(s, i.uv).rgb, 2.2);
    return float4(shade(i.world, albedo, night.sample(s, i.uv).rgb, water.sample(s, i.uv).r, u), 1.0);
}

// ---- Streamed imagery: a Web Mercator tile bent onto the sphere, lit like the rest of the globe ----
struct TileParams {
    float lon0, dLon, merc0, dMerc;
    float u0, v0, uvScale, fade;
};
struct TileOut { float4 pos [[position]]; float3 world; float2 tileUV; float2 globalUV; };

vertex TileOut tile_v(uint vid [[vertex_id]], constant float2 *grid [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                      constant TileParams &t [[buffer(2)]]) {
    float2 g = grid[vid];
    float lon = t.lon0 + g.x * t.dLon;
    float lat = 2.0 * atan(exp(t.merc0 - g.y * t.dMerc)) - M_PI_2_F;
    TileOut o;
    o.world = float3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
    o.pos = u.viewProj * float4(o.world, 1.0);
    o.tileUV = float2(t.u0, t.v0) + g * t.uvScale;
    o.globalUV = float2(lon / (2.0 * M_PI_F) + 0.5, 0.5 - lat / M_PI_F);
    return o;
}

fragment float4 tile_f(TileOut i [[stage_in]], constant Uniforms &u [[buffer(1)]], constant TileParams &t [[buffer(2)]],
                       texture2d<float> day [[texture(0)]], texture2d<float> night [[texture(1)]],
                       texture2d<float> water [[texture(2)]], texture2d<float> tile [[texture(3)]],
                       sampler s [[sampler(0)]], sampler ts [[sampler(1)]]) {
    float3 base = pow(day.sample(s, i.globalUV).rgb, 2.2);
    // Sentinel-2 mosaics run darker than the base map, so a little lift keeps the two matched.
    float3 sharp = pow(tile.sample(ts, i.tileUV).rgb, 2.2) * 1.25;
    float3 albedo = mix(base, sharp, t.fade);
    // The water mask is too coarse to hold up close, so the glint fades out along with the base map.
    float glint = water.sample(s, i.globalUV).r * (1.0 - t.fade * 0.9);
    return float4(shade(i.world, albedo, night.sample(s, i.globalUV).rgb, glint, u), 1.0);
}

// ---- Atmosphere shell (drawn front-culled, slightly larger than the Earth) ----
fragment float4 atmo_f(EarthOut i [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(i.world);
    float3 v = normalize(u.eye - i.world);
    float facing = saturate(-dot(n, v));
    float ndl = dot(n, u.sun);
    float a = pow(saturate(facing / 0.30), 2.6) * saturate(ndl * 1.5 + 0.35);
    float3 c = mix(float3(0.95, 0.5, 0.3), float3(0.3, 0.58, 1.0), smoothstep(-0.1, 0.4, ndl));
    return float4(c * a * 1.35, a);
}

// ---- Border lines (Earth-fixed) and orbit tracks (TEME) ----
struct LineOut { float4 pos [[position]]; float4 color; };
vertex LineOut line_ecef_v(uint vid [[vertex_id]], constant packed_float3 *v [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]], constant float4 &color [[buffer(2)]]) {
    LineOut o;
    o.pos = u.viewProj * float4(float3(v[vid]), 1.0);
    o.color = color;
    return o;
}
vertex LineOut line_teme_v(uint vid [[vertex_id]], constant packed_float3 *v [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]], constant float4 &color [[buffer(2)]]) {
    float3 p = float3(v[vid]);
    float3 q = float3(u.cosG * p.x + u.sinG * p.y, -u.sinG * p.x + u.cosG * p.y, p.z);
    LineOut o;
    o.pos = u.viewProj * float4(q, 1.0);
    o.color = color;
    return o;
}
fragment float4 line_f(LineOut i [[stage_in]]) { return i.color; }

// ---- Satellite particles ----
struct Particle { packed_float3 pos; packed_float3 vel; packed_float4 color; };
struct ParticleOut { float4 pos [[position]]; float size [[point_size]]; float4 color; };

static float3 tick(constant Particle &p, constant Uniforms &u) {
    float3 q = float3(p.pos) + float3(p.vel) * u.dt;
    return float3(u.cosG * q.x + u.sinG * q.y, -u.sinG * q.x + u.cosG * q.y, q.z);
}

vertex ParticleOut particle_v(uint vid [[vertex_id]], constant Particle *ps [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    ParticleOut o;
    // The alpha slot carries the orbit class, or -1 for an object that failed to propagate.
    float4 c = float4(ps[vid].color);
    bool hidden = c.a < 0.0 || (u.filterClass >= 0 && int(c.a) != u.filterClass) || int(vid) == u.lockedIndex;
    o.pos = hidden ? float4(2.0, 2.0, 2.0, 1.0) : u.viewProj * float4(tick(ps[vid], u), 1.0);
    o.size = u.pointSize;
    o.color = float4(c.rgb, 1.0);
    return o;
}
fragment float4 particle_f(ParticleOut i [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    if (d >= 1.0) discard_fragment();   // A large dot's corners mustn't hide what's behind them.
    float core = smoothstep(1.0, 0.45, d);
    float3 c = mix(i.color.rgb, float3(1.0), smoothstep(0.55, 0.0, d) * 0.45);
    return float4(c * core * i.color.a, core * i.color.a);
}

// ---- Selected address: a red dot with a ring pulsing outwards ----
struct MarkerOut { float4 pos [[position]]; float size [[point_size]]; };
vertex MarkerOut marker_v(constant packed_float3 &p [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    MarkerOut o;
    // A sprite has one depth, so against the curved Earth the depth test would cut it in half.
    // It's tested against the horizon instead, as a whole.
    float3 q = float3(p);
    o.pos = dot(q, u.eye) > 1.0 ? u.viewProj * float4(q, 1.0) : float4(2.0, 2.0, 2.0, 1.0);
    o.size = u.pointSize;
    return o;
}
fragment float4 marker_f(MarkerOut i [[stage_in]], float2 pc [[point_coord]], constant Uniforms &u [[buffer(1)]]) {
    float d = length(pc - 0.5) * 2.0;
    float3 red = u.regionMarker == 1 ? float3(0.2, 0.75, 1.0) : float3(1.0, 0.16, 0.14);
    float phase = fract(u.time / 1.6);
    float ring = smoothstep(0.07, 0.0, abs(d - (0.12 + phase * 0.85))) * (1.0 - phase) * 0.9;
    float halo = smoothstep(0.34, 0.1, d) * (0.3 + 0.2 * sin(u.time * 3.9));
    float core = smoothstep(0.16, 0.12, d);
    float3 rgb = mix(red, float3(1.0), smoothstep(0.1, 0.0, d) * 0.5);
    float a = saturate(max(core, max(ring, halo)));
    return float4(rgb * a, a);
}

// ---- Locked satellite: the SVG icon as a screen-space billboard in the particle's colour ----
struct IconOut { float4 pos [[position]]; float2 uv; };
struct IconUniforms { packed_float3 pos; float sizePx; float4 color; };

vertex IconOut icon_v(uint vid [[vertex_id]], constant IconUniforms &ic [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    float4 c = u.viewProj * float4(float3(ic.pos), 1.0);
    float2 off = (corner - 0.5) * 2.0 * ic.sizePx / u.viewport;
    IconOut o;
    o.pos = float4(c.xy + off * c.w, c.z, c.w);
    o.uv = float2(corner.x, 1.0 - corner.y);
    return o;
}
fragment float4 icon_f(IconOut i [[stage_in]], constant IconUniforms &ic [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float a = tex.sample(s, i.uv).a;
    float lum = tex.sample(s, i.uv).r;
    float3 c = ic.color.rgb * (0.35 + 0.65 * lum);
    return float4(c * a, a);
}
"""#
