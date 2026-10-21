#ifndef NEWT_NEWTUSB_H
#define NEWT_NEWTUSB_H
// SPDX-License-Identifier: MIT
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct NewtUSBDevice NewtUSBDevice;
typedef struct NewtUSBInfo {
    uint16_t vendor_id, product_id;
    uint8_t bus, address;
} NewtUSBInfo;

typedef void (*NewtUSBVisitor)(const NewtUSBInfo* info, void* userdata);
int NewtUSB_Enumerate(NewtUSBVisitor visitor, void* userdata);

int NewtUSB_Open(const NewtUSBInfo* info, int interface_number, NewtUSBDevice** out);
void NewtUSB_Close(NewtUSBDevice* device);

int NewtUSB_Bulk(NewtUSBDevice* device, uint8_t endpoint, unsigned char* data,
                 int length, int* transferred, unsigned int timeout_ms);
const char* NewtUSB_ErrorName(int error);
#ifdef __cplusplus
}
#endif

#endif // NEWT_NEWTUSB_H
