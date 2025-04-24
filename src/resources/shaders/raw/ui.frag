#version 450

layout (location = 0) in vec4 i_color;
layout (location = 1) in vec2 i_uv;
layout (location = 2) in vec4 i_corners;
layout (location = 3) in vec4 i_center_scale;
layout (location = 4) in vec4 i_border_color;
layout (location = 5) in float i_border_width;
layout (location = 6) in float i_type;

layout (location = 0) out vec4 o_color;

layout (set = 2, binding = 0) uniform sampler2D atlas;

const float AA_THRESHOLD = 1.0;

float rounded_box(vec2 p, vec2 b, in vec4 r) {
  r.xy = (p.x > 0.0) ? r.xy : r.zw;
  r.x  = (p.y > 0.0) ? r.x  : r.y;
  vec2 q = abs(p) - b + r.x;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

void main() {
  if (i_type == 0.0) { // quad
    if (i_corners == vec4(0.0) && i_border_width == 0.0) {
      o_color = i_color;
    } else {
      float d = rounded_box(gl_FragCoord.xy - i_center_scale.xy, i_center_scale.zw / 2, i_corners);
      if (d > AA_THRESHOLD) { discard; }

      float alpha = 1.0 - smoothstep(-AA_THRESHOLD, AA_THRESHOLD, d);
      vec4 border_mixed = mix(i_color, i_border_color, 1.0 - smoothstep(0.0, AA_THRESHOLD * 2.0, abs(d) - i_border_width - AA_THRESHOLD));

      o_color = vec4(border_mixed.rgb, border_mixed.a * alpha);
    }
  } else if (i_type == 1.0) { // text
    vec4 texture_color = texture(atlas, i_uv);
    o_color = vec4(i_color.rgb, i_color.a * texture_color.a);
  } else { // texture
    vec4 texture_color = texture(atlas, i_uv);
    o_color = i_color * texture_color.a;
  }
}
