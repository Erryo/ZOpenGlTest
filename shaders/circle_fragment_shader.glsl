#version 410 core
in vec4 v_Color;
flat in uint v_TextureId;
in vec2 v_TextureCoords;

out vec4 f_Color;
uniform vec2 u_Resolution;
uniform float u_Time;
void main()
{

  vec2 uv = (gl_FragCoord.xy * 2.0 - u_Resolution.xy) / u_Resolution.y; 
  uv *= 2;
  uv = fract(uv);
  uv -= 0.5;
  float d = length(uv); 
  float milli =  u_Time*0.000000001;

  d = sin(d*8.0+milli)/8.0;
  d = abs(d);
  d = smoothstep(0.0,0.1, d);
  f_Color = vec4(d,d*2,d*2,1);
}

