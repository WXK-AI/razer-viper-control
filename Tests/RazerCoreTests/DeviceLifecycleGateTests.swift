import XCTest
@testable import RazerCore

final class DeviceLifecycleGateTests: XCTestCase {
    func testSleepInvalidatesAwakeWorkAndSuppressesNewWork() throws {
        let gate = DeviceLifecycleGate()
        let scheduled = try XCTUnwrap(gate.currentAwakeToken())

        gate.transitionToSleep()

        XCTAssertFalse(gate.isCurrentAndAwake(scheduled))
        XCTAssertNil(gate.currentAwakeToken())
    }

    func testDelayedWakeTokenCannotRunAfterLaterSleep() throws {
        let gate = DeviceLifecycleGate()
        gate.transitionToSleep()
        let wake = gate.transitionToWake()

        gate.transitionToSleep()

        XCTAssertFalse(gate.isCurrentAndAwake(wake))
    }

    func testRemovalInvalidatesInFlightWorkWithoutPuttingGateToSleep() throws {
        let gate = DeviceLifecycleGate()
        let inFlight = try XCTUnwrap(gate.currentAwakeToken())

        gate.invalidateForRemoval()

        XCTAssertFalse(gate.isCurrentAndAwake(inFlight))
        XCTAssertNotNil(gate.currentAwakeToken())
    }

    func testPublicationRequiresCurrentApplyAndLifecycleTokens() throws {
        let lifecycle = DeviceLifecycleGate()
        let apply = LatestHardwareApplyGate()
        let lifecycleToken = try XCTUnwrap(lifecycle.currentAwakeToken())
        let applyToken = apply.issue()

        XCTAssertTrue(
            apply.isCurrent(applyToken) && lifecycle.isCurrentAndAwake(lifecycleToken)
        )

        lifecycle.transitionToSleep()

        XCTAssertFalse(
            apply.isCurrent(applyToken) && lifecycle.isCurrentAndAwake(lifecycleToken)
        )
    }
}
