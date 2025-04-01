#version 450 core

layout (location = 0) in vec4 i_pos_scale;
layout (location = 1) in vec4 i_corners;
layout (location = 2) in vec4 i_color;
layout (location = 3) in vec4 i_border_color;
layout (location = 4) in float i_border_width;

layout (location = 0) out vec4 o_color;
layout (location = 1) out vec4 o_corners;
layout (location = 2) out vec4 o_center_scale;
layout (location = 3) out vec4 o_border_color;
layout (location = 4) out float o_border_width;

layout(set = 1, binding = 0) uniform UniformBlock {
  mat4 projection;
  float dpi_scale;
};

const vec2 positions[6] = vec2[](
  vec2(1.0, 1.0),  // top left
  vec2(1.0, 0.0),  // top right
  vec2(0.0, 0.0),  // bottom right
  vec2(0.0, 0.0),  // bottom right
  vec2(0.0, 1.0),  // bottom left
  vec2(1.0, 1.0)   // top left
);

void main() {
  float min_corner_radius = min(i_pos_scale.z, i_pos_scale.w) * 0.5;
  vec4 corner_radii = vec4(
    min(i_corners.x, min_corner_radius),
    min(i_corners.y, min_corner_radius),
    min(i_corners.z, min_corner_radius),
    min(i_corners.w, min_corner_radius)
  );

  vec2 position = i_pos_scale.xy * dpi_scale;
  vec2 scale = i_pos_scale.zw * dpi_scale;

  vec2 local_pos = positions[gl_VertexIndex];
  local_pos *= scale;
  local_pos += position;

  o_color = i_color;
  o_corners = corner_radii * dpi_scale;
  o_center_scale = vec4(position + scale * 0.5, scale);
  o_border_color = i_border_color;
  o_border_width = i_border_width * dpi_scale;

  gl_Position = projection * vec4(local_pos, 0.0, 1.0);
}
