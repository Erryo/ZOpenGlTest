#version 410 core

layout(location=0) in vec3 a_Position;
layout(location=1) in vec3 a_Color;
layout(location=2) in vec3 a_Origin;
layout(location=3) in float a_Angle;

out vec4 v_Color;

void main()
{
    float angle_rad = radians(a_Angle);
    vec3 p = a_Position - a_Origin;

    float c = cos(angle_rad);
    float s = sin(angle_rad);
    mat2 rot = mat2(c, -s, s, c);

    p.xy = rot * p.xy;
    p += a_Origin;

    gl_Position = vec4(p*0.5, 1.0);
    v_Color = vec4(a_Color, 1.0);
}
