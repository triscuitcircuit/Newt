// SPDX-License-Identifier: MIT
#include "GPUTextureInternal.h"
#include "include/NewtLog.h"
#include <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <algorithm>

namespace Newt {
namespace {
using UseSurface = VkResult (*)(VkImage, IOSurfaceRef);
UseSurface SurfaceImporter(VkDevice device) {
    Dl_info owner{};
    auto create = vkGetDeviceProcAddr(device, "vkCreateImage");
    if (!create || !dladdr(reinterpret_cast<void*>(create), &owner)) return nullptr;
    if (owner.dli_fbase == reinterpret_cast<const void*>(_dyld_get_image_header(0)))
        return reinterpret_cast<UseSurface>(dlsym(RTLD_MAIN_ONLY, "vkUseIOSurfaceMVK"));
    void* library = dlopen(owner.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
    if (!library) return nullptr;
    auto import = reinterpret_cast<UseSurface>(dlsym(library, "vkUseIOSurfaceMVK"));
    dlclose(library);
    return import;
}
}

void GPUTextureData::Release() noexcept {
    if (device) {
        if (texture.descriptor) vkFreeDescriptorSets(device, pool, 1, &texture.descriptor);
        if (texture.view) vkDestroyImageView(device, texture.view, nullptr);
        if (texture.image) vkDestroyImage(device, texture.image, nullptr);
    }
    texture = {};
    device = VK_NULL_HANDLE;
    if (pixels) CVPixelBufferRelease(pixels);
    pixels = nullptr;
}

GPUTexture Session::ImportPixelBuffer(CVPixelBufferRef pixels) {
    if (!mDevice || !pixels || CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferIsPlanar(pixels)) return {};
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixels);
    auto import = SurfaceImporter(mDevice);
    if (!surface || !import) return {};
    auto result = std::make_shared<GPUTextureData>();
    result->device = mDevice; result->pool = mDescriptorPool;
    result->pixels = CVPixelBufferRetain(pixels);
    auto& texture = result->texture;
    texture.width = static_cast<uint32_t>(CVPixelBufferGetWidth(pixels));
    texture.height = static_cast<uint32_t>(CVPixelBufferGetHeight(pixels));
    VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = VK_FORMAT_B8G8R8A8_SRGB;
    info.extent = {texture.width, texture.height, 1};
    info.mipLevels = 1; info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
    if (vkCreateImage(mDevice, &info, nullptr, &texture.image) != VK_SUCCESS) return {};
    if (import(texture.image, surface) != VK_SUCCESS) return {};
    try {
        texture.view = CreateView(texture.image, info.format, VK_IMAGE_ASPECT_COLOR_BIT);
        VkDescriptorSetAllocateInfo alloc{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        alloc.descriptorPool = mDescriptorPool;
        alloc.descriptorSetCount = 1; alloc.pSetLayouts = &mTextureLayout;
        CheckVk(vkAllocateDescriptorSets(mDevice, &alloc, &texture.descriptor), "GPU descriptor");
        VkDescriptorImageInfo image{mSampler, texture.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        write.dstSet = texture.descriptor; write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; write.pImageInfo = &image;
        vkUpdateDescriptorSets(mDevice, 1, &write, 0, nullptr);
        texture.initialized = true;
        mGPUTextures.erase(std::remove_if(mGPUTextures.begin(), mGPUTextures.end(),
            [](const auto& entry) { return entry.expired(); }), mGPUTextures.end());
        mGPUTextures.push_back(result);
        mPendingGPUTextures.push_back(result);
        return result;
    } catch (const std::exception& error) {
        Newt_Logf(NEWT_LOG_WARNING, "GPU capture import failed; CPU fallback: %s", error.what());
        return {};
    }
}

void Session::PrepareGPUTextures(VkCommandBuffer command) {
    for (const auto& frame : mPendingGPUTextures) {
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = frame->texture.image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
        mSampledGPUTextures[mDrawingSlot].push_back(frame);
    }
}

void Session::DrawGPUTexture(VkCommandBuffer command, const Mat4& viewProj, const Mat4& model,
                            const GPUTexture& frame, const TextureRegion& region,
                            const Buffer* mesh, uint32_t count) {
    if (!frame || frame->device != mDevice || !frame->texture.initialized) return;
    auto& retained = mSampledGPUTextures[mDrawingSlot];
    if (std::find(retained.begin(), retained.end(), frame) == retained.end()) retained.push_back(frame);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, mTexturePipeline);
    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(command, 0, 1, mesh ? &mesh->buffer : &mQuadBuffer.buffer, &offset);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, mTexturePipelineLayout,
                            0, 1, &frame->texture.descriptor, 0, nullptr);
    TexturePush push{Multiply(viewProj, model), region.source, region.destination};
    vkCmdPushConstants(command, mTexturePipelineLayout,
                        VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push), &push);
    vkCmdDraw(command, count, 1, 0, 0);
}

void Session::CleanupGPUTextures() noexcept {
    for (auto& entry : mGPUTextures) if (auto frame = entry.lock()) frame->Release();
    for (auto& frames : mSampledGPUTextures) frames.clear();
    mPendingGPUTextures.clear(); mGPUTextures.clear();
}
}
