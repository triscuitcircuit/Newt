#include "Newt/VRMirrorWire.h"
#include <cassert>
#include <cstdio>
int main() {
    using namespace Newt::VRMirror;
    Header h;
    assert(!Valid(h));
    h.width = 1280; h.height = 1440; h.format = BGRA; h.eyeBytes = h.width * h.height * 4;
    assert(Valid(h));
    h.format = RGBA; assert(Valid(h));
    h.eyeBytes--; assert(!Valid(h)); h.eyeBytes++;
    h.magic = 0; assert(!Valid(h)); h.magic = Magic;
    h.version++; assert(!Valid(h)); h.version--;
    h.width = MaxDimension + 1; assert(!Valid(h));
    h.width = 0; assert(!Valid(h));
    puts("PASS: viewer frame format and bounds");
}
