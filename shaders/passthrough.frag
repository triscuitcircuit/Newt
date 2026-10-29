#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location = 0) in vec3 cameraRay;
layout(location = 1) in vec2 meshPos;
layout(location = 0) out vec4 outColor;
layout(push_constant) uniform Push {
    mat4 mvp;
    mat4 cameraFromLocal;
    vec4 lens0;
    vec4 lens1;
    vec4 lens2;
    vec4 size;
    vec4 cutout0;
    vec4 cutout1;
} pc;
const vec4 kOutside = vec4(0.04, 0.05, 0.065, 1);
// size.z > 0.5: nothing is drawn outside the camera image (camera-textured hands).
vec4 outside() {
    if (pc.size.z > 0.5) discard;
    return kOutside;
}
// Even-odd point-in-polygon test against the user's cutout quad (any shape, even concave).
bool insideCutout(vec2 p) {
    const vec2 q[4] = vec2[4](pc.cutout0.xy, pc.cutout0.zw, pc.cutout1.xy, pc.cutout1.zw);
    bool inside = false;
    for (int i = 0, j = 3; i < 4; j = i++) {
        if ((q[i].y > p.y) != (q[j].y > p.y) &&
            p.x < (q[j].x - q[i].x) * (p.y - q[i].y) / (q[j].y - q[i].y) + q[i].x)
            inside = !inside;
    }
    return inside;
}

void main() {
    if (!insideCutout(meshPos)) discard;
    // Meta's Fisheye62 camera model (PinholeSymmetric projection).
    if (cameraRay.z <= 1e-4) { outColor = outside(); return; }
    const vec2 ab = cameraRay.xy / cameraRay.z;
    const float r = length(ab);
    const float th = atan(r);
    const float t2 = th * th;
    const float poly = 1.0 + t2 * (pc.lens1.x + t2 * (pc.lens1.y + t2 * (pc.lens1.z + t2 * (pc.lens1.w +
                       t2 * (pc.lens2.x + t2 * pc.lens2.y)))));
    vec2 uv = ab * (r > 1e-8 ? th * poly / r : 1.0);
    const vec2 p = pc.lens2.zw;
    const float r2 = dot(uv, uv);
    uv += 2.0 * dot(uv, p) * uv + r2 * p;
    const vec2 texel = (pc.lens0.x * uv + pc.lens0.yz) * pc.size.xy;
    if (any(lessThan(texel, vec2(0))) || any(greaterThan(texel, vec2(1)))) { outColor = outside(); return; }
    outColor = texture(tex, texel);
    // Camera hands in outline mode: alpha is the hand mask; skip non-hand pixels entirely
    // (no depth either). Other camera images are opaque.
    if (pc.size.z > 0.5 && outColor.a < 0.03) discard;
}
