#ifndef NEWT_GPU_TEXTURE_INTERNAL_H
#define NEWT_GPU_TEXTURE_INTERNAL_H
#include "Newt/Session.h"
namespace Newt {
struct GPUTextureData {
    Texture texture;
    VkDevice device = VK_NULL_HANDLE;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    CVPixelBufferRef pixels = nullptr;
    void Release() noexcept;
    ~GPUTextureData() { Release(); }
};
}
#endif
