#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct UniformBlock
{
    float4x4 projection;
    float dpi_scale;
};

struct main0_out
{
    float4 color [[user(locn0)]];
    float2 uv [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 v_pos_uv [[attribute(0)]];
    float4 v_color [[attribute(1)]];
    float2 text_pos [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant UniformBlock& _29 [[buffer(0)]])
{
    main0_out out = {};
    out.color = in.v_color;
    out.uv = in.v_pos_uv.zw;
    float2 local_pos = in.v_pos_uv.xy;
    local_pos += (in.text_pos * _29.dpi_scale);
    out.gl_Position = _29.projection * float4(local_pos, 0.0, 1.0);
    return out;
}

