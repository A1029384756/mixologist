#version 450

layout (location = 0) in vec4 i_pos_uv;
layout (location = 1) in vec4 i_color;
layout (location = 2) in vec2 i_text_pos;

layout (location = 0) out vec4 o_color;
layout (location = 1) out vec2 o_uv;

layout(set = 1, binding = 0) uniform UniformBlock {
  mat4 projection;
  float dpi_scale;
};

void main() {
  o_color = i_color;
  o_uv = i_pos_uv.zw;

  vec2 local_pos = i_pos_uv.xy;
  local_pos += i_text_pos * dpi_scale;

  gl_Position = projection * vec4(local_pos, 0.0, 1.0);
}
