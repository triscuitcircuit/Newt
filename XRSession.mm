#include "include/NewtLog.h"
#include "Newt/Session.h"
using Newt::Session;
#include "CoreInternal.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
using namespace NewtInternal;

// Fallback declarations for Vulkan headers that omit these (values are ABI-stable).
#ifndef VK_EXT_METAL_SURFACE_EXTENSION_NAME
#define VK_EXT_METAL_SURFACE_EXTENSION_NAME "VK_EXT_metal_surface"
#endif
#ifndef VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
#define VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME "VK_KHR_portability_enumeration"
#endif
#ifndef VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
#define VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR 0x00000001
#endif

void Session::CreateInstanceAndSystem() {
    XrApplicationInfo appInfo{};
    std::strncpy(appInfo.applicationName, "NewtXR", XR_MAX_APPLICATION_NAME_SIZE - 1);
    appInfo.applicationVersion = 1;
    std::strncpy(appInfo.engineName, "Newt", XR_MAX_ENGINE_NAME_SIZE - 1);
    appInfo.engineVersion = 1;
    appInfo.apiVersion = XR_CURRENT_API_VERSION;

    const char* const extensions[] = { XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME };
    XrInstanceCreateInfo createInfo{ XR_TYPE_INSTANCE_CREATE_INFO };
    createInfo.applicationInfo = appInfo;
    createInfo.enabledExtensionCount = 1;
    createInfo.enabledExtensionNames = extensions;
    CheckXr(xrCreateInstance(&createInfo, &mInstance), "xrCreateInstance");

    XrSystemGetInfo systemInfo{ XR_TYPE_SYSTEM_GET_INFO };
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    CheckXr(xrGetSystem(mInstance, &systemInfo, &mSystemId), "xrGetSystem");

    XrSystemProperties systemProperties{ XR_TYPE_SYSTEM_PROPERTIES };
    CheckXr(xrGetSystemProperties(mInstance, mSystemId, &systemProperties), "xrGetSystemProperties");
    Newt_Logf(NEWT_LOG_INFO, "OpenXR system '%s'", systemProperties.systemName);
    mDelegate->OnSystem(systemProperties);

    mGetRequirements2 =
        GetXrFunction<PFN_xrGetVulkanGraphicsRequirements2KHR>(mInstance, "xrGetVulkanGraphicsRequirements2KHR");
    mCreateVkInstance =
        GetXrFunction<PFN_xrCreateVulkanInstanceKHR>(mInstance, "xrCreateVulkanInstanceKHR");
    mGetVkDevice2 =
        GetXrFunction<PFN_xrGetVulkanGraphicsDevice2KHR>(mInstance, "xrGetVulkanGraphicsDevice2KHR");
    mCreateVkDevice =
        GetXrFunction<PFN_xrCreateVulkanDeviceKHR>(mInstance, "xrCreateVulkanDeviceKHR");
}

