#include <NewtLog.h>
#ifdef NEWT_TEST_USB
#include <NewtUSB.h>
#endif
int main() {
    // Exercise installed symbols without initializing XR or USB hardware.
    Newt_SetLogHandler(nullptr, nullptr);
    Newt_SetLogLevel(NEWT_LOG_INFO);
#ifdef NEWT_TEST_USB
    NewtUSB_Close(nullptr);
#endif
}
