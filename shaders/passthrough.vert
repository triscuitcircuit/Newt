#version 450
// Passthrough window: the panel is a world-fixed window; each fragment samples the
// headset camera along the ray from the eye through that point.
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUv;
layout(push_constant) uniform Push {
    mat4 mvp;
    mat4 cameraFromLocal; // panel-local point -> ray from the eye, in camera axes (x right, y down, z forward)
    vec4 lens0;           // f, cx, cy (pixels), unused
    vec4 lens1;           // Fisheye62 k0..k3
    vec4 lens2;           // k4, k5, p0, p1
    vec4 size;            // 1/width, 1/height (calibrated image), discard outside the image, unused
    vec4 cutout0;         // cutout quad in mesh units: top-left xy, top-right xy
    vec4 cutout1;         // bottom-right xy, bottom-left xy
} pc;
layout(location = 0) out vec3 cameraRay;
layout(location = 1) out vec2 meshPos;
void main() {
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    cameraRay = (pc.cameraFromLocal * vec4(inPos, 1.0)).xyz;
    meshPos = inPos.xy;
}
