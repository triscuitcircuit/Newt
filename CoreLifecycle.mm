#include "Newt/Session.h"
#include "CoreInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <cstring>
#include <thread>
#include <chrono>
using namespace NewtInternal;
using Newt::Session;

Session::~Session() { Cleanup(); }
void Session::Run(Newt::SessionDelegate& delegate) {
    if(mActive) throw std::logic_error("Session::Run is already active");
    mActive=true; mDelegate=&delegate; mStop.store(false);
    try {
        CreateInstanceAndSystem(); CreateVulkanAndSession(); CreateReferenceSpace();
        CreateSwapchains(); CreateRenderAssets(); CreatePipelines(); CreateActions();
        delegate.OnReady(*this);
        uint64_t frameCount = 0;
        std::array<double, 4> stageMs{};
        auto fpsStart = std::chrono::steady_clock::now();
        while(!mStop.load()) {
            if(PollEvents() || !delegate.OnTick(*this)) break;
            if(!mSessionRunning) { std::this_thread::sleep_for(std::chrono::milliseconds(100)); continue; }
            XrFrameState frame{XR_TYPE_FRAME_STATE};
            auto start = std::chrono::steady_clock::now();
            CheckXr(xrWaitFrame(mSession,nullptr,&frame),"xrWaitFrame");
            auto waited = std::chrono::steady_clock::now();
            delegate.OnInput(ReadInput(frame.predictedDisplayTime));
            auto inputDone = std::chrono::steady_clock::now();
            delegate.OnPrepareFrame(frame);
            auto prepared = std::chrono::steady_clock::now();
            const bool rendered = RenderFrame(frame);
            auto submitted = std::chrono::steady_clock::now();
            const auto ms = [](auto duration) { return std::chrono::duration<double, std::milli>(duration).count(); };
            stageMs[0] += ms(waited-start); stageMs[1] += ms(inputDone-waited);
            stageMs[2] += ms(prepared-inputDone); stageMs[3] += ms(submitted-prepared);
            if (++frameCount % 90 == 0) {
                const auto now = std::chrono::steady_clock::now();
                const double seconds = std::chrono::duration<double>(now - fpsStart).count();
                Newt_Logf(NEWT_LOG_DEBUG,
                          "rendered %llu frames (%.4f fps, runtime shouldRender=%d, submitted=%d)",
                          static_cast<unsigned long long>(frameCount),
                          90.0 / (seconds > 0 ? seconds : 1),
                          static_cast<int>(frame.shouldRender), static_cast<int>(rendered));
                Newt_Logf(NEWT_LOG_DEBUG, "frame stages avg ms: wait=%.2f input=%.2f prepare=%.2f render=%.2f period=%.2f",
                          stageMs[0]/90, stageMs[1]/90, stageMs[2]/90, stageMs[3]/90,
                          double(frame.predictedDisplayPeriod)/1e6);
                stageMs = {};
                fpsStart = now;
            }
        }
        if(mSessionRunning) {
            CheckXr(xrRequestExitSession(mSession),"xrRequestExitSession");
            auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
            while(mSessionRunning && std::chrono::steady_clock::now()<deadline) {
                if(PollEvents()) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
        }
    } catch(...) {
        if(mDevice) vkDeviceWaitIdle(mDevice);
        delegate.OnStopping(*this); Cleanup(); mDelegate=nullptr; mActive=false;
        throw;
    }
    if(mDevice) vkDeviceWaitIdle(mDevice);
    delegate.OnStopping(*this); Cleanup(); mDelegate=nullptr; mActive=false;
}
void Session::FlushUploads() {
    mBatchUploads=false;
    if(mUploads.empty()) return;
    ImmediateSubmit(mDevice,mQueue,mCommandPool,[&](VkCommandBuffer command) {
        for(auto& upload:mUploads) upload(command);
    });
    mUploads.clear();
}
void Session::Cleanup() noexcept {
    if(mDevice) vkDeviceWaitIdle(mDevice);
    mUploads.clear(); mBatchUploads=false;
    CleanupGPUTextures();
    DestroyBuffer(mQuadBuffer);
    if (mColorPipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(mDevice, mColorPipeline, nullptr);
        mColorPipeline = VK_NULL_HANDLE;
    }
    if (mLinePipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(mDevice, mLinePipeline, nullptr);
        mLinePipeline = VK_NULL_HANDLE;
    }
    if (mTexturePipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(mDevice, mTexturePipeline, nullptr);
        mTexturePipeline = VK_NULL_HANDLE;
    }
    if (mColorLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(mDevice, mColorLayout, nullptr);
        mColorLayout = VK_NULL_HANDLE;
    }
    if (mTexturePipelineLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(mDevice, mTexturePipelineLayout, nullptr);
        mTexturePipelineLayout = VK_NULL_HANDLE;
    }
    if (mDescriptorPool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(mDevice, mDescriptorPool, nullptr);
        mDescriptorPool = VK_NULL_HANDLE;
    }
    if (mTextureLayout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(mDevice, mTextureLayout, nullptr);
        mTextureLayout = VK_NULL_HANDLE;
    }
    if (mSampler != VK_NULL_HANDLE) {
        vkDestroySampler(mDevice, mSampler, nullptr);
        mSampler = VK_NULL_HANDLE;
    }
    for (auto& sv : mSwapchains) {
        for (VkFramebuffer fb : sv.framebuffers) vkDestroyFramebuffer(mDevice, fb, nullptr);
        for (VkImageView v : sv.views) vkDestroyImageView(mDevice, v, nullptr);
        for (VkImageView v : sv.depthViews) vkDestroyImageView(mDevice, v, nullptr);
        for (VkImage img : sv.depthImages) vkDestroyImage(mDevice, img, nullptr);
        for (VkDeviceMemory mem : sv.depthMemories) vkFreeMemory(mDevice, mem, nullptr);
        if (sv.swapchain != XR_NULL_HANDLE) xrDestroySwapchain(sv.swapchain);
    }
    mSwapchains.clear();
    if (mRenderPass) vkDestroyRenderPass(mDevice,mRenderPass,nullptr);
    mRenderPass=VK_NULL_HANDLE;
    for (VkFence& fence : mFences) {
        if (fence != VK_NULL_HANDLE) {
            vkDestroyFence(mDevice, fence, nullptr);
            fence = VK_NULL_HANDLE;
        }
    }
    mCommandBuffers = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    if (mCommandPool != VK_NULL_HANDLE) {
        vkDestroyCommandPool(mDevice, mCommandPool, nullptr);
        mCommandPool = VK_NULL_HANDLE;
    }

    for (XrSpace s : mAimSpaces) {
        if (s != XR_NULL_HANDLE) xrDestroySpace(s);
    }
    for (XrSpace s : mGripSpaces) {
        if (s != XR_NULL_HANDLE) xrDestroySpace(s);
    }
    mAimSpaces = {};
    mGripSpaces = {};
    const XrAction actions[] = { mAimAction, mGrabAction, mGripAction, mSelectAction, mMenuAction,
                                mThumbstickAction, mHapticAction };
    for (XrAction a : actions) {
        if (a != XR_NULL_HANDLE) xrDestroyAction(a);
    }
    mAimAction = mGrabAction = mGripAction = mSelectAction = mMenuAction = mThumbstickAction = mHapticAction = XR_NULL_HANDLE;
    if (mActionSet != XR_NULL_HANDLE) {
        xrDestroyActionSet(mActionSet);
        mActionSet = XR_NULL_HANDLE;
    }
    if (mAppSpace != XR_NULL_HANDLE) {
        xrDestroySpace(mAppSpace);
        mAppSpace = XR_NULL_HANDLE;
    }
    if (mSession != XR_NULL_HANDLE) {
        xrDestroySession(mSession);
        mSession = XR_NULL_HANDLE;
    }
    mSessionRunning = false;
    mSessionState = XR_SESSION_STATE_UNKNOWN;
    mSystemId = XR_NULL_SYSTEM_ID;
    mViewConfigs.clear();
    mHandPaths = {};
    if (mInstance != XR_NULL_HANDLE) {
        xrDestroyInstance(mInstance);
        mInstance = XR_NULL_HANDLE;
    }
    if (mDevice != VK_NULL_HANDLE) {
        vkDestroyDevice(mDevice, nullptr);
        mDevice = VK_NULL_HANDLE;
    }
    if (mVkInstance != VK_NULL_HANDLE) {
        vkDestroyInstance(mVkInstance, nullptr);
        mVkInstance = VK_NULL_HANDLE;
    }
    mQueue = VK_NULL_HANDLE;
    mPhysicalDevice = VK_NULL_HANDLE;
}
