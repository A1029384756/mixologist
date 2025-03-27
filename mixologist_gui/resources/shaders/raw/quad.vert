#version 450 core

layout(location = 0) in vec4 v_pos_scale;
layout(location = 1) in vec4 v_corners;
layout(location = 2) in vec4 v_color;
layout(location = 3) in vec4 v_border_color;
layout(location = 4) in float v_border_width;

layout(location = 0) out vec4 color;
layout(location = 1) out vec4 corners;
layout(location = 2) out vec4 center_scale;
layout(location = 3) out vec4 border_color;
layout(location = 4) out float border_width;

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
    float min_corner_radius = min(v_pos_scale.z, v_pos_scale.w) * 0.5;
    vec4 corner_radii = vec4(
        min(v_corners.x, min_corner_radius),
        min(v_corners.y, min_corner_radius),
        min(v_corners.z, min_corner_radius),
        min(v_corners.w, min_corner_radius)
    );

    // Extract position and scale from position_scale
    vec2 position = v_pos_scale.xy * dpi_scale;
    vec2 scale = v_pos_scale.zw * dpi_scale;

    vec2 local_pos = positions[gl_VertexIndex];
    local_pos *= scale;
    local_pos += position;

    // Pass values to fragment shader
    color = v_color;
    corners = corner_radii * dpi_scale;
    center_scale = vec4(position + scale * 0.5, scale);
    border_color = v_border_color;
    border_width = v_border_width * dpi_scale;

    gl_Position = projection * vec4(local_pos, 0.0, 1.0);
}
