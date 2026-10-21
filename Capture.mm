#include "Newt/CaptureInternal.h"
static std::atomic<float> gMediaVolume{0.7f};
void SetMediaVolume(float v) { gMediaVolume.store(std::max(0.0f,std::min(1.0f,v))); }

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>

static std::atomic<uint32_t> liveWidth{1024};
uint32_t LiveWidth() { return liveWidth.load(); }
uint32_t LiveHeight() { return LiveWidth() * 5 / 8; }
void SetLiveResolution(uint32_t width) { liveWidth = width; }

namespace NewtCaptureInternal {

uint64_t NowMs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

PixelImage PixelImageFromCVPixelBuffer(CVPixelBufferRef pb, const std::string& badgeText) {
    PixelImage out;
    out.width = LiveWidth();
    out.height = out.width * 5 / 8;
    out.pixels.assign(static_cast<size_t>(out.width) * out.height * 4, 0);

    if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) return out;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const size_t srcW = CVPixelBufferGetWidth(pb);
    const size_t srcH = CVPixelBufferGetHeight(pb);
    const size_t srcStride = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t* srcBase = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pb));

    if (srcBase && srcW == out.width && srcH == out.height) {
        for (uint32_t row = 0; row < out.height; ++row)
            std::memcpy(out.pixels.data() + static_cast<size_t>(row) * out.width * 4,
                        srcBase + static_cast<size_t>(row) * srcStride, out.width * 4);
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return out;
    }
    if (srcBase && srcW > 0 && srcH > 0) {
        @autoreleasepool {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGDataProviderRef provider =
                CGDataProviderCreateWithData(nullptr, srcBase, srcStride * srcH, nullptr);
            CGImageRef cgImg = CGImageCreate(
                srcW, srcH, 8, 32, srcStride, cs,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                provider, nullptr, true, kCGRenderingIntentDefault);

            CGContextRef ctx = CGBitmapContextCreate(
                out.pixels.data(), out.width, out.height, 8, out.width * 4, cs,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

            // Fill dark background.
            CGContextSetRGBFillColor(ctx, 0.04, 0.05, 0.065, 1.0);
            CGContextFillRect(ctx, CGRectMake(0, 0, out.width, out.height));

            if (cgImg) {

                const double scaleX = static_cast<double>(out.width) / static_cast<double>(srcW);
                const double scaleY = static_cast<double>(out.height) / static_cast<double>(srcH);
                const double scale = std::min(scaleX, scaleY);
                const double drawW = srcW * scale;
                const double drawH = srcH * scale;
                const double drawX = (out.width - drawW) * 0.5;
                const double drawY = (out.height - drawH) * 0.5;
                CGContextDrawImage(ctx, CGRectMake(drawX, drawY, drawW, drawH), cgImg);
                CGImageRelease(cgImg);
            }
            CGDataProviderRelease(provider);

            if (!badgeText.empty()) {
                CGContextTranslateCTM(ctx, 0.0, out.height);
                CGContextScaleCTM(ctx, 1.0, -1.0);
                NSGraphicsContext* gc =
                    [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:gc];
                NSString* badge = [NSString stringWithUTF8String:badgeText.c_str()];
                FillRounded(NSMakeRect(24, 18, 460, 38), 10, RGB(0.05f, 0.07f, 0.09f, 0.78f));
                DrawText(badge, NSMakeRect(38, 24, 432, 26), 18, YES,
                         RGB(0.48f, 0.88f, 0.78f));
                [NSGraphicsContext restoreGraphicsState];
            }

            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return out;
}

} // namespace


float NewtCaptureInternal::MediaVolume() { return gMediaVolume.load(); }
void RetainedObjectDeleter::operator()(void* object) const noexcept { if (object) CFRelease(object); }