void Session::CreateVulkanAndSession() {
    XrGraphicsRequirementsVulkan2KHR reqs{ XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR };
    CheckXr(mGetRequirements2(mInstance, mSystemId, &reqs), "xrGetVulkanGraphicsRequirements2KHR");

    VkApplicationInfo appInfo{ VK_STRUCTURE_TYPE_APPLICATION_INFO };
    appInfo.pApplicationName = "NewtXR";
    appInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    appInfo.pEngineName = "Newt";
    appInfo.engineVersion = VK_MAKE_VERSION(1, 0, 0);
    appInfo.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo ici{ VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &appInfo;

    XrVulkanInstanceCreateInfoKHR vkInstanceInfo{ XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR };
    vkInstanceInfo.systemId = mSystemId;
    vkInstanceInfo.pfnGetInstanceProcAddr = &vkGetInstanceProcAddr;
    vkInstanceInfo.vulkanCreateInfo = &ici;

    VkResult vkRes = VK_SUCCESS;
    CheckXr(mCreateVkInstance(mInstance, &vkInstanceInfo, &mVkInstance, &vkRes),
            "xrCreateVulkanInstanceKHR");
    CheckVk(vkRes, "vkCreateInstance");

    XrVulkanGraphicsDeviceGetInfoKHR deviceGetInfo{ XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR };
    deviceGetInfo.systemId = mSystemId;
    deviceGetInfo.vulkanInstance = mVkInstance;
    CheckXr(mGetVkDevice2(mInstance, &deviceGetInfo, &mPhysicalDevice),
            "xrGetVulkanGraphicsDevice2KHR");

    uint32_t queueCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(mPhysicalDevice, &queueCount, nullptr);
    std::vector<VkQueueFamilyProperties> queueProps(queueCount);
    vkGetPhysicalDeviceQueueFamilyProperties(mPhysicalDevice, &queueCount, queueProps.data());
    mQueueFamily = UINT32_MAX;
    for (uint32_t i = 0; i < queueCount; ++i) {
        if (queueProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            mQueueFamily = i;
            break;
        }
    }
    if (mQueueFamily == UINT32_MAX) throw std::runtime_error("no graphics queue family");

    const float queuePriority = 1.0f;
    VkDeviceQueueCreateInfo qci{ VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = mQueueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &queuePriority;

    VkPhysicalDeviceFeatures features{};

    VkDeviceCreateInfo dci{ VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.pEnabledFeatures = &features;

    XrVulkanDeviceCreateInfoKHR vkDeviceInfo{ XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR };
    vkDeviceInfo.systemId = mSystemId;
    vkDeviceInfo.pfnGetInstanceProcAddr = &vkGetInstanceProcAddr;
    vkDeviceInfo.vulkanCreateInfo = &dci;
    vkDeviceInfo.vulkanPhysicalDevice = mPhysicalDevice;
    vkRes = VK_SUCCESS;
    CheckXr(mCreateVkDevice(mInstance, &vkDeviceInfo, &mDevice, &vkRes),
            "xrCreateVulkanDeviceKHR");
    CheckVk(vkRes, "vkCreateDevice");
    vkGetDeviceQueue(mDevice, mQueueFamily, 0, &mQueue);

    XrGraphicsBindingVulkanKHR binding{ XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR };
    binding.instance = mVkInstance;
    binding.physicalDevice = mPhysicalDevice;
    binding.device = mDevice;
    binding.queueFamilyIndex = mQueueFamily;
    binding.queueIndex = 0;

    XrSessionCreateInfo sci{ XR_TYPE_SESSION_CREATE_INFO };
    sci.next = &binding;
    sci.systemId = mSystemId;
    CheckXr(xrCreateSession(mInstance, &sci, &mSession), "xrCreateSession");
}

void Session::CreateReferenceSpace() {
    XrReferenceSpaceCreateInfo info{ XR_TYPE_REFERENCE_SPACE_CREATE_INFO };
    info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    info.poseInReferenceSpace = IdentityPose();
    XrResult res = xrCreateReferenceSpace(mSession, &info, &mAppSpace);
    if (XR_FAILED(res)) {
        info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        CheckXr(xrCreateReferenceSpace(mSession, &info, &mAppSpace), "xrCreateReferenceSpace");
    }
}

void Session::CreateSwapchains() {
    uint32_t viewCount = 0;
    CheckXr(xrEnumerateViewConfigurationViews(mInstance, mSystemId, mViewType, 0, &viewCount,
                                              nullptr),
            "xrEnumerateViewConfigurationViews(count)");
    mViewConfigs.resize(viewCount, { XR_TYPE_VIEW_CONFIGURATION_VIEW });
    CheckXr(xrEnumerateViewConfigurationViews(mInstance, mSystemId, mViewType, viewCount,
                                              &viewCount, mViewConfigs.data()),
            "xrEnumerateViewConfigurationViews");

    uint32_t formatCount = 0;
    CheckXr(xrEnumerateSwapchainFormats(mSession, 0, &formatCount, nullptr),
            "xrEnumerateSwapchainFormats(count)");
    std::vector<int64_t> formats(formatCount);
    CheckXr(xrEnumerateSwapchainFormats(mSession, formatCount, &formatCount, formats.data()),
            "xrEnumerateSwapchainFormats");
    mColorFormat = VK_FORMAT_B8G8R8A8_SRGB;
    bool haveSrgb = false;
    for (int64_t f : formats) {
        if (f == static_cast<int64_t>(VK_FORMAT_B8G8R8A8_SRGB)) {
            haveSrgb = true;
            break;
        }
    }
    if (!haveSrgb) mColorFormat = static_cast<VkFormat>(formats[0]);

    const VkFormat depthCandidates[] = { VK_FORMAT_D32_SFLOAT, VK_FORMAT_D16_UNORM };
    mDepthFormat = VK_FORMAT_D32_SFLOAT;
    for (VkFormat f : depthCandidates) {
        VkFormatProperties props{};
        vkGetPhysicalDeviceFormatProperties(mPhysicalDevice, f, &props);
        if (props.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) {
            mDepthFormat = f;
            break;
        }
    }

    VkAttachmentDescription attachments[2]{};
    attachments[0].format = mColorFormat;
    attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachments[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachments[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[0].initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    attachments[0].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    attachments[1].format = mDepthFormat;
    attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachments[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkAttachmentReference depthRef{};
    depthRef.attachment = 1;
    depthRef.layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colorRef;
    subpass.pDepthStencilAttachment = &depthRef;
    VkSubpassDependency dep{};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo rpci{ VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 2;
    rpci.pAttachments = attachments;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &subpass;
    rpci.dependencyCount = 1;
    rpci.pDependencies = &dep;
    CheckVk(vkCreateRenderPass(mDevice, &rpci, nullptr, &mRenderPass), "vkCreateRenderPass");

    mSwapchains.resize(mViewConfigs.size());
    for (size_t i = 0; i < mViewConfigs.size(); ++i) {
        SwapchainView& sv = mSwapchains[i];
        sv.width = mViewConfigs[i].recommendedImageRectWidth;
        sv.height = mViewConfigs[i].recommendedImageRectHeight;

        XrSwapchainCreateInfo swci{ XR_TYPE_SWAPCHAIN_CREATE_INFO };
        swci.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
        swci.format = static_cast<int64_t>(mColorFormat);
        swci.sampleCount = 1;
        swci.width = sv.width;
        swci.height = sv.height;
        swci.faceCount = 1;
        swci.arraySize = 1;
        swci.mipCount = 1;
        CheckXr(xrCreateSwapchain(mSession, &swci, &sv.swapchain), "xrCreateSwapchain");

        uint32_t imageCount = 0;
        CheckXr(xrEnumerateSwapchainImages(sv.swapchain, 0, &imageCount, nullptr),
                "xrEnumerateSwapchainImages(count)");
        std::vector<XrSwapchainImageVulkanKHR> xrImages(
            imageCount, { XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR });
        CheckXr(xrEnumerateSwapchainImages(sv.swapchain, imageCount, &imageCount,
                                           reinterpret_cast<XrSwapchainImageBaseHeader*>(
                                               xrImages.data())),
                "xrEnumerateSwapchainImages");
        sv.images.resize(imageCount);
        sv.views.resize(imageCount);
        for (uint32_t k = 0; k < imageCount; ++k) {
            sv.images[k] = xrImages[k].image;
            sv.views[k] = CreateView(sv.images[k], mColorFormat, VK_IMAGE_ASPECT_COLOR_BIT);
        }

        sv.depthImages.resize(imageCount);
        sv.depthMemories.resize(imageCount);
        sv.depthViews.resize(imageCount);
        for (uint32_t k = 0; k < imageCount; ++k) {
            VkImageCreateInfo ici{ VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
            ici.imageType = VK_IMAGE_TYPE_2D;
            ici.format = mDepthFormat;
            ici.extent.width = sv.width;
            ici.extent.height = sv.height;
            ici.extent.depth = 1;
            ici.mipLevels = 1;
            ici.arrayLayers = 1;
            ici.samples = VK_SAMPLE_COUNT_1_BIT;
            ici.tiling = VK_IMAGE_TILING_OPTIMAL;
            ici.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
            ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            CheckVk(vkCreateImage(mDevice, &ici, nullptr, &sv.depthImages[k]),
                    "vkCreateImage(depth)");
            VkMemoryRequirements req{};
            vkGetImageMemoryRequirements(mDevice, sv.depthImages[k], &req);
            VkMemoryAllocateInfo mai{ VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
            mai.allocationSize = req.size;
            mai.memoryTypeIndex =
                FindMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            CheckVk(vkAllocateMemory(mDevice, &mai, nullptr, &sv.depthMemories[k]),
                    "vkAllocateMemory(depth)");
            CheckVk(vkBindImageMemory(mDevice, sv.depthImages[k], sv.depthMemories[k], 0),
                    "vkBindImageMemory(depth)");
            sv.depthViews[k] = CreateView(sv.depthImages[k], mDepthFormat,
                                          VK_IMAGE_ASPECT_DEPTH_BIT);
        }

        sv.framebuffers.resize(imageCount);
        for (uint32_t k = 0; k < imageCount; ++k) {
            VkImageView fbViews[] = { sv.views[k], sv.depthViews[k] };
            VkFramebufferCreateInfo fci{ VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
            fci.renderPass = mRenderPass;
            fci.attachmentCount = 2;
            fci.pAttachments = fbViews;
            fci.width = sv.width;
            fci.height = sv.height;
            fci.layers = 1;
            CheckVk(vkCreateFramebuffer(mDevice, &fci, nullptr, &sv.framebuffers[k]),
                    "vkCreateFramebuffer");
        }
    }
}
