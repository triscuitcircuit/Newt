// SPDX-License-Identifier: MIT
#include "NewtUSB.h"
#include <cstdio>
int main() {
    int result=NewtUSB_Enumerate([](const NewtUSBInfo* info, void*) {
        std::printf("%04x:%04x bus=%u address=%u\n", info->vendor_id, info->product_id,info->bus,info->address);
    },nullptr);
    if(result<0) std::fprintf(stderr,"USB: %s\n",NewtUSB_ErrorName(result));
    return result<0?1:0;
}
