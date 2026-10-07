#version 460 core
// Moves a virtual camera through a rendered still using its depth map, so near things
// slide past faster than far ones (real parallax). Used by the door intro.
#include <flutter/runtime_effect.glsl>
precision highp float;

uniform vec2 uSize;          // canvas size (unused, kept for layout parity)
uniform vec4 uRect;          // where the square image sits on screen: left, top, size, size
uniform vec3 uCam;           // camera move in metres: x right, y up, z forward
uniform float uFocal;        // focal length as a fraction of the image size
uniform float uOpen;         // how much of the "open" image's light to blend in
uniform vec4 uDoor;          // hidden-door rect in image uv: left, top, right, bottom
uniform float uDoorOpen;     // 1 once the hidden door has started to move

uniform sampler2D uClosed;
uniform sampler2D uOpened;
uniform sampler2D uDepthClosed;
uniform sampler2D uDepthOpened;

out vec4 fragColor;

const float NEAR = 0.5;
const float FAR = 14.0;

float depthOf(float v) {
  return 1.0 / (v * (1.0 / NEAR - 1.0 / FAR) + 1.0 / FAR);
}

bool inDoor(vec2 uv) {
  return uv.x > uDoor.x && uv.x < uDoor.z && uv.y > uDoor.y && uv.y < uDoor.w;
}

float depthAt(vec2 uv) {
  if (uDoorOpen > 0.5 && inDoor(uv)) return depthOf(texture(uDepthOpened, uv).r);
  return depthOf(texture(uDepthClosed, uv).r);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 uv = (p - uRect.xy) / uRect.zw;
  vec2 pp = vec2(0.5, 0.5);
  // find the source pixel that lands here after the camera moves (a few fixed-point steps)
  vec2 src = uv;
  for (int i = 0; i < 5; i++) {
    float d = depthAt(src);
    float dz = max(d - uCam.z, 0.08);
    src = pp + (uv - pp) * (dz / d) + vec2(uCam.x, -uCam.y) * (uFocal / d);
  }
  vec4 c;
  if (uDoorOpen > 0.5 && inDoor(src)) {
    c = texture(uOpened, src);
  } else {
    c = mix(texture(uClosed, src), texture(uOpened, src), uOpen);
  }
  float inside = step(0.0, src.x) * step(src.x, 1.0) * step(0.0, src.y) * step(src.y, 1.0);
  float onCanvas = step(p.x, uSize.x + 1.0) * step(p.y, uSize.y + 1.0);   // always 1 here; keeps uSize in use
  fragColor = vec4(c.rgb * inside * onCanvas, 1.0);
}
