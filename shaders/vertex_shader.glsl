#version 410 core

layout(location=0) in vec3 a_Position;
layout(location=1) in vec3 a_Color;
layout(location=2) in uint a_TextureId;
layout(location=3) in vec2 a_TextureCoords;

uniform mat4 u_Matrix; 
out vec4 v_Color;
flat out uint v_TextureId;
out vec2 v_TextureCoords;

void main()
{
    gl_Position =  u_Matrix * vec4(a_Position, 1.0) ;
    v_Color = vec4(a_Color, 1.0);
    v_TextureId = a_TextureId;
    v_TextureCoords = a_TextureCoords;
}
