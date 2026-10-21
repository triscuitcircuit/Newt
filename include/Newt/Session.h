#ifndef NEWT_SESSION_H
#define NEWT_SESSION_H
#ifndef XR_USE_GRAPHICS_API_VULKAN
#define XR_USE_GRAPHICS_API_VULKAN
#endif
#include "MathTypes.h"
#include "Newt/PixelImage.h"
#include <CoreVideo/CoreVideo.h>
#include <array>
#include <atomic>
#include <functional>
#include <memory>
struct Buffer {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize size = 0;
};

struct Texture {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkDescriptorSet descriptor = VK_NULL_HANDLE;
    VkBuffer stagingBuffer = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    void* stagingMapped = nullptr;
    VkDeviceSize stagingSize = 0;
    uint32_t width = kTextureWidth, height = kTextureHeight;
    bool initialized = false;
    bool laidOut = false;
};

struct SwapchainView {
    XrSwapchain swapchain = XR_NULL_HANDLE;
    uint32_t width = 0, height = 0;
    std::vector<VkImage> images;
    std::vector<VkImageView> views;
    std::vector<VkImage> depthImages;
    std::vector<VkDeviceMemory> depthMemories;
    std::vector<VkImageView> depthViews;
    std::vector<VkFramebuffer> framebuffers;
};


namespace Newt {
struct GPUTextureData;

using GPUTexture = std::shared_ptr<GPUTextureData>;
struct TextureRegion {
    Vec4 source{0, 0, 1, 1};
    Vec4 destination{0, 0, 1, 1};
};

struct InputState {
    XrTime displayTime = 0;
    XrPosef viewer = IdentityPose();
    bool viewerValid = false;
    std::array<XrPosef,2> aim{}, grip{};
    std::array<bool,2> aimValid{}, gripValid{}, select{}, menu{};
    std::array<XrActionStateFloat,2> grab{};
    std::array<XrActionStateVector2f,2> stick{};
};
struct EyeFrame {
    VkCommandBuffer command;
    Mat4 viewProjection;
    XrView view;
    uint32_t index, width, height;
};
class Session;
class SessionDelegate {
public:
    virtual ~SessionDelegate() = default;
    virtual void OnSystem(const XrSystemProperties&) {}
    virtual void OnReady(Session&) {}
    virtual bool OnTick(Session&) { return true; }
    virtual void OnInput(const InputState&) {}
    virtual void OnPrepareFrame(const XrFrameState&) {}
    virtual void OnDrawEye(const EyeFrame&) {}
    virtual void OnSessionState(XrSessionState) {}

    virtual void OnStopping(Session&) noexcept {}
};
class Session final {
public:
    Session() = default;
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    void Run(SessionDelegate& delegate);
    void RequestStop() noexcept { mStop.store(true); }
    bool Running() const noexcept { return mSessionRunning; }

    void PulseHaptic(int hand, float amplitude = 0.3f);
    VkDevice Device() const noexcept { return mDevice; }
    void BeginUploads() { mBatchUploads = true; }
    void FlushUploads();
    uint32_t FindMemoryType(uint32_t typeBits, VkMemoryPropertyFlags props);
    Buffer CreateBuffer(VkDeviceSize size, VkBufferUsageFlags usage);
    void UploadBuffer(Buffer& buffer, const void* data, VkDeviceSize size);
    void DestroyBuffer(Buffer& buffer);
    VkImageView CreateView(VkImage image, VkFormat format, VkImageAspectFlags aspect);
    void CreateTexture(Texture& tex, uint32_t width = kTextureWidth, uint32_t height = kTextureHeight);
    void UpdateTexture(Texture& tex, const PixelImage& image);

