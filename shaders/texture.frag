#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 fragUv;
layout(location = 0) out vec4 outColor;
layout(push_constant) uniform Push { mat4 mvp; vec4 source; vec4 destination; } pc;
void main() {
    vec2 uv = (fragUv - pc.destination.xy) / pc.destination.zw;
    if (any(lessThan(uv, vec2(0))) || any(greaterThan(uv, vec2(1)))) {
        outColor = vec4(0.04, 0.05, 0.065, 1);
    } else {
        outColor = texture(tex, pc.source.xy + uv * pc.source.zw);
    }
}
