// Exercise the real USB implementation with a fake libusb backend. No USB access.
#include <libusb.h>
#include <cassert>
#include "../usb/NewtUSB.cpp"
static int failure, exits, closes, releases, lists;
static libusb_device* devices[]={reinterpret_cast<libusb_device*>(3), nullptr};
extern "C" {
int libusb_init(libusb_context** context) {
    if(failure==1) return LIBUSB_ERROR_OTHER;
    *context=reinterpret_cast<libusb_context*>(1);return 0;
}
void libusb_exit(libusb_context*) { ++exits; }
ssize_t libusb_get_device_list(libusb_context*,libusb_device*** out) {
    if(failure==2) return LIBUSB_ERROR_OTHER;
    *out=devices;return 1;
}
void libusb_free_device_list(libusb_device**,int) { ++lists; }
uint8_t libusb_get_bus_number(libusb_device*) { return 4; }
uint8_t libusb_get_device_address(libusb_device*) { return 5; }
int libusb_get_device_descriptor(libusb_device*,libusb_device_descriptor* desc) {
    desc->idVendor=1;desc->idProduct=2;return 0;
}
int libusb_open(libusb_device*,libusb_device_handle** out) {
    if(failure==3) return LIBUSB_ERROR_ACCESS;
    *out=reinterpret_cast<libusb_device_handle*>(2);return 0;
}
int libusb_claim_interface(libusb_device_handle*,int) { return failure==4?LIBUSB_ERROR_BUSY:0; }
int libusb_release_interface(libusb_device_handle*,int index) { assert(index==6);++releases;return 0; }
void libusb_close(libusb_device_handle*) { ++closes; }
int libusb_bulk_transfer(libusb_device_handle*,unsigned char,unsigned char*,int,int*,unsigned int) { return 0; }
const char* libusb_error_name(int) { return "fake"; }
}
int main() {
    const NewtUSBInfo info{1,2,4,5};
    for(failure=1;failure<=4;++failure) {
        exits=closes=releases=lists=0;
        NewtUSBDevice* result=reinterpret_cast<NewtUSBDevice*>(9);
        assert(NewtUSB_Open(&info,6,&result)<0 && result==nullptr);
        assert(exits==(failure>1?1:0));
        assert(closes==(failure==4?1:0));
        assert(releases==0);
        assert(lists==(failure>=3?1:0));
    }
    failure=0;exits=closes=releases=lists=0;
    NewtUSBDevice* result=nullptr;
    assert(NewtUSB_Open(&info,6,&result)==0 && result);
    assert(exits==0 && closes==0 && lists==1);
    NewtUSB_Close(result);
    assert(exits==1 && closes==1 && releases==1);
    NewtUSB_Close(nullptr);
    assert(exits==1 && closes==1 && releases==1);
}
