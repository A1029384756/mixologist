#version 450

layout (location = 0) in vec4 i_color;
layout (location = 1) in vec2 i_uv;

layout (location = 0) out vec4 o_color;

layout (set = 2, binding = 0) uniform sampler2D atlas;

void main() {
  o_color = i_color * texture(atlas, i_uv);
}
