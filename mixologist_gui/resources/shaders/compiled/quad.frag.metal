#pragma clang diagnostic ignored "-Wmissing-prototypes"

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
    float4 corners [[user(locn1)]];
    float4 center_scale [[user(locn2)]];
    float4 border_color [[user(locn3)]];
    float border_width [[user(locn4)]];
};

static inline __attribute__((always_inline))
float rounded_box(thread const float2& p, thread const float2& b, thread float4& r)
{
    float2 _25;
    if (p.x > 0.0)
    {
        _25 = r.xy;
    }
    else
    {
        _25 = r.zw;
    }
    r.x = _25.x;
    r.y = _25.y;
    float _42;
    if (p.y > 0.0)
    {
        _42 = r.x;
    }
    else
    {
        _42 = r.y;
    }
    r.x = _42;
    float2 q = (abs(p) - b) + float2(r.x);
    return (fast::min(fast::max(q.x, q.y), 0.0) + length(fast::max(q, float2(0.0)))) - r.x;
}

fragment main0_out main0(main0_in in [[stage_in]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    bool _83 = all(in.corners == float4(0.0));
    bool _90;
    if (_83)
    {
        _90 = in.border_width == 0.0;
    }
    else
    {
        _90 = _83;
    }
    if (_90)
    {
        out.out_color = in.color;
    }
    else
    {
        float2 param = gl_FragCoord.xy - in.center_scale.xy;
        float2 param_1 = in.center_scale.zw / float2(2.0);
        float4 param_2 = in.corners;
        float _115 = rounded_box(param, param_1, param_2);
        float d = _115;
        if (d > 1.0)
        {
            discard_fragment();
        }
        float alpha = 1.0 - smoothstep(-1.0, 1.0, d);
        float4 border_mixed = mix(in.color, in.border_color, float4(1.0 - smoothstep(0.0, 2.0, (abs(d) - in.border_width) - 1.0)));
        out.out_color = float4(border_mixed.xyz, border_mixed.w * alpha);
    }
    return out;
}

