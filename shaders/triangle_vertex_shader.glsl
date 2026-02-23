#version 410 core

layout(location=0) in vec3 a_Position;
layout(location=1) in vec3 a_Color;

uniform mat4 u_ModelMatrix; 
uniform mat4 u_ProjectionMatrix; 
out vec4 v_Color;

void main()
{
    gl_Position =  u_ProjectionMatrix *u_ModelMatrix * vec4(a_Position, 1.0) ;
    v_Color = vec4(a_Color, 1.0);
}
