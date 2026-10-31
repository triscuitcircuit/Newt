#pragma once
// SPDX-License-Identifier: MIT
#include <cstdint>
#include <cstddef>
#include <limits>

namespace Newt::VRMirror {
constexpr uint32_t Magic = 0x56524d50;
constexpr uint32_t Version = 1;
constexpr uint32_t MaxDimension = 4096;
constexpr size_t MaxPairBytes = size_t(MaxDimension) * MaxDimension * 8;
enum PixelFormat : uint32_t { BGRA = 1, RGBA = 2 };

struct Header {
    uint32_t magic = Magic, version = Version;
    uint32_t width = 0, height = 0, format = 0, eyeBytes = 0;
    uint64_t frame = 0;
};
static_assert(sizeof(Header) == 32, "VR viewer wire header size");

inline bool Valid(const Header& h) {
    if (h.magic != Magic || h.version != Version || !h.width || !h.height ||
        h.width > MaxDimension || h.height > MaxDimension || (h.format != BGRA && h.format != RGBA)) return false;
    const size_t bytes = size_t(h.width) * size_t(h.height) * 4;
    return bytes <= MaxPairBytes / 2 && h.eyeBytes == bytes;
}
}