    GPUTexture ImportPixelBuffer(CVPixelBufferRef pixels);
    void DrawGPUTexture(VkCommandBuffer cmd, const Mat4& viewProj, const Mat4& model,
                        const GPUTexture& texture, const TextureRegion& region = {},
                        const Buffer* mesh = nullptr, uint32_t vertexCount = 6);
    void DestroyTexture(Texture& tex);
    VkShaderModule CreateShader(const unsigned char* data, unsigned int len);
    void DrawColor(VkCommandBuffer cmd, const Mat4& viewProj, const Mat4& model,
                   const Buffer& buffer, uint32_t count, const Vec4& color, bool lines);
    void DrawTextured(VkCommandBuffer cmd, const Mat4& viewProj, const Mat4& model,
                      const Texture& tex, const Buffer* mesh = nullptr, uint32_t vertexCount = 6);

private:
    friend struct SessionGPUProbe;
    void CreateInstanceAndSystem();
    void CreateVulkanAndSession();
    void CreateReferenceSpace();
    void CreateSwapchains();
    void CreateRenderAssets();
    void CreatePipelines();
    void CreateActions();
    bool PollEvents();
    bool LocatePose(XrSpace space, XrTime time, XrPosef& pose);
    InputState ReadInput(XrTime time);
    bool RenderFrame(const XrFrameState& frameState);
    void Cleanup() noexcept;
    void PrepareGPUTextures(VkCommandBuffer command);
    void CleanupGPUTextures() noexcept;
    std::vector<std::weak_ptr<GPUTextureData>> mGPUTextures;
    std::vector<GPUTexture> mPendingGPUTextures;
    std::array<std::vector<GPUTexture>, 2> mSampledGPUTextures;
    size_t mDrawingSlot = 0;
    SessionDelegate* mDelegate = nullptr; // borrowed only during Run
    std::atomic_bool mStop{false};
    bool mActive = false;
    Buffer mQuadBuffer;
    XrInstance mInstance = XR_NULL_HANDLE;
    XrSystemId mSystemId = XR_NULL_SYSTEM_ID;
    XrSession mSession = XR_NULL_HANDLE;
    XrSpace mAppSpace = XR_NULL_HANDLE;
    XrSessionState mSessionState = XR_SESSION_STATE_UNKNOWN;
    bool mSessionRunning = false;
    XrViewConfigurationType mViewType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    std::vector<XrViewConfigurationView> mViewConfigs;

    PFN_xrGetVulkanGraphicsRequirements2KHR mGetRequirements2 = nullptr;
    PFN_xrCreateVulkanInstanceKHR mCreateVkInstance = nullptr;
    PFN_xrGetVulkanGraphicsDevice2KHR mGetVkDevice2 = nullptr;
    PFN_xrCreateVulkanDeviceKHR mCreateVkDevice = nullptr;

    VkInstance mVkInstance = VK_NULL_HANDLE;
    VkPhysicalDevice mPhysicalDevice = VK_NULL_HANDLE;
    VkDevice mDevice = VK_NULL_HANDLE;
    VkQueue mQueue = VK_NULL_HANDLE;
    bool mBatchUploads = false;
    std::vector<std::function<void(VkCommandBuffer)>> mUploads;
    uint32_t mQueueFamily = 0;
    VkFormat mColorFormat = VK_FORMAT_B8G8R8A8_SRGB;
    VkFormat mDepthFormat = VK_FORMAT_D32_SFLOAT;
    VkRenderPass mRenderPass = VK_NULL_HANDLE;
    VkCommandPool mCommandPool = VK_NULL_HANDLE;
    std::array<VkCommandBuffer, 2> mCommandBuffers{VK_NULL_HANDLE, VK_NULL_HANDLE};
    std::array<VkFence, 2> mFences{VK_NULL_HANDLE, VK_NULL_HANDLE};
    std::vector<SwapchainView> mSwapchains;

    VkDescriptorSetLayout mTextureLayout = VK_NULL_HANDLE;
    VkDescriptorPool mDescriptorPool = VK_NULL_HANDLE;
    VkSampler mSampler = VK_NULL_HANDLE;
    VkPipelineLayout mColorLayout = VK_NULL_HANDLE;
    VkPipelineLayout mTexturePipelineLayout = VK_NULL_HANDLE;
    VkPipeline mColorPipeline = VK_NULL_HANDLE;
    VkPipeline mLinePipeline = VK_NULL_HANDLE;
    VkPipeline mTexturePipeline = VK_NULL_HANDLE;

    XrActionSet mActionSet = XR_NULL_HANDLE;
    XrAction mAimAction = XR_NULL_HANDLE, mGrabAction = XR_NULL_HANDLE, mGripAction = XR_NULL_HANDLE;
    XrAction mSelectAction = XR_NULL_HANDLE, mMenuAction = XR_NULL_HANDLE, mThumbstickAction = XR_NULL_HANDLE;
    XrAction mHapticAction = XR_NULL_HANDLE;
    std::array<XrPath, 2> mHandPaths{};
    std::array<XrSpace, 2> mAimSpaces{}, mGripSpaces{};
};
} // namespace Newt
#endif
