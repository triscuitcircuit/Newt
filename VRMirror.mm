// SPDX-License-Identifier: MIT
#include "VRMirror.h"
#import <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <poll.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>

namespace {
std::string SocketPath() {
#ifdef NEWT_VR_MIRROR_TESTING
    if (const char* path = getenv("NEWT_VR_MIRROR_TEST_SOCKET")) return path;
#endif
    return "/tmp/pippin-vr-view-" + std::to_string(getuid()) + ".sock";
}
bool PeerIsUser(int fd) {
    uid_t uid = 0; gid_t gid = 0;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
}
bool Transfer(int fd, void* bytes, size_t length, bool write) {
    auto* data = static_cast<uint8_t*>(bytes);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (length) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        const ssize_t n = write ? send(fd, data, length, 0) : recv(fd, data, length, 0);
        if (n > 0) { data += n; length -= size_t(n); continue; }
        if (n < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}
void Timeout(int fd) {
    const timeval tv{0, 250000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    const int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
}
int Connect() {
    const std::string path = SocketPath();
    struct stat st{};
    if (lstat(path.c_str(), &st) || !S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    Timeout(fd);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) { close(fd); return -1; }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || !PeerIsUser(fd)) {
        close(fd); return -1;
    }
    return fd;
}

class Receiver {
public:
    ~Receiver() { Stop(); }
    bool Start() {
        if (listener >= 0) return true;
        const std::string path = SocketPath();
        struct stat st{};
        if (lstat(path.c_str(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return false;
            int existing = Connect();
            if (existing >= 0) { close(existing); return false; }
            if (unlink(path.c_str()) != 0) return false;
        } else if (errno != ENOENT) return false;
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return false;
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        if (path.size() >= sizeof(address.sun_path)) { close(fd); return false; }
        std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address))) { close(fd); return false; }
        if (chmod(path.c_str(), 0600) || listen(fd, 2)) { close(fd); unlink(path.c_str()); return false; }
        listener = fd;
        stopping = false;
        try {
            thread = std::thread([this] { Run(); });
        } catch (...) {
            close(listener); listener = -1;
            unlink(path.c_str());
            return false;
        }
        return true;
    }
    void Stop() {
        if (listener < 0) return;
        stopping = true;
        if (thread.joinable()) thread.join();
        close(listener); listener = -1;
        const std::string path = SocketPath();
        struct stat st{};
        if (!lstat(path.c_str(), &st) && S_ISSOCK(st.st_mode) && st.st_uid == getuid()) unlink(path.c_str());
        std::lock_guard<std::mutex> lock(mutex);
        pixels.clear(); sequence++;
    }
    CFDataRef Copy(uint64_t* last, uint32_t* width, uint32_t* height, uint32_t* format) {
        if (!last || !width || !height || !format) return nullptr;
        std::lock_guard<std::mutex> lock(mutex);
        if (*last == sequence || pixels.empty() || std::chrono::steady_clock::now() - received > std::chrono::seconds(2)) return nullptr;
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, pixels.data(), CFIndex(pixels.size()));
        if (!data) return nullptr;
        *last = sequence; *width = header.width; *height = header.height; *format = header.format;
        return data;
    }
private:
    void Run() {
        while (!stopping) {
            pollfd p{listener, POLLIN, 0};
            if (poll(&p, 1, 200) <= 0 || !(p.revents & POLLIN)) continue;
            int fd = accept(listener, nullptr, nullptr);
            if (fd < 0) continue;
            Timeout(fd);
            Newt::VRMirror::Header h{};
            if (PeerIsUser(fd) && Transfer(fd, &h, sizeof(h), false) && Newt::VRMirror::Valid(h)) {
                try {
                    std::vector<uint8_t> incoming(size_t(h.eyeBytes) * 2);
                    if (Transfer(fd, incoming.data(), incoming.size(), false)) {
                        std::lock_guard<std::mutex> lock(mutex);
                        header = h; pixels = std::move(incoming); received = std::chrono::steady_clock::now(); sequence++;
                    }
                } catch (...) {}
            }
            close(fd);
        }
    }
    int listener = -1;
    std::atomic<bool> stopping{false};
    std::thread thread;
    std::mutex mutex;
    Newt::VRMirror::Header header{};
    std::vector<uint8_t> pixels;
    uint64_t sequence = 0;
    std::chrono::steady_clock::time_point received{};
};
Receiver receiver;
}

namespace Newt {
VRMirrorProducer::VRMirrorProducer() : worker([this] { Worker(); }) {}
VRMirrorProducer::~VRMirrorProducer() {
    { std::lock_guard<std::mutex> lock(mutex); stop = true; pending.reset(); }
    ready.notify_one();
    if (worker.joinable()) worker.join();
}
bool VRMirrorProducer::ViewerReady() {
    const auto now = std::chrono::steady_clock::now();
    if (now - lastProbe >= std::chrono::milliseconds(250)) {
        struct stat st{}; const std::string path = SocketPath();
        viewer = !lstat(path.c_str(), &st) && S_ISSOCK(st.st_mode) && st.st_uid == getuid();
        lastProbe = now;
    }
    if (!viewer || now - lastCapture < std::chrono::milliseconds(100)) return false;
    std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
    if (!lock || busy || pending) return false;
    lastCapture = now;
    return true;
}
void VRMirrorProducer::Eye(uint32_t eye, uint64_t frame, uint32_t width, uint32_t height,
                           uint32_t format, const void* pixels) {
    VRMirror::Header h; h.width = width; h.height = height; h.format = format;
    if (width > VRMirror::MaxDimension || height > VRMirror::MaxDimension) return;
    h.eyeBytes = width * height * 4; h.frame = frame;
    if (!pixels || !VRMirror::Valid(h) || eye > 1) return;
    if (eye == 0) {
        eyes[0].assign(static_cast<const uint8_t*>(pixels), static_cast<const uint8_t*>(pixels) + h.eyeBytes);
        leftFrame = frame; leftWidth = width; leftHeight = height; leftFormat = format;
    } else if (leftFrame == frame && leftWidth == width && leftHeight == height && leftFormat == format) {
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock || busy || pending) return;
        auto pair = std::make_unique<Pair>(); pair->header = h;
        pair->bytes.reserve(size_t(h.eyeBytes) * 2);
        pair->bytes.insert(pair->bytes.end(), eyes[0].begin(), eyes[0].end());
        pair->bytes.insert(pair->bytes.end(), static_cast<const uint8_t*>(pixels), static_cast<const uint8_t*>(pixels) + h.eyeBytes);
        pending = std::move(pair); ready.notify_one();
    }
}
void VRMirrorProducer::Worker() {
    for (;;) {
        std::unique_ptr<Pair> pair;
        {
            std::unique_lock<std::mutex> lock(mutex);
            ready.wait(lock, [&] { return stop || pending; });
            if (stop) return;
            pair = std::move(pending); busy = true;
        }
        const int fd = Connect();
        if (fd >= 0) {
            if (Transfer(fd, &pair->header, sizeof(pair->header), true))
                Transfer(fd, pair->bytes.data(), pair->bytes.size(), true);
            close(fd);
        }
        { std::lock_guard<std::mutex> lock(mutex); busy = false; }
    }
}
}

extern "C" bool Newt_VRMirrorStart(void) { return receiver.Start(); }
extern "C" void Newt_VRMirrorStop(void) { receiver.Stop(); }
extern "C" CFDataRef Newt_VRMirrorCopy(uint64_t* sequence, uint32_t* width, uint32_t* height, uint32_t* format) {
    return receiver.Copy(sequence, width, height, format);
}
