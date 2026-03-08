#version 410 core
in vec4 v_Color;
flat in uint v_TextureId;
in vec2 v_TextureCoords;

out vec4 f_Color;
uniform vec2 u_Resolution;
uniform float u_Time;

void main()
{
  f_Color = vec4(v_Color);
}

