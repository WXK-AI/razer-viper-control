// Copyright © 2026. Task 8 spike: exclusive HID ownership for 1532:00B8 (passthrough only).
// Remapping is intentionally not implemented here. Physical acceptance must pass before Task 9+.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <HIDDriverKit/HIDDriverKit.h>

#include "RazerHIDDriver.hpp"

static os_log_t RZLog()
{
    static os_log_t log = os_log_create("com.razermenubar.RazerViperHIDDriver", "spike");
    return log;
}

bool RazerHIDDriver::init()
{
    if (!super::init()) {
        return false;
    }
    os_log(RZLog(), "init");
    return true;
}

void RazerHIDDriver::free()
{
    os_log(RZLog(), "free");
    super::free();
}

kern_return_t IMPL(RazerHIDDriver, Start)
{
    os_log(RZLog(), "Start");
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log_error(RZLog(), "super::Start failed: 0x%08x", ret);
        return ret;
    }
    return kIOReturnSuccess;
}

kern_return_t IMPL(RazerHIDDriver, Stop)
{
    os_log(RZLog(), "Stop");
    return Stop(provider, SUPERDISPATCH);
}

bool RazerHIDDriver::handleStart(IOService * provider)
{
    os_log(RZLog(), "handleStart (passthrough spike for 1532:00B8 mouse interface)");
    return super::handleStart(provider);
}

void RazerHIDDriver::handleStop(IOService * provider)
{
    os_log(RZLog(), "handleStop");
    super::handleStop(provider);
}

kern_return_t RazerHIDDriver::handleReport(
    uint64_t timestamp,
    uint8_t * report,
    uint32_t reportLength,
    IOHIDReportType reportType,
    uint32_t reportID)
{
    // Passthrough: let IOUserHIDEventService parse and dispatch the physical report unchanged.
    // Duplicate-event and second-device proofs are recorded in docs/testing/driverkit-spike.md.
    return super::handleReport(timestamp, report, reportLength, reportType, reportID);
}
