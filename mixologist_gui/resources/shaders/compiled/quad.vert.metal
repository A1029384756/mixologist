#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct UniformBlock
{
    float4x4 projection;
    float dpi_scale;
};

constant spvUnsafeArray<float2, 6> _75 = spvUnsafeArray<float2, 6>({ float2(1.0), float2(1.0, 0.0), float2(0.0), float2(0.0), float2(0.0, 1.0), float2(1.0) });

struct main0_out
{
    float4 color [[user(locn0)]];
    float4 corners [[user(locn1)]];
    float4 center_scale [[user(locn2)]];
    float4 border_color [[user(locn3)]];
    float border_width [[user(locn4)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 v_pos_scale [[attribute(0)]];
    float4 v_corners [[attribute(1)]];
    float4 v_color [[attribute(2)]];
    float4 v_border_color [[attribute(3)]];
    float v_border_width [[attribute(4)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant UniformBlock& _53 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])
{
    main0_out out = {};
    float min_corner_radius = fast::min(in.v_pos_scale.z, in.v_pos_scale.w) * 0.5;
    float4 corner_radii = float4(fast::min(in.v_corners.x, min_corner_radius), fast::min(in.v_corners.y, min_corner_radius), fast::min(in.v_corners.z, min_corner_radius), fast::min(in.v_corners.w, min_corner_radius));
    float2 position = in.v_pos_scale.xy * _53.dpi_scale;
    float2 scale = in.v_pos_scale.zw * _53.dpi_scale;
    float2 local_pos = _75[int(gl_VertexIndex)];
    local_pos *= scale;
    local_pos += position;
    out.color = in.v_color;
    out.corners = corner_radii * _53.dpi_scale;
    out.center_scale = float4(position + (scale * 0.5), scale);
    out.border_color = in.v_border_color;
    out.border_width = in.v_border_width * _53.dpi_scale;
    out.gl_Position = _53.projection * float4(local_pos, 0.0, 1.0);
    return out;
}

