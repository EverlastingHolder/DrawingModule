#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

struct InstanceData {
    float2 position;
    float scale;
    float rotation;
    float opacity;
    float4 color;
};

// MARK: - Multi-pass Brush Shaders

// Pass 1: Splatting (Mask/Stamp Generation)
// Renders to a memoryless R16Float texture
fragment float fragment_brush_mask(VertexOut in [[stage_in]],
                                  texture2d<float> brushTexture [[texture(0)]],
                                  sampler textureSampler [[sampler(0)]]) {
    float alpha = brushTexture.sample(textureSampler, in.texCoord).r;
    return alpha * in.color.a;
}

// Pass 2: Effect Application (Smudge/Blur)
// Simplified Smudge logic for 120 FPS
struct SmudgeParams {
    float2 center;
    float radius;
    float strength;
    float hardness;
};

kernel void compute_smudge_hdr(texture2d<float, access::read_write> canvas [[texture(0)]],
                              texture2d<float, access::read> smudgeSource [[texture(1)]],
                              constant SmudgeParams &params [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= canvas.get_width() || gid.y >= canvas.get_height()) return;
    
    float2 pos = float2(gid);
    float dist = distance(pos, params.center);
    
    if (dist > params.radius) return;
    
    // Optimization: use half precision for intermediate calculations to reduce register pressure
    half falloff = half(smoothstep(params.radius, params.radius * (1.0 - params.hardness), dist));
    half4 currentColor = half4(canvas.read(gid));
    
    // Sampling from the 'dragged' position
    float2 samplePos = pos - (params.center - pos) * 0.1; 
    half4 sampledColor = half4(smudgeSource.sample(sampler(filter::linear), samplePos / float2(canvas.get_width(), canvas.get_height())));
    
    half3 diff = sampledColor.rgb - currentColor.rgb;
    
    // Safety: limit delta for HDR
    diff = clamp(diff, half3(-4.0), half3(4.0));
    
    half3 resultRgb = currentColor.rgb + diff * half(params.strength) * falloff;
    
    canvas.write(float4(float3(resultRgb), float(currentColor.a)), gid);
}

// MARK: - Export & Tonemapping

// ACES Filmic Tone Mapping Curve
// Source: https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// Interleaved Gradient Noise for Dithering
float interleavedGradientNoise(float2 uv) {
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(uv, magic.xy)));
}

kernel void tonemap_hdr_to_sdr(
    texture2d<float, access::read> hdrTexture [[texture(0)]],
    texture2d<float, access::write> sdrTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]) 
{
    if (gid.x >= hdrTexture.get_width() || gid.y >= hdrTexture.get_height()) return;
    
    float4 hdrColor = hdrTexture.read(gid);
    
    // 1. ACES Tonemapping
    float3 sdrColor = ACESFilm(hdrColor.rgb);
    
    // 2. Gamma Correction (approx 2.2)
    sdrColor = pow(sdrColor, 0.4545f);
    
    // 3. Dithering (8-bit) to prevent banding
    float noise = interleavedGradientNoise(float2(gid));
    sdrColor += (noise - 0.5f) / 255.0f;
    
    sdrTexture.write(float4(sdrColor, hdrColor.a), gid);
}

// MARK: - Utilities

kernel void generate_thumbnail(
    texture2d<float, access::read> sourceMip [[texture(0)]],
    texture2d<float, access::write> thumbnail [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]) 
{
    if (gid.x >= thumbnail.get_width() || gid.y >= thumbnail.get_height()) return;
    
    // We sample from a high-level mip to get free hardware downscaling
    float2 uv = (float2(gid) + 0.5f) / float2(thumbnail.get_width(), thumbnail.get_height());
    float4 color = sourceMip.sample(sampler(filter::linear), uv);
    
    thumbnail.write(color, gid);
}
