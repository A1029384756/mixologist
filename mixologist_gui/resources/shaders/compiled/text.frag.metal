#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 out_color [[color(0)]];
};

struct main0_in
{
    float4 color [[user(locn0)]];
    float2 uv [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler atlasSmplr [[sampler(0)]])
{
    main0_out out = {};
    out.out_color = in.color * atlas.sample(atlasSmplr, in.uv);
    return out;
}

