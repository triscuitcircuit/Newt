#pragma once
// SPDX-License-Identifier: MIT
#include "Newt/VRMirrorWire.h"
#include <array>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace Newt {
class VRMirrorProducer {
public:
    VRMirrorProducer();
    ~VRMirrorProducer();
    bool ViewerReady();
    void Eye(uint32_t eye, uint64_t frame, uint32_t width, uint32_t height,
             uint32_t format, const void* pixels);
private:
    struct Pair { VRMirror::Header header; std::vector<uint8_t> bytes; };
    void Worker();
    std::mutex mutex;
    std::condition_variable ready;
    bool stop = false, busy = false;
    std::unique_ptr<Pair> pending;
    std::array<std::vector<uint8_t>, 2> eyes;
    uint64_t leftFrame = 0;
    uint32_t leftWidth = 0, leftHeight = 0, leftFormat = 0;
    std::chrono::steady_clock::time_point lastProbe{}, lastCapture{};
    bool viewer = false;
    std::thread worker;
};
}
