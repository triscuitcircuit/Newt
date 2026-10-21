// SPDX-License-Identifier: MIT
#include "include/NewtLog.h"
#include <cstdarg>
#include <cstdio>
#include <mutex>

namespace {
std::mutex gLogMutex;
NewtLogHandler gHandler = nullptr;
void* gHandlerUser = nullptr;
int gMinimumLevel = NEWT_LOG_DEBUG;
} // namespace

namespace NewtInternal {
bool HasLogHandler() {
    std::lock_guard<std::mutex> guard(gLogMutex);
    return gHandler != nullptr;
}
} // namespace NewtInternal

extern "C" int Newt_IsEmbedded(void) {
    return NewtInternal::HasLogHandler() ? 1 : 0;
}

extern "C" void Newt_SetLogHandler(NewtLogHandler handler, void* user) {
    std::lock_guard<std::mutex> guard(gLogMutex);
    gHandler = handler;
    gHandlerUser = user;
}

extern "C" void Newt_SetLogLevel(int minimumLevel) {
    std::lock_guard<std::mutex> guard(gLogMutex);
    gMinimumLevel = minimumLevel;
}

extern "C" void Newt_Logf(int level, const char* format, ...) {
    if (!format) return;
    char buffer[2048];
    va_list args;
    va_start(args, format);
    std::vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    std::lock_guard<std::mutex> guard(gLogMutex);
    if (level < gMinimumLevel) return;
    if (gHandler) {
        gHandler(gHandlerUser, level, buffer);
    } else {
        std::FILE* out = level >= NEWT_LOG_ERROR ? stderr : stdout;
        std::fprintf(out, "NewtXR: %s\n", buffer);
        std::fflush(out);
    }
}
