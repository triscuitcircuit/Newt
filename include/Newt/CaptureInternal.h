#ifndef NEWT_CAPTURE_INTERNAL_H
#define NEWT_CAPTURE_INTERNAL_H
#include "Capture.h"
#import <CoreVideo/CoreVideo.h>
namespace NewtCaptureInternal {
uint64_t NowMs();
PixelImage PixelImageFromCVPixelBuffer(CVPixelBufferRef buffer, const std::string& badge);
float MediaVolume();
}
#endif
