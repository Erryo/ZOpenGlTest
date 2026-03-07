#version 410 core
in vec4 v_Color;
in vec3 v_WorldPos;
out vec4 f_Color;
uniform vec2 u_Resolution;
uniform float u_Time;
uniform int u_SceneMode;

float hash21(vec2 p) {
  p = fract(p * vec2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}

void main()
{
  vec2 uv = (gl_FragCoord.xy * 2.0 - u_Resolution.xy) / u_Resolution.y;

  if (u_SceneMode == 0) {
    float pulse = 0.6 + 0.4 * sin(u_Time * 1.8 + length(v_WorldPos.xy) * 2.0);
    vec3 warmGradient = mix(vec3(1.0, 0.56, 0.68), vec3(1.0, 0.85, 0.35), 0.5 + 0.5 * sin(uv.y * 2.4 + u_Time * 0.8));
    vec3 motherPalette = v_Color.rgb * warmGradient * pulse;
    float halo = smoothstep(1.6, 0.0, length(uv - vec2(0.0, 0.1)));
    motherPalette += vec3(0.18, 0.09, 0.12) * halo;
    f_Color = vec4(motherPalette, 1.0);
    return;
  }

  float twinkle = smoothstep(0.92, 1.0, sin(u_Time * 4.0 + hash21(floor((uv + 2.0) * 8.0)) * 8.0));
  vec3 neon = mix(vec3(0.3, 0.45, 1.0), vec3(0.95, 0.4, 1.0), 0.5 + 0.5 * sin(u_Time + v_WorldPos.x * 1.4));
  vec3 sisterPalette = v_Color.rgb * neon;
  sisterPalette += twinkle * vec3(0.2, 0.25, 0.4);
  float vignette = smoothstep(1.8, 0.15, length(uv));
  sisterPalette *= vignette;
  f_Color = vec4(sisterPalette, 1.0);
}
