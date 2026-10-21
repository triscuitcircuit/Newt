#ifndef NEWT_MATHTYPES_H
#define NEWT_MATHTYPES_H

#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <cmath>
#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <vector>

inline void CheckXr(XrResult result, const char* what) {
    if (XR_FAILED(result)) {
        std::ostringstream ss;
        ss << what << " failed: XrResult=" << static_cast<int>(result);
        throw std::runtime_error(ss.str());
    }
}

inline void CheckVk(VkResult result, const char* what) {
    if (result != VK_SUCCESS) {
        std::ostringstream ss;
        ss << what << " failed: VkResult=" << static_cast<int>(result);
        throw std::runtime_error(ss.str());
    }
}

struct Vec3 {
    float x = 0, y = 0, z = 0;
    Vec3() = default;
    Vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
    Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }
};

struct Vec4 { float x = 0, y = 0, z = 0, w = 1; };
struct Mat4 { float m[16]{}; };

inline Mat4 Identity() {
    Mat4 r{};
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
    return r;
}

inline Mat4 Multiply(const Mat4& a, const Mat4& b) {
    Mat4 r{};
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) sum += a.m[k * 4 + row] * b.m[col * 4 + k];
            r.m[col * 4 + row] = sum;
        }
    }
    return r;
}

inline Mat4 Translation(const Vec3& t) {
    Mat4 r = Identity();
    r.m[12] = t.x; r.m[13] = t.y; r.m[14] = t.z;
    return r;
}

inline Mat4 Scale(const Vec3& s) {
    Mat4 r = Identity();
    r.m[0] = s.x; r.m[5] = s.y; r.m[10] = s.z;
    return r;
}

inline Mat4 Rotation(const XrQuaternionf& q) {
    const float x2 = q.x + q.x, y2 = q.y + q.y, z2 = q.z + q.z;
    const float xx2 = q.x * x2, yy2 = q.y * y2, zz2 = q.z * z2;
    const float yz2 = q.y * z2, wx2 = q.w * x2;
    const float xy2 = q.x * y2, wz2 = q.w * z2;
    const float xz2 = q.x * z2, wy2 = q.w * y2;
    Mat4 r = Identity();
    r.m[0] = 1 - yy2 - zz2; r.m[1] = xy2 + wz2;     r.m[2] = xz2 - wy2;
    r.m[4] = xy2 - wz2;     r.m[5] = 1 - xx2 - zz2; r.m[6] = yz2 + wx2;
    r.m[8] = xz2 + wy2;     r.m[9] = yz2 - wx2;     r.m[10] = 1 - xx2 - yy2;
    return r;
}

inline Mat4 PoseMatrix(const XrPosef& pose, const Vec3& scale = {1, 1, 1}) {
    Vec3 t{pose.position.x, pose.position.y, pose.position.z};
    return Multiply(Translation(t), Multiply(Rotation(pose.orientation), Scale(scale)));
}

inline Mat4 RigidInverse(const Mat4& m) {
    Mat4 r = Identity();
    for (int col = 0; col < 3; ++col)
        for (int row = 0; row < 3; ++row) r.m[col * 4 + row] = m.m[row * 4 + col];
    Vec3 t{m.m[12], m.m[13], m.m[14]};
    r.m[12] = -(r.m[0] * t.x + r.m[4] * t.y + r.m[8] * t.z);
    r.m[13] = -(r.m[1] * t.x + r.m[5] * t.y + r.m[9] * t.z);
    r.m[14] = -(r.m[2] * t.x + r.m[6] * t.y + r.m[10] * t.z);
    return r;
}

inline Mat4 Projection(const XrFovf& fov, float nearZ, float farZ) {
    const float l = std::tan(fov.angleLeft), rgt = std::tan(fov.angleRight);
    const float d = std::tan(fov.angleDown), u = std::tan(fov.angleUp);
    const float w = rgt - l;
    const float h = d - u; // Vulkan Y-down clip space.
    Mat4 r{};
    r.m[0] = 2.0f / w;
    r.m[5] = 2.0f / h;
    r.m[8] = (rgt + l) / w;
    r.m[9] = (u + d) / h;
    r.m[10] = -farZ / (farZ - nearZ);
    r.m[11] = -1.0f;
    r.m[14] = -(farZ * nearZ) / (farZ - nearZ);
    return r;
}

