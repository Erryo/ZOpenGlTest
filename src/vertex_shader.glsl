#version 410 core
in vec4 a_Position;
in vec4 a_Color;
// Color output to pass to fragment shader
out vec4 v_Color;
void main()
{
  gl_Position = vec4(a_Position.x,a_Position.y,a_Position.z,a_Position.w);
  v_Color = a_Color;
}

