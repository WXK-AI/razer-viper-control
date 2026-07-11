// Copyright © 2026. Task 8 spike: exclusive HID ownership for 1532:00B8 (passthrough only).
// Remapping is intentionally not implemented here. Physical acceptance must pass before Task 9+.
// Report dispatch uses inherited IOUserHIDEventService::handleReport (void signature).

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <HIDDriverKit/HIDDriverKit.h>

#include "RazerHIDDriver.hpp"

bool RazerHIDDriver::init()
{
    if (!super::init()) {
        return false;
    }
    IOLog("RazerHIDDriver: init\n");
    return true;
}

void RazerHIDDriver::free()
{
    IOLog("RazerHIDDriver: free\n");
    super::free();
}

kern_return_t IMPL(RazerHIDDriver, Start)
{
    IOLog("RazerHIDDriver: Start\n");
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        IOLog("RazerHIDDriver: super::Start failed: 0x%08x\n", ret);
        return ret;
    }
    return kIOReturnSuccess;
}

kern_return_t IMPL(RazerHIDDriver, Stop)
{
    IOLog("RazerHIDDriver: Stop\n");
    return Stop(provider, SUPERDISPATCH);
}

bool RazerHIDDriver::handleStart(IOService * provider)
{
    IOLog("RazerHIDDriver: handleStart (passthrough spike for 1532:00B8 mouse interface)\n");
    return super::handleStart(provider);
}
