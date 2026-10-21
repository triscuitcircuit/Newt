#ifndef NEWT_PIXELIMAGE_H
#define NEWT_PIXELIMAGE_H
// SPDX-License-Identifier: MIT

#include <cstdint>
#include <vector>

constexpr uint32_t kTextureWidth = 1024;
constexpr uint32_t kTextureHeight = 640;

struct PixelImage {
    uint32_t width = kTextureWidth;
    uint32_t height = kTextureHeight;
    std::vector<uint8_t> pixels;
};

#endif
