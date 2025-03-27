#version 450 core

layout(location = 0) in vec4 color;
layout(location = 1) in vec4 corners;
layout(location = 2) in vec4 center_scale;
layout(location = 3) in vec4 border_color;
layout(location = 4) in float border_width;

layout(location = 0) out vec4 out_color;

const float AA_THRESHOLD = 1.0;

float rounded_box(vec2 p, vec2 b, in vec4 r) {
    r.xy = (p.x > 0.0) ? r.xy : r.zw;
    r.x  = (p.y > 0.0) ? r.x  : r.y;
    vec2 q = abs(p) - b + r.x;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

void main() {
    if (corners == vec4(0.0) && border_width == 0.0) {
        out_color = color;
    } else {
        float d = rounded_box(gl_FragCoord.xy - center_scale.xy, center_scale.zw / 2, corners);
        if (d > AA_THRESHOLD) {
            discard;
        }
        float alpha = 1.0 - smoothstep(-AA_THRESHOLD, AA_THRESHOLD, d);
        vec4 border_mixed = mix(color, border_color, 1.0 - smoothstep(0.0, AA_THRESHOLD * 2.0, abs(d) - border_width - AA_THRESHOLD));

        out_color = vec4(border_mixed.rgb, border_mixed.a * alpha);
    }
}
