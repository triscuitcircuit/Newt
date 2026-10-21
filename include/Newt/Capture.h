#ifndef NEWT_CAPTURE_H
#define NEWT_CAPTURE_H

#include "Newt/DrawHelpers.h"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <memory>

void SetMediaVolume(float volume);
uint32_t LiveWidth();
uint32_t LiveHeight();
void SetLiveResolution(uint32_t width);


struct RetainedObjectDeleter { void operator()(void* object) const noexcept; };
using RetainedObject = std::unique_ptr<void, RetainedObjectDeleter>;

class FrameSource {
public:
    virtual ~FrameSource() = default;
    virtual void Stop() = 0;
    virtual void SetFPS(uint32_t fps) = 0;
    virtual bool GetLatestFrame(uint64_t& sequence, PixelImage& image) = 0;
};

class ScreenCaptureManager final : public FrameSource {
public:
    ScreenCaptureManager();
    ~ScreenCaptureManager() override;

    void Start(uint32_t displayIndex = 0, uint32_t fps = 30);
    void Stop() override;
    void SetDisplayID(uint32_t displayID) { mDisplayID = displayID; }
    uint32_t DisplayID() const { return mDisplayID; }
    uint32_t FPS() const { return mFPS; }
    void SetFPS(uint32_t fps) override;


    bool GetLatestFrame(uint64_t& lastSeq, PixelImage& outImage) override;

    bool GetLatestPixelBuffer(uint64_t& lastSeq, RetainedObject& pixels, std::string& label);

    void PublishCVPixelBuffer(void* cvPixelBuffer, const std::string& label);
    void TickFallback();

private:
    std::mutex mMutex;
    PixelImage mLatestFrame;
    RetainedObject mLatestBuffer;
    std::string mLatestLabel;
    std::atomic<uint64_t> mFrameSeq{0};
    std::atomic<uint64_t> mLastSCStreamTimeMs{0};
    std::atomic<bool> mRunning{false};
    std::atomic<uint32_t> mDisplayIndex{0};
    uint32_t mDisplayID = 0;
    uint32_t mFPS = 30;
    RetainedObject mImpl;
};

class MediaCaptureManager final : public FrameSource {
public:
    MediaCaptureManager();
    ~MediaCaptureManager() override;

    void Start();
    void SetVideoPath(const std::string& path) { mVideoPath = path; }
    const std::string& VideoPath() const { return mVideoPath; }
    void StartCamera(uint32_t cameraIndex, uint32_t fps = 30);
    void SetFPS(uint32_t fps) override;
    uint32_t FPS() const { return mFPS.load(); }
    uint32_t CameraIndex() const { return mCameraIndex; }
    void SetCameraID(const std::string& id) { mCameraID = id; }
    const std::string& CameraID() const { return mCameraID; }
    void Stop() override;

    bool GetLatestFrame(uint64_t& lastSeq, PixelImage& outImage) override;

    void PublishCVPixelBuffer(void* cvPixelBuffer, const std::string& badge);
    void PublishImage(PixelImage&& img);

private:
    std::mutex mMutex;
    PixelImage mLatestFrame;
    std::atomic<uint64_t> mFrameSeq{0};
    std::atomic<bool> mRunning{false};
    std::atomic<uint32_t> mFPS{30};
    uint32_t mCameraIndex = 0;
    std::string mCameraID;
    std::string mVideoPath;
    std::atomic<uint64_t> mLastPublishMs{0};
    RetainedObject mImpl;
};

#endif // NEWT_CAPTURE_H
