#include "NewtUSB.h"
#include <cassert>
int main() {
    assert(NewtUSB_Enumerate(nullptr,nullptr)<0);
    NewtUSBDevice* out=reinterpret_cast<NewtUSBDevice*>(1);
    assert(NewtUSB_Open(nullptr,0,&out)<0 && out==nullptr);
    int transferred=5; unsigned char data[1]{};
    assert(NewtUSB_Bulk(nullptr,0x81,data,1,&transferred,10)<0 && transferred==0);
    NewtUSB_Close(nullptr);
}
