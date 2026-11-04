#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

// 像素风后处理：1px 深色描边（基于深度差，反向 Z：越近值越大）+ 小范围暖色泛光
struct PixVIn { float4 position [[attribute(SCNVertexSemanticPosition)]]; };
struct PixVOut { float4 position [[position]]; float2 uv; };

vertex PixVOut pix_vertex(PixVIn in [[stage_in]]) {
    PixVOut o;
    o.position = float4(in.position.xy, 0.0, 1.0);
    o.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
    return o;
}

static float3 cAt(texture2d<float> t, int2 p, int2 s) {
    p = clamp(p, int2(0), s - 1);
    return t.read(uint2(p)).rgb;
}
static float dAt(depth2d<float> t, int2 p, int2 s) {
    p = clamp(p, int2(0), s - 1);
    return t.read(uint2(p));
}
static float glowKey(float3 c) { return max(0.0, c.r + 0.5 * c.g - c.b - 0.95); }

fragment half4 pix_fragment(PixVOut in [[stage_in]],
                            texture2d<float> colorTex [[texture(0)]],
                            depth2d<float> depthTex [[texture(1)]]) {
    int2 s = int2(colorTex.get_width(), colorTex.get_height());
    int2 p = int2(in.position.xy);
    float3 c = cAt(colorTex, p, s);
    float dc = dAt(depthTex, p, s);
    float thr = 0.0035;
    float e = 0.0;
    e = max(e, dc - dAt(depthTex, p + int2(1, 0), s));
    e = max(e, dc - dAt(depthTex, p + int2(-1, 0), s));
    e = max(e, dc - dAt(depthTex, p + int2(0, 1), s));
    e = max(e, dc - dAt(depthTex, p + int2(0, -1), s));
    if (dc > 0.0 && e > thr) {
        c = mix(c, float3(0.20, 0.11, 0.20), 0.82);
    }
    // 紧凑泛光（5x5）
    float3 g = float3(0.0);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            float3 n = cAt(colorTex, p + int2(x, y), s);
            float w = 1.0 / (1.0 + float(x * x + y * y));
            g += n * glowKey(n) * w;
        }
    }
    c += g * float3(1.0, 0.8, 0.5) * 0.35;
    return half4(half3(clamp(c, 0.0, 1.0)), 1.0);
}
