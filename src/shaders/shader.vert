//! This treats each Bezier curve as a single instance, with (6*n_line_segments_per_curve_) vertices.

#version 460

layout(location = 0) in vec2 control_point_1_pos_;
layout(location = 1) in vec2 control_point_2_pos_;
layout(location = 2) in vec2 control_point_3_pos_;
layout(location = 3) in vec2 control_point_4_pos_;

layout(location = 4) in vec4 control_point_1_color_;
layout(location = 5) in vec4 control_point_4_color_;

layout(location = 0) out vec4 fragment_color_;

// Values for these specialization constants must be specified during pipeline creation.
layout(constant_id = 0) const float camera_center_x = 0;
layout(constant_id = 1) const float camera_center_y = 0;
layout(constant_id = 2) const float camera_halfsize_x = 1;
layout(constant_id = 3) const float camera_halfsize_y = 1;
layout(constant_id = 4) const uint n_line_segments_per_curve_ = 0;
layout(constant_id = 5) const float line_thickness_ = 1.0f;

//
// ===========================================================================================================
//

/// Let B: [0, 1] -> R^2 be the cubic Bezier curve defined by this instance's control points.
/// This computes B(t).
vec2 computeCubicBezierAt(float t) {
    const float t0 = 1.0f;
    const float t1 = t;
    const float t2 = t*t;
    const float t3 = t2*t;

    const float one_minus_t_0 = 1.0f;
    const float one_minus_t_1 = 1.0f - t;
    const float one_minus_t_2 = one_minus_t_1 * one_minus_t_1;
    const float one_minus_t_3 = one_minus_t_2 * one_minus_t_1;

    return
        control_point_1_pos_ * t0 * one_minus_t_3 * 1.0f +
        control_point_2_pos_ * t1 * one_minus_t_2 * 3.0f +
        control_point_3_pos_ * t2 * one_minus_t_1 * 3.0f +
        control_point_4_pos_ * t3 * one_minus_t_0 * 1.0f;
}

vec2 rotate90(vec2 v) {
    return vec2(-v.y, v.x);
}

// x in [-1, 1]; varies along the width of the line segment rectangle (x=0 is on the centerline).
// y in [0, 1]; varies along the length of the line segment rectangle (y=0 maps to start, y=1 maps to end).
const vec2 BASE_RECTANGLE[] = {
    { -1.0,  0.0 },
    {  1.0,  0.0 },
    { -1.0,  1.0 },
    {  1.0,  1.0 },
    { -1.0,  1.0 },
    {  1.0,  0.0 },
};

void main() {

    const float interval_length = 1.0f / float(n_line_segments_per_curve_);

    const float interval_start = interval_length * float(gl_VertexIndex);
    const float interval_end = interval_start + interval_length;


    const vec2 line_segment_start = computeCubicBezierAt(interval_start);
    const vec2 line_segment_end = computeCubicBezierAt(interval_end);

    const vec2 vector_along_length = line_segment_end - line_segment_start;
    const vec2 vector_along_width = 0.5*line_thickness_ * normalize(rotate90(vector_along_length));

    const vec2 base_vertex_pos = BASE_RECTANGLE[gl_VertexIndex % 6];


    // scale and rotate to the target rectangle
    vec2 vertex_pos = vector_along_length * base_vertex_pos.y
                    + vector_along_width  * base_vertex_pos.x;
    // translate
    vertex_pos += line_segment_start;


    // convert world-coords to normalized-coords
    vertex_pos -= vec2(camera_center_x, camera_center_y);
    vertex_pos /= vec2(camera_halfsize_x, camera_halfsize_y);


    // flip y-coord because the window's y-axis is upside-down
    vertex_pos.y = -vertex_pos.y;

    gl_Position = vec4(vertex_pos, 0.0, 1.0);
    fragment_color_ = (1.0f - interval_start)*control_point_1_color_ + interval_start*control_point_4_color_;
}
