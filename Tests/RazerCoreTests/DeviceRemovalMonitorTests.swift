import IOKit.hid
import XCTest
@testable import RazerCore

final class DeviceRemovalMonitorTests: XCTestCase {
    func testOpenFailureExposesUnavailableMonitoringAndCleansUpBackend() {
        let backend = FakeDeviceRemovalMonitorBackend(startResult: kIOReturnNotPermitted)

        let monitor = ManagedDeviceRemovalMonitor(backend: backend)

        XCTAssertEqual(
            monitor.status,
            .unavailable("IOHIDManagerOpen result \(kIOReturnNotPermitted)")
        )
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testCallbackCapturedBeforeStopIsDrainedWithoutDeliveryAfterStopBegins() {
        let backend = FakeDeviceRemovalMonitorBackend(startResult: kIOReturnSuccess)
        let monitor = ManagedDeviceRemovalMonitor(backend: backend)
        var removalCount = 0
        monitor.setRemovalHandler { _ in removalCount += 1 }
        backend.invokeCapturedCallbackDuringStop = true

        monitor.stop()
        monitor.stop()

        XCTAssertEqual(backend.capturedCallbackInvocationCount, 1)
        XCTAssertEqual(removalCount, 0)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.events, [.callbackAttempted, .cancelled])
    }
}

private final class FakeDeviceRemovalMonitorBackend: DeviceRemovalMonitorBackend {
    enum Event: Equatable {
        case callbackAttempted
        case cancelled
    }

    let startResult: IOReturn
    var invokeCapturedCallbackDuringStop = false
    private(set) var stopCount = 0
    private(set) var capturedCallbackInvocationCount = 0
    private(set) var events: [Event] = []

    private var removalHandler: ((DeviceSessionDeviceIdentity) -> Void)?

    init(startResult: IOReturn) {
        self.startResult = startResult
    }

    func start(removalHandler: @escaping (DeviceSessionDeviceIdentity) -> Void) -> IOReturn {
        self.removalHandler = removalHandler
        return startResult
    }

    func stop() {
        stopCount += 1
        if invokeCapturedCallbackDuringStop, let removalHandler {
            capturedCallbackInvocationCount += 1
            events.append(.callbackAttempted)
            removalHandler(DeviceSessionDeviceIdentity(registryEntryID: 1))
        }
        events.append(.cancelled)
    }
}
