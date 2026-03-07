#version 410 core

layout(location=0) in vec3 a_Position;
layout(location=1) in vec3 a_Color;

uniform mat4 u_Matrix;
out vec4 v_Color;
out vec3 v_WorldPos;

void main()
{
    vec4 world = vec4(a_Position, 1.0);
    gl_Position = u_Matrix * world;
    v_Color = vec4(a_Color, 1.0);
    v_WorldPos = a_Position;
}
