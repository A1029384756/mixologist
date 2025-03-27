#version 450

layout (location = 0) in vec4 v_pos_uv;
layout (location = 1) in vec4 v_color;
layout (location = 2) in vec2 text_pos;

layout (location = 0) out vec4 color;
layout (location = 1) out vec2 uv;

layout(set = 1, binding = 0) uniform UniformBlock {
    mat4 projection;
    float dpi_scale;
};

void main() {
    color = v_color;
    uv = v_pos_uv.zw;

    vec2 local_pos = v_pos_uv.xy;
    local_pos += text_pos * dpi_scale;

    gl_Position = projection * vec4(local_pos, 0.0, 1.0);
}
