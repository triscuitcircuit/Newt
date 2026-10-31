// SPDX-License-Identifier: MIT
#include "../VRMirror.h"
#import <CoreFoundation/CoreFoundation.h>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <thread>
#include <unistd.h>
#include <sys/wait.h>

extern "C" bool Newt_VRMirrorStart(void);
extern "C" void Newt_VRMirrorStop(void);
extern "C" CFDataRef Newt_VRMirrorCopy(uint64_t*, uint32_t*, uint32_t*, uint32_t*);

int main() {
    const std::string path = "/tmp/pippin-vr-mirror-test-" + std::to_string(getpid()) + ".sock";
    setenv("NEWT_VR_MIRROR_TEST_SOCKET", path.c_str(), 1);
    int signalPipe[2];
    assert(pipe(signalPipe) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(signalPipe[1]);
        char signal;
        if (read(signalPipe[0], &signal, 1) != 1) _exit(1);
        {
            Newt::VRMirrorProducer producer;
            std::vector<uint8_t> eye(64 * 48 * 4, 83);
            producer.Eye(0, 7, 64, 48, Newt::VRMirror::BGRA, eye.data());
            producer.Eye(1, 7, 64, 48, Newt::VRMirror::BGRA, eye.data());
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
        _exit(0);
    }
    close(signalPipe[0]);
    assert(Newt_VRMirrorStart());
    assert(write(signalPipe[1], "x", 1) == 1);
    close(signalPipe[1]);
    uint64_t childSequence = 0;
    uint32_t childWidth = 0, childHeight = 0, childFormat = 0;
    CFDataRef childFrame = nullptr;
    for (int i = 0; i < 100 && !childFrame; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        childFrame = Newt_VRMirrorCopy(&childSequence, &childWidth, &childHeight, &childFormat);
    }
    assert(childFrame && childWidth == 64 && childHeight == 48 && CFDataGetBytePtr(childFrame)[0] == 83);
    CFRelease(childFrame);
    int childStatus = 0;
    assert(waitpid(child, &childStatus, 0) == child && WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0);
    Newt_VRMirrorStop();
    assert(Newt_VRMirrorStart());
    Newt::VRMirrorProducer producer;
    assert(producer.ViewerReady());
    constexpr uint32_t width = 64, height = 48, bytes = width * height * 4;
    std::vector<uint8_t> left(bytes, 17), right(bytes, 239);
    producer.Eye(0, 42, width, height, Newt::VRMirror::BGRA, left.data());
    producer.Eye(1, 41, width, height, Newt::VRMirror::BGRA, right.data());
    uint64_t sequence = 0;
    uint32_t receivedWidth = 0, receivedHeight = 0, format = 0;
    assert(!Newt_VRMirrorCopy(&sequence, &receivedWidth, &receivedHeight, &format));
    producer.Eye(1, 42, width, height, Newt::VRMirror::BGRA, right.data());
    CFDataRef frame = nullptr;
    for (int i = 0; i < 100 && !frame; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        frame = Newt_VRMirrorCopy(&sequence, &receivedWidth, &receivedHeight, &format);
    }
    assert(frame && receivedWidth == width && receivedHeight == height && format == Newt::VRMirror::BGRA);
    assert(CFDataGetLength(frame) == bytes * 2);
    const UInt8* pixels = CFDataGetBytePtr(frame);
    assert(pixels[0] == 17 && pixels[bytes - 1] == 17 && pixels[bytes] == 239 && pixels[bytes * 2 - 1] == 239);
    CFRelease(frame);
    assert(!Newt_VRMirrorCopy(&sequence, &receivedWidth, &receivedHeight, &format));
    std::this_thread::sleep_for(std::chrono::milliseconds(2100));
    sequence = 0;
    assert(!Newt_VRMirrorCopy(&sequence, &receivedWidth, &receivedHeight, &format));
    Newt_VRMirrorStop();
    assert(access(path.c_str(), F_OK) != 0);
    assert(Newt_VRMirrorStart());
    Newt_VRMirrorStop();
    puts("PASS: paired-eye transport, matching, stale-frame rejection and receiver lifecycle");
}
