#include <Newt/Session.h>
#include <cassert>
#include <stdexcept>
#include <type_traits>

struct Delegate final : Newt::SessionDelegate {
    int ready = 0, stopping = 0;
    void OnReady(Newt::Session&) override { ++ready; }
    void OnStopping(Newt::Session& session) noexcept override {
        ++stopping;
        assert(!session.Running());
    }
};

int main() {
    static_assert(!std::is_copy_constructible_v<Newt::Session>);
    Newt::Session session;
    Delegate delegate;
    // CTest forces a nonexistent runtime: exercise cleanup after failed setup,
    // then reuse the same object. No headset, GPU or capture permission needed.
    for (int attempt = 1; attempt <= 2; ++attempt) {
        bool failed = false;
        try { session.Run(delegate); }
        catch (const std::runtime_error&) { failed = true; }
        assert(failed);
        assert(delegate.ready == 0);
        assert(delegate.stopping == attempt);
        assert(session.Device() == VK_NULL_HANDLE);
        assert(!session.Running());
    }
}
