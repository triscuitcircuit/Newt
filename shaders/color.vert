#version 450
layout(location = 0) in vec3 inPos;
layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
} pc;
layout(location = 0) out vec4 fragColor;
void main() {
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    fragColor = pc.color;
}
