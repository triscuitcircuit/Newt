#version 450
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUv;
layout(push_constant) uniform Push { mat4 mvp; vec4 source; vec4 destination; } pc;
layout(location = 0) out vec2 fragUv;
void main() {
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    fragUv = inUv;
}
