#include <metal_stdlib>
using namespace metal;

// Final color-grade pass (v0.3.0). The scene is composited first, then this
// fullscreen pass grades it — so preview and recording share one grade, after
// exposure. Uniform-driven: tuning a preset is a param change
// (GradeUniforms), not a shader rewrite.
//
// Field order MUST match GradeUniforms in MetalCompositor.swift exactly
// (float4-aligned). The Swift struct is memcpy'd in.
struct GradeUniforms {
    float4 shadowTint;    // RGB add in the shadows (split tone)
    float4 highlightTint; // RGB add in the highlights (split tone)
    float  enabled;
    float  exposure;
    float  contrast;
    float  saturation;
    float  splitStrength;
    float  vignette;
    float2 _pad;
};

struct GradeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex GradeVertexOut dcr_grade_vertex(uint vid [[vertex_id]]) {
    // Same pos->uv table as dcr_vertex, so every framebuffer position samples
    // the exact texel the composite pass wrote there (render-to-texture
    // round-trips through identical mappings).
    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 uv[4]  = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
    GradeVertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.texCoord = uv[vid];
    return out;
}

fragment float4 dcr_grade_fragment(GradeVertexOut in [[stage_in]],
                                   texture2d<float> sceneTex [[texture(0)]],
                                   constant GradeUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = sceneTex.sample(s, in.texCoord).rgb;
    if (u.enabled > 0.5) {
        // 1. exposure pull-down / lift
        c *= u.exposure;
        // 2. gentle S-curve contrast
        c = clamp((c - 0.5) * u.contrast + 0.5, 0.0, 1.0);
        // 3. saturation
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(luma), c, u.saturation);
        // 4. split tone: cool shadows, warm highlights
        float l2 = dot(c, float3(0.299, 0.587, 0.114));
        c += u.shadowTint.rgb * (1.0 - smoothstep(0.0, 0.55, l2)) * u.splitStrength;
        c += u.highlightTint.rgb * smoothstep(0.45, 1.0, l2) * u.splitStrength;
        // 5. vignette (symmetric — orientation-independent)
        float2 d = in.texCoord - float2(0.5);
        float vig = smoothstep(0.85, 0.25, length(d) * 2.0);
        c *= mix(1.0, vig, u.vignette);
        c = clamp(c, 0.0, 1.0);
    }
    return float4(c, 1.0);
}

// Vertex passthrough for a textured quad. Position is in NDC; the inset MVP and
// mirror are baked into the texCoords on the CPU side.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 local; // 0..1 within this quad, for the rounded-corner SDF
};

// Field order MUST match QuadUniforms in MetalCompositor.swift exactly
// (descending alignment: 16 -> 8 -> 4). The Swift struct is memcpy'd in.
struct QuadUniforms {
    float4x4  mvp;            // places the quad (full-frame or inset) in NDC
    float3x3  yuvMatrix;      // BT.709 limited-range YCbCr -> RGB
    float3    yuvOffset;
    float2x2  texXform;       // rotate-upright + aspect-cover (source space)
    float2    quadSizePx;
    float     mirror;         // 1.0 -> flip x (front selfie)
    float     rounded;        // 1.0 -> apply rounded-corner SDF
    float     cornerRadiusPx;
    float     _pad;
};

vertex VertexOut dcr_vertex(uint vid [[vertex_id]],
                            constant QuadUniforms& u [[buffer(0)]]) {
    // Unit quad.
    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 uv[4]  = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
    VertexOut out;
    float2 p = pos[vid];
    out.position = u.mvp * float4(p, 0.0, 1.0);
    // Center the texcoord, mirror (selfie), then rotate-upright + cover-crop via
    // texXform, then un-center — matches the Android GLSL VERTEX order so the
    // recorded file and preview are bit-identical (IOS_HANDOFF §2).
    float2 a = uv[vid] - 0.5;
    if (u.mirror > 0.5) { a.x = -a.x; }
    out.texCoord = u.texXform * a + 0.5;
    out.local = uv[vid];
    return out;
}

// Sample biplanar YUV (luma R8 + chroma RG8) and convert in-shader — lower
// bandwidth than forcing BGRA out of the camera (ARCHITECTURE.md §3).
fragment float4 dcr_fragment(VertexOut in [[stage_in]],
                             texture2d<float> lumaTex [[texture(0)]],
                             texture2d<float> chromaTex [[texture(1)]],
                             constant QuadUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = lumaTex.sample(s, in.texCoord).r;
    float2 cbcr = chromaTex.sample(s, in.texCoord).rg;
    float3 yuv = float3(y, cbcr) + u.yuvOffset;
    float3 rgb = u.yuvMatrix * yuv;
    float alpha = 1.0;

    if (u.rounded > 0.5) {
        // Rounded-rect SDF in this quad's pixel space.
        float2 px = in.local * u.quadSizePx;
        float2 halfSz = u.quadSizePx * 0.5;
        float2 q = abs(px - halfSz) - (halfSz - u.cornerRadiusPx);
        float dist = length(max(q, 0.0)) - u.cornerRadiusPx;
        alpha = 1.0 - smoothstep(-1.0, 1.0, dist);
    }
    return float4(rgb, alpha);
}
