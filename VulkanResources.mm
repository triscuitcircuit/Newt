#include "Newt/Session.h"
using Newt::Session;
#include "CoreInternal.h"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <thread>
using namespace NewtInternal;

uint32_t Session::FindMemoryType(uint32_t typeBits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(mPhysicalDevice, &memProps);
    for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
        if ((typeBits & (1u << i)) && (memProps.memoryTypes[i].propertyFlags & props) == props)
            return i;
    }
    throw std::runtime_error("FindMemoryType: no suitable memory type");
}

Buffer Session::CreateBuffer(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buffer b;
    b.size = size;
    VkBufferCreateInfo bci{ VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size;
    bci.usage = usage | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    CheckVk(vkCreateBuffer(mDevice, &bci, nullptr, &b.buffer), "vkCreateBuffer");
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(mDevice, b.buffer, &req);
    VkMemoryAllocateInfo mai{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CheckVk(vkAllocateMemory(mDevice, &mai, nullptr, &b.memory), "vkAllocateMemory(buffer)");
    CheckVk(vkBindBufferMemory(mDevice, b.buffer, b.memory, 0), "vkBindBufferMemory");
    return b;
}

void Session::UploadBuffer(Buffer& buffer, const void* data, VkDeviceSize size) {
    VkBufferCreateInfo bci{ VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer staging = VK_NULL_HANDLE;
    CheckVk(vkCreateBuffer(mDevice, &bci, nullptr, &staging), "vkCreateBuffer(staging)");
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(mDevice, staging, &req);
    VkMemoryAllocateInfo mai{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = FindMemoryType(
        req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory stagingMem = VK_NULL_HANDLE;
    CheckVk(vkAllocateMemory(mDevice, &mai, nullptr, &stagingMem), "vkAllocateMemory(staging)");
    CheckVk(vkBindBufferMemory(mDevice, staging, stagingMem, 0), "vkBindBufferMemory(staging)");
    void* mapped = nullptr;
    CheckVk(vkMapMemory(mDevice, stagingMem, 0, size, 0, &mapped), "vkMapMemory(staging)");
    std::memcpy(mapped, data, static_cast<size_t>(size));
    vkUnmapMemory(mDevice, stagingMem);
    ImmediateSubmit(mDevice, mQueue, mCommandPool, [&](VkCommandBuffer cmd) {
        VkBufferCopy copy{};
        copy.size = size;
        vkCmdCopyBuffer(cmd, staging, buffer.buffer, 1, &copy);
    });
    vkDestroyBuffer(mDevice, staging, nullptr);
    vkFreeMemory(mDevice, stagingMem, nullptr);
}

void Session::DestroyBuffer(Buffer& buffer) {
    if (buffer.buffer != VK_NULL_HANDLE) vkDestroyBuffer(mDevice, buffer.buffer, nullptr);
    if (buffer.memory != VK_NULL_HANDLE) vkFreeMemory(mDevice, buffer.memory, nullptr);
    buffer.buffer = VK_NULL_HANDLE;
    buffer.memory = VK_NULL_HANDLE;
    buffer.size = 0;
}

VkImageView Session::CreateView(VkImage image, VkFormat format, VkImageAspectFlags aspect) {
    VkImageViewCreateInfo vci{ VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = image;
    vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vci.format = format;
    vci.subresourceRange.aspectMask = aspect;
    vci.subresourceRange.baseMipLevel = 0;
    vci.subresourceRange.levelCount = 1;
    vci.subresourceRange.baseArrayLayer = 0;
    vci.subresourceRange.layerCount = 1;
    VkImageView view = VK_NULL_HANDLE;
    CheckVk(vkCreateImageView(mDevice, &vci, nullptr, &view), "vkCreateImageView");
    return view;
}

void Session::CreateTexture(Texture& tex, uint32_t width, uint32_t height) {
    tex.width = width; tex.height = height;
    VkImageCreateInfo ici{ VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_B8G8R8A8_SRGB;
    ici.extent.width = tex.width;
    ici.extent.height = tex.height;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    CheckVk(vkCreateImage(mDevice, &ici, nullptr, &tex.image), "vkCreateImage(texture)");
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(mDevice, tex.image, &req);
    VkMemoryAllocateInfo mai{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CheckVk(vkAllocateMemory(mDevice, &mai, nullptr, &tex.memory), "vkAllocateMemory(texture)");
    CheckVk(vkBindImageMemory(mDevice, tex.image, tex.memory, 0), "vkBindImageMemory(texture)");
    tex.view = CreateView(tex.image, VK_FORMAT_B8G8R8A8_SRGB, VK_IMAGE_ASPECT_COLOR_BIT);

    // Persistent host-visible mapped staging buffer for zero-allocation live frame uploads.
    tex.stagingSize = static_cast<VkDeviceSize>(tex.width) * tex.height * 4;
    VkBufferCreateInfo bci{ VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = tex.stagingSize;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    CheckVk(vkCreateBuffer(mDevice, &bci, nullptr, &tex.stagingBuffer),
            "vkCreateBuffer(persistent tex staging)");
    VkMemoryRequirements sreq{};
    vkGetBufferMemoryRequirements(mDevice, tex.stagingBuffer, &sreq);
    VkMemoryAllocateInfo smai{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    smai.allocationSize = sreq.size;
    smai.memoryTypeIndex = FindMemoryType(
        sreq.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    CheckVk(vkAllocateMemory(mDevice, &smai, nullptr, &tex.stagingMemory),
            "vkAllocateMemory(persistent tex staging)");
    CheckVk(vkBindBufferMemory(mDevice, tex.stagingBuffer, tex.stagingMemory, 0),
            "vkBindBufferMemory(persistent tex staging)");
    CheckVk(vkMapMemory(mDevice, tex.stagingMemory, 0, tex.stagingSize, 0, &tex.stagingMapped),
            "vkMapMemory(persistent tex staging)");

    VkDescriptorSetAllocateInfo dai{ VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dai.descriptorPool = mDescriptorPool;
    dai.descriptorSetCount = 1;
    dai.pSetLayouts = &mTextureLayout;
    CheckVk(vkAllocateDescriptorSets(mDevice, &dai, &tex.descriptor), "vkAllocateDescriptorSets");

    VkDescriptorImageInfo imgInfo{};
    imgInfo.sampler = mSampler;
    imgInfo.imageView = tex.view;
    imgInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkWriteDescriptorSet write{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    write.dstSet = tex.descriptor;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &imgInfo;
    vkUpdateDescriptorSets(mDevice, 1, &write, 0, nullptr);
    tex.initialized = true;
    tex.laidOut = false;
}

void Session::UpdateTexture(Texture& tex, const PixelImage& image) {
    if (!tex.initialized || tex.image == VK_NULL_HANDLE || !tex.stagingMapped) return;
    if (image.width != tex.width || image.height != tex.height) {
        if (image.pixels.size() < static_cast<size_t>(image.width) * image.height * 4 || !image.width || !image.height) return;
        PixelImage resized;
        resized.width = tex.width; resized.height = tex.height;
        resized.pixels.resize(static_cast<size_t>(tex.width) * tex.height * 4);
        for (uint32_t y = 0; y < tex.height; ++y)
            for (uint32_t x = 0; x < tex.width; ++x)
                std::memcpy(&resized.pixels[(static_cast<size_t>(y) * tex.width + x) * 4],
                    &image.pixels[(static_cast<size_t>(y * image.height / tex.height) * image.width + x * image.width / tex.width) * 4], 4);
        UpdateTexture(tex, resized);
        return;
    }
    const VkDeviceSize byteSize =
        std::min<VkDeviceSize>(tex.stagingSize,
                               static_cast<VkDeviceSize>(image.width) * image.height * 4);
    if (image.pixels.size() < byteSize) return;

    std::memcpy(tex.stagingMapped, image.pixels.data(), static_cast<size_t>(byteSize));
    const bool firstUpload = !tex.laidOut;
    tex.laidOut = true;

    const uint32_t width = image.width, height = image.height;
    auto record = [&, firstUpload, width, height](VkCommandBuffer cmd) {
        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.baseMipLevel = 0;
        range.levelCount = 1;
        range.baseArrayLayer = 0;
        range.layerCount = 1;

        VkImageMemoryBarrier pre{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        pre.srcAccessMask = firstUpload ? 0 : VK_ACCESS_SHADER_READ_BIT;
        pre.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        pre.oldLayout = firstUpload ? VK_IMAGE_LAYOUT_UNDEFINED
                                    : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        pre.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        pre.image = tex.image;
        pre.subresourceRange = range;
        vkCmdPipelineBarrier(cmd,
                             firstUpload ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                                         : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &pre);

        VkBufferImageCopy copy{};
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.mipLevel = 0;
        copy.imageSubresource.baseArrayLayer = 0;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent.width = std::min(width, tex.width);
        copy.imageExtent.height = std::min(height, tex.height);
        copy.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(cmd, tex.stagingBuffer, tex.image,
                               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);

        VkImageMemoryBarrier post{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        post.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        post.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        post.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        post.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        post.image = tex.image;
        post.subresourceRange = range;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr,
                             1, &post);
    };
    if (mBatchUploads) mUploads.push_back(record);
    else ImmediateSubmit(mDevice, mQueue, mCommandPool, record);
}

void Session::DestroyTexture(Texture& tex) {
    if (tex.descriptor != VK_NULL_HANDLE)
        vkFreeDescriptorSets(mDevice, mDescriptorPool, 1, &tex.descriptor);
    tex.descriptor = VK_NULL_HANDLE;
    if (tex.stagingMapped && tex.stagingMemory != VK_NULL_HANDLE) {
        vkUnmapMemory(mDevice, tex.stagingMemory);
        tex.stagingMapped = nullptr;
    }
    if (tex.stagingBuffer != VK_NULL_HANDLE) vkDestroyBuffer(mDevice, tex.stagingBuffer, nullptr);
    if (tex.stagingMemory != VK_NULL_HANDLE) vkFreeMemory(mDevice, tex.stagingMemory, nullptr);
    if (tex.view != VK_NULL_HANDLE) vkDestroyImageView(mDevice, tex.view, nullptr);
    if (tex.image != VK_NULL_HANDLE) vkDestroyImage(mDevice, tex.image, nullptr);
    if (tex.memory != VK_NULL_HANDLE) vkFreeMemory(mDevice, tex.memory, nullptr);
    tex.stagingBuffer = VK_NULL_HANDLE;
    tex.stagingMemory = VK_NULL_HANDLE;
    tex.stagingSize = 0;
    tex.view = VK_NULL_HANDLE;
    tex.image = VK_NULL_HANDLE;
    tex.memory = VK_NULL_HANDLE;
    tex.initialized = false;
    tex.laidOut = false;
}

VkShaderModule Session::CreateShader(const unsigned char* data, unsigned int len) {
    VkShaderModuleCreateInfo ci{ VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    ci.codeSize = len;
    ci.pCode = reinterpret_cast<const uint32_t*>(data);
    VkShaderModule mod = VK_NULL_HANDLE;
    CheckVk(vkCreateShaderModule(mDevice, &ci, nullptr, &mod), "vkCreateShaderModule");
    return mod;
}
