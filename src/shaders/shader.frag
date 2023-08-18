#version 460

layout(location = 0) in vec4 in_color_;

layout(location = 0) out vec4 out_color_;

void main() {
    out_color_ = in_color_;
}