inline Vec3 Rotate(const XrQuaternionf& q, const Vec3& v) {
    Vec3 u{q.x, q.y, q.z};
    Vec3 cross{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    Vec3 cross2{u.y * cross.z - u.z * cross.y, u.z * cross.x - u.x * cross.z,
                u.x * cross.y - u.y * cross.x};
    return v + cross * (2.0f * q.w) + cross2 * 2.0f;
}

inline XrQuaternionf Conjugate(const XrQuaternionf& q) { return {-q.x, -q.y, -q.z, q.w}; }
inline XrQuaternionf QuaternionProduct(const XrQuaternionf& a, const XrQuaternionf& b) {
    return {a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
            a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
            a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
            a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z};
}

inline XrPosef IdentityPose() {
    XrPosef p{};
    p.orientation = {0, 0, 0, 1};
    p.position = {0, 0, 0};
    return p;
}

struct VertexPC { float pos[3]; float uv[2]; };
struct ColorPush { Mat4 mvp; Vec4 color; };
struct TexturePush { Mat4 mvp; Vec4 source{0,0,1,1}; Vec4 destination{0,0,1,1}; };

inline std::vector<Vec3> MakeCube() {
    const float h = 0.5f;
    const Vec3 corners[8] = {{-h,-h,-h},{h,-h,-h},{h,h,-h},{-h,h,-h},
                             {-h,-h,h},{h,-h,h},{h,h,h},{-h,h,h}};
    const int faces[6][4] = {{0,1,2,3},{5,4,7,6},{4,0,3,7},{1,5,6,2},{3,2,6,7},{4,5,1,0}};
    std::vector<Vec3> out;
    for (auto& f : faces) {
        out.push_back(corners[f[0]]); out.push_back(corners[f[1]]); out.push_back(corners[f[2]]);
        out.push_back(corners[f[0]]); out.push_back(corners[f[2]]); out.push_back(corners[f[3]]);
    }
    return out;
}

inline std::vector<VertexPC> MakeQuad() {
    return {
        {{-0.5f,-0.5f,0},{0,1}}, {{0.5f,-0.5f,0},{1,1}}, {{0.5f,0.5f,0},{1,0}},
        {{-0.5f,-0.5f,0},{0,1}}, {{0.5f,0.5f,0},{1,0}}, {{-0.5f,0.5f,0},{0,0}},
    };
}

inline std::vector<Vec3> MakeGrid() {
    std::vector<Vec3> out;
    for (int i = -10; i <= 10; ++i) {
        float p = i * 0.5f;
        out.push_back({p, 0.0f, -5.0f}); out.push_back({p, 0.0f, 5.0f});
        out.push_back({-5.0f, 0.0f, p}); out.push_back({5.0f, 0.0f, p});
    }
    // A continuous world-locked horizon remains visible when looking away from desktops.
    for (int i=0;i<128;++i) {
        const float a=i*6.2831853f/128, b=(i+1)*6.2831853f/128;
        out.push_back({8*std::sin(a),1.3f,8*std::cos(a)});
        out.push_back({8*std::sin(b),1.3f,8*std::cos(b)});
        if (i%16==0) {
            out.push_back({8*std::sin(a),0,8*std::cos(a)});
            out.push_back({8*std::sin(a),2.5f,8*std::cos(a)});
        }
    }
    return out;
}

inline XrPath MakePath(XrInstance instance, const char* path) {
    XrPath out = XR_NULL_PATH;
    CheckXr(xrStringToPath(instance, path, &out), "xrStringToPath");
    return out;
}

template <typename T>
inline T GetXrFunction(XrInstance instance, const char* name) {
    PFN_xrVoidFunction fn = nullptr;
    CheckXr(xrGetInstanceProcAddr(instance, name, &fn), "xrGetInstanceProcAddr");
    return reinterpret_cast<T>(fn);
}

#endif // NEWT_MATHTYPES_H
