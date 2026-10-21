// SPDX-License-Identifier: MIT
#include "NewtUSB.h"
#include <libusb.h>
#include <new>
#include <memory>
struct NewtUSBDevice {
    libusb_context* context = nullptr;
    libusb_device_handle* handle = nullptr;
    int interface_number = -1;
    ~NewtUSBDevice() {
        if (handle) {
            if (interface_number >= 0) libusb_release_interface(handle, interface_number);
            libusb_close(handle);
        }
        if (context) libusb_exit(context);
    }
    NewtUSBDevice() = default;
    NewtUSBDevice(const NewtUSBDevice&) = delete;
    NewtUSBDevice& operator=(const NewtUSBDevice&) = delete;
};
int NewtUSB_Enumerate(NewtUSBVisitor visitor, void* userdata) {
    if (!visitor) return LIBUSB_ERROR_INVALID_PARAM;
    libusb_context* context = nullptr;
    int result = libusb_init(&context);
    if (result < 0) return result;
    libusb_device** devices = nullptr;
    const ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) { libusb_exit(context); return static_cast<int>(count); }
    for (ssize_t i = 0; i < count; ++i) {
        libusb_device_descriptor desc{};
        if (libusb_get_device_descriptor(devices[i], &desc) != 0) continue;
        const NewtUSBInfo info{desc.idVendor, desc.idProduct,
            libusb_get_bus_number(devices[i]), libusb_get_device_address(devices[i])};
        visitor(&info, userdata);
    }
    libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return 0;
}
int NewtUSB_Open(const NewtUSBInfo* info, int interface_number, NewtUSBDevice** out) {
    if (!out) return LIBUSB_ERROR_INVALID_PARAM;
    *out = nullptr;
    if (!info || interface_number < 0 || interface_number > 255) return LIBUSB_ERROR_INVALID_PARAM;
    auto device = std::unique_ptr<NewtUSBDevice>(new(std::nothrow) NewtUSBDevice);
    if (!device) return LIBUSB_ERROR_NO_MEM;
    int result = libusb_init(&device->context);
    if (result < 0) { return result; }
    libusb_device** devices = nullptr;
    const ssize_t count = libusb_get_device_list(device->context, &devices);
    if (count < 0) { return static_cast<int>(count); }
    result = LIBUSB_ERROR_NO_DEVICE;
    for (ssize_t i = 0; i < count; ++i) {
        if (libusb_get_bus_number(devices[i]) != info->bus || libusb_get_device_address(devices[i]) != info->address) continue;
        libusb_device_descriptor desc{};
        if (libusb_get_device_descriptor(devices[i], &desc) != 0 || desc.idVendor != info->vendor_id || desc.idProduct != info->product_id) continue;
        result = libusb_open(devices[i], &device->handle);
        break;
    }
    libusb_free_device_list(devices, 1);
    if (result == 0) {
        result = libusb_claim_interface(device->handle, interface_number);
        if (result == 0) device->interface_number = interface_number;
    }
    if (result < 0) { return result; }
    *out = device.release(); // Ownership crosses the C ABI; Close takes it back.
    return 0;
}
void NewtUSB_Close(NewtUSBDevice* device) {
    const std::unique_ptr<NewtUSBDevice> owned(device);
}
int NewtUSB_Bulk(NewtUSBDevice* device, uint8_t endpoint, unsigned char* data,
                 int length, int* transferred, unsigned int timeout_ms) {
    if (transferred) *transferred = 0;
    if (!device || !device->handle || !data || length <= 0 || !transferred || !timeout_ms ||
        (endpoint & 0x0f) == 0 || (endpoint & 0x70) != 0) return LIBUSB_ERROR_INVALID_PARAM;
    return libusb_bulk_transfer(device->handle, endpoint, data, length, transferred, timeout_ms);
}
const char* NewtUSB_ErrorName(int error) { return libusb_error_name(error); }
