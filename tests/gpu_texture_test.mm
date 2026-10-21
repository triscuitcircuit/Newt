
#include "GPUTextureInternal.h"
#include <cassert>
#include <cstring>
#include <iostream>
namespace Newt {
struct SessionGPUProbe {
static void Run() {
    Session session;
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ici.pApplicationInfo=&app;
    CheckVk(vkCreateInstance(&ici,nullptr,&session.mVkInstance),"instance");
    uint32_t count=1;
    CheckVk(vkEnumeratePhysicalDevices(session.mVkInstance,&count,&session.mPhysicalDevice),"physical device");
    float priority=1;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueCount=1; qci.pQueuePriorities=&priority;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dci.queueCreateInfoCount=1; dci.pQueueCreateInfos=&qci;
    CheckVk(vkCreateDevice(session.mPhysicalDevice,&dci,nullptr,&session.mDevice),"device");
    vkGetDeviceQueue(session.mDevice,0,0,&session.mQueue);
    session.CreateRenderAssets();
    VkAttachmentDescription attachment{};
    attachment.format=VK_FORMAT_R8G8B8A8_UNORM; attachment.samples=VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
    attachment.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference ref{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass{}; subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount=1; subpass.pColorAttachments=&ref;
    VkSubpassDependency dependencies[2]{};
    dependencies[0]={VK_SUBPASS_EXTERNAL,0,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                     0,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,0};
    dependencies[1]={0,VK_SUBPASS_EXTERNAL,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,
                     VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,VK_ACCESS_TRANSFER_READ_BIT,0};
    VkRenderPassCreateInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    rp.attachmentCount=1; rp.pAttachments=&attachment; rp.subpassCount=1; rp.pSubpasses=&subpass;
    rp.dependencyCount=2; rp.pDependencies=dependencies;
    CheckVk(vkCreateRenderPass(session.mDevice,&rp,nullptr,&session.mRenderPass),"renderpass");
    session.CreatePipelines();
    NSDictionary* attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    CVPixelBufferRef pixels=nullptr;
    assert(CVPixelBufferCreate(nullptr,64,64,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&pixels)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pixels,0);
    for(int y=0;y<64;++y) {
        auto row=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixels))+y*CVPixelBufferGetBytesPerRow(pixels);
        for(int x=0;x<64;++x) { row[x*4]=x<32?255:0; row[x*4+1]=0; row[x*4+2]=x<32?0:255; row[x*4+3]=255; }
    }
    CVPixelBufferUnlockBaseAddress(pixels,0);
    auto frame=session.ImportPixelBuffer(pixels); assert(frame);
    CVPixelBufferRelease(pixels); // only the imported handle now retains producer memory
    assert(!session.ImportPixelBuffer(nullptr));
    CVPixelBufferRef unsupported=nullptr;
    assert(CVPixelBufferCreate(nullptr,64,64,kCVPixelFormatType_OneComponent8,(__bridge CFDictionaryRef)attributes,&unsupported)==kCVReturnSuccess);
    assert(!session.ImportPixelBuffer(unsupported)); CVPixelBufferRelease(unsupported);
    VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    imageInfo.imageType=VK_IMAGE_TYPE_2D; imageInfo.format=attachment.format; imageInfo.extent={64,64,1};
    imageInfo.mipLevels=1; imageInfo.arrayLayers=1; imageInfo.samples=VK_SAMPLE_COUNT_1_BIT;
    imageInfo.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    VkImage output; CheckVk(vkCreateImage(session.mDevice,&imageInfo,nullptr,&output),"output");
    VkMemoryRequirements requirements; vkGetImageMemoryRequirements(session.mDevice,output,&requirements);
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.allocationSize=requirements.size;
    alloc.memoryTypeIndex=session.FindMemoryType(requirements.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory memory; CheckVk(vkAllocateMemory(session.mDevice,&alloc,nullptr,&memory),"memory");
    CheckVk(vkBindImageMemory(session.mDevice,output,memory,0),"bind");
    auto view=session.CreateView(output,attachment.format,VK_IMAGE_ASPECT_COLOR_BIT);
    VkFramebufferCreateInfo fb{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; fb.renderPass=session.mRenderPass;
    fb.attachmentCount=1; fb.pAttachments=&view; fb.width=64; fb.height=64; fb.layers=1;
    VkFramebuffer framebuffer; CheckVk(vkCreateFramebuffer(session.mDevice,&fb,nullptr,&framebuffer),"framebuffer");
    Buffer readback; readback.size=64*64*4;
    VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size=readback.size; bufferInfo.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    CheckVk(vkCreateBuffer(session.mDevice,&bufferInfo,nullptr,&readback.buffer),"readback");
    vkGetBufferMemoryRequirements(session.mDevice,readback.buffer,&requirements);
    alloc.allocationSize=requirements.size;
    alloc.memoryTypeIndex=session.FindMemoryType(requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    CheckVk(vkAllocateMemory(session.mDevice,&alloc,nullptr,&readback.memory),"readback memory");
    CheckVk(vkBindBufferMemory(session.mDevice,readback.buffer,readback.memory,0),"readback bind");
    for(size_t slot=0;slot<2;++slot) {
        auto command=session.mCommandBuffers[slot]; auto fence=session.mFences[slot];
        vkResetFences(session.mDevice,1,&fence); session.mDrawingSlot=slot;
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        CheckVk(vkBeginCommandBuffer(command,&begin),"begin"); session.PrepareGPUTextures(command);
        VkClearValue clear{};
        VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; pass.renderPass=session.mRenderPass;
        pass.framebuffer=framebuffer; pass.renderArea.extent={64,64}; pass.clearValueCount=1; pass.pClearValues=&clear;
        vkCmdBeginRenderPass(command,&pass,VK_SUBPASS_CONTENTS_INLINE);
        VkViewport viewport{0,0,64,64,0,1}; VkRect2D scissor{{0,0},{64,64}};
        vkCmdSetViewport(command,0,1,&viewport); vkCmdSetScissor(command,0,1,&scissor);
        TextureRegion region;
        region.source={0.5f,0,0.5f,1};
        region.destination={0.25f,0.25f,0.5f,0.5f};
        session.DrawGPUTexture(command,Identity(),Identity(),frame,region);
        vkCmdEndRenderPass(command);
        VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent={64,64,1};
        vkCmdCopyImageToBuffer(command,output,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,readback.buffer,1,&copy);
        CheckVk(vkEndCommandBuffer(command),"end");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        CheckVk(vkQueueSubmit(session.mQueue,1,&submit,fence),"submit");
        CheckVk(vkWaitForFences(session.mDevice,1,&fence,VK_TRUE,UINT64_MAX),"fence");
    }
    // PrepareGPUTextures leaves clearing mPendingGPUTextures to the caller,
    // once, after every eye's command buffer has had its own chance to
    // record the layout-transition barrier (see CoreFrame.mm::RenderFrame) --
    // this test's own two-slot loop above is standing in for that, so it
    // must do the same, or `frame` stays reachable through the pending list.
    session.mPendingGPUTextures.clear();
    void* bytes=nullptr; CheckVk(vkMapMemory(session.mDevice,readback.memory,0,VK_WHOLE_SIZE,0,&bytes),"map");
    auto center=static_cast<uint8_t*>(bytes)+(32*64+32)*4;
    std::cerr<<"Sampled center RGBA: "<<int(center[0])<<","<<int(center[1])<<","<<int(center[2])<<","<<int(center[3])<<"\n";
    assert(center[0]>245 && center[1]<5 && center[2]<5 && center[3]>245);
    auto border=static_cast<uint8_t*>(bytes)+(32*64+19)*4;
    assert(border[0]>=9 && border[0]<=12 && border[1]>=11 && border[1]<=15);
    vkUnmapMemory(session.mDevice,readback.memory);
    auto heldPixels=CVPixelBufferRetain(frame->pixels);
    std::weak_ptr<GPUTextureData> weak=frame;
    frame.reset(); assert(!weak.expired());
    session.mSampledGPUTextures[0].clear(); assert(!weak.expired());
    session.mSampledGPUTextures[1].clear(); assert(weak.expired());
    auto late=session.ImportPixelBuffer(heldPixels); assert(late);
    CVPixelBufferRelease(heldPixels);
    session.DestroyBuffer(readback);
    vkDestroyFramebuffer(session.mDevice,framebuffer,nullptr);
    vkDestroyImageView(session.mDevice,view,nullptr);
    vkDestroyImage(session.mDevice,output,nullptr); vkFreeMemory(session.mDevice,memory,nullptr);
    session.Cleanup();
    assert(!late->pixels && !late->device);
    late.reset();
    std::cout<<"PASS: IOSurface sampling, two-eye lifetime, unsupported-format fallback and cleanup\n";
}
};
}
int main() { @autoreleasepool { Newt::SessionGPUProbe::Run(); } }
