import XCTest
@testable import RazerCore

private final class FakeHardwareClient: RazerHardwareMutating {
    var state = DeviceState(dpiX: 800, dpiY: 1600, pollingRateHz: 1000)
    var wheel = HardwareWheelSettings(
        scrollMode: .tactile,
        accelerationEnabled: false,
        smartReelEnabled: true
    )
    var setDPICalls: [(Int, Int)] = []
    var setPollingCalls: [Int] = []
    var setScrollModeCalls: [ScrollWheelMode] = []
    var setAccelerationCalls: [Bool] = []
    var setSmartReelCalls: [Bool] = []
    var failOnSetDPICount: Int?
    var failOnSetPollingCount: Int?
    var ignoreScrollModeWrites = false
    var scrollModeSetResult: CommandSendResult?
    private var dpiSetCount = 0
    private var pollingSetCount = 0

    func readState() throws -> DeviceState { state }

    func setDPI(x: Int, y: Int) throws {
        dpiSetCount += 1
        setDPICalls.append((x, y))
        if failOnSetDPICount == dpiSetCount {
            throw RazerCommandError.timeout
        }
        state.dpiX = x
        state.dpiY = y
    }

    func setPollingRate(hz: Int) throws {
        pollingSetCount += 1
        setPollingCalls.append(hz)
        if failOnSetPollingCount == pollingSetCount {
            throw RazerCommandError.deviceBusy
        }
        state.pollingRateHz = hz
    }

    func send(_ request: RazerReport) throws -> RazerReport {
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        if request.commandClass == 0x04 && request.commandID == 0x85 {
            response.arguments[1] = UInt8((state.dpiX >> 8) & 0xFF)
            response.arguments[2] = UInt8(state.dpiX & 0xFF)
            response.arguments[3] = UInt8((state.dpiY >> 8) & 0xFF)
            response.arguments[4] = UInt8(state.dpiY & 0xFF)
        }
        if request.commandClass == 0x00 && request.commandID == 0x85 {
            switch state.pollingRateHz {
            case 1000: response.arguments[0] = 0x01
            case 500: response.arguments[0] = 0x02
            case 125: response.arguments[0] = 0x08
            default: break
            }
        }
        response.refreshCRC()
        return response
    }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> RazerCommandClient.WheelHardwareReadback {
        var settings = HardwareWheelSettings()
        if capability.scrollMode == .supported {
            settings.scrollMode = wheel.scrollMode
        }
        if capability.acceleration == .supported {
            settings.accelerationEnabled = wheel.accelerationEnabled
        }
        if capability.smartReel == .supported {
            settings.smartReelEnabled = wheel.smartReelEnabled
        }
        return .init(settings: settings)
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws -> CommandSendResult {
        setScrollModeCalls.append(mode)
        if let scrollModeSetResult {
            return scrollModeSetResult
        }
        if !ignoreScrollModeWrites {
            wheel.scrollMode = mode
        }
        return .success(RazerReport.setScrollMode(mode))
    }

    func setScrollAcceleration(_ enabled: Bool) throws -> CommandSendResult {
        setAccelerationCalls.append(enabled)
        wheel.accelerationEnabled = enabled
        return .success(RazerReport.setScrollAcceleration(enabled))
    }

    func setScrollSmartReel(_ enabled: Bool) throws -> CommandSendResult {
        setSmartReelCalls.append(enabled)
        wheel.smartReelEnabled = enabled
        return .success(RazerReport.setScrollSmartReel(enabled))
    }
}

final class HardwareStateTransactionTests: XCTestCase {
    func testIntegrationRestoresAsymmetricDPI() throws {
        let client = FakeHardwareClient()
        let result = try HardwareStateTransaction.runIntegration(
            client: client,
            temporaryDPI: 1800,
            temporaryPollingHz: 500
        )
        XCTAssertEqual(result.original.dpiX, 800)
        XCTAssertEqual(result.original.dpiY, 1600)
        XCTAssertEqual(client.state.dpiX, 800)
        XCTAssertEqual(client.state.dpiY, 1600)
        XCTAssertEqual(client.state.pollingRateHz, 1000)
        XCTAssertEqual(client.setDPICalls.last?.0, 800)
        XCTAssertEqual(client.setDPICalls.last?.1, 1600)
    }

    func testFailureAfterEachMutationPhaseStillRestores() {
        let phases: [HardwareTransactionPhase] = [
            .setTemporaryDPI,
            .verifyTemporaryDPI,
            .setTemporaryPolling,
            .verifyTemporaryPolling
        ]
        for phase in phases {
            let client = FakeHardwareClient()
            XCTAssertThrowsError(
                try HardwareStateTransaction.runIntegration(
                    client: client,
                    temporaryDPI: 1800,
                    temporaryPollingHz: 500,
                    failAfter: phase
                )
            )
            XCTAssertEqual(client.state.dpiX, 800, "phase \(phase)")
            XCTAssertEqual(client.state.dpiY, 1600, "phase \(phase)")
            XCTAssertEqual(client.state.pollingRateHz, 1000, "phase \(phase)")
        }
    }

    func testDPIRestoreFailureStillAttemptsPollingRestore() {
        let client = FakeHardwareClient()
        client.failOnSetDPICount = 2 // temporary ok, restore DPI fails
        XCTAssertThrowsError(
            try HardwareStateTransaction.runIntegration(
                client: client,
                temporaryDPI: 1800,
                temporaryPollingHz: 500
            )
        )
        // Polling restore must still have been attempted after DPI restore failed.
        XCTAssertTrue(client.setPollingCalls.contains(1000))
        XCTAssertEqual(client.state.pollingRateHz, 1000)
    }

    func testFailureDuringRestoreReportsBothErrors() {
        let client = FakeHardwareClient()
        client.failOnSetDPICount = 2
        XCTAssertThrowsError(
            try HardwareStateTransaction.runIntegration(
                client: client,
                temporaryDPI: 1800,
                temporaryPollingHz: 500,
                failAfter: .verifyTemporaryPolling
            )
        ) { error in
            guard case .restorationFailed = error as? HardwareTransactionError else {
                return XCTFail("Expected restorationFailed, got \(error)")
            }
        }
        XCTAssertTrue(client.setPollingCalls.contains(1000))
    }

    func testWheelMutationSkipsUnknownOriginal() {
        let client = FakeHardwareClient()
        client.wheel.scrollMode = nil
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .notSupported,
            smartReel: .notSupported
        )
        XCTAssertThrowsError(
            try HardwareStateTransaction.runWheelProbeMutation(client: client, capability: capability)
        ) { error in
            XCTAssertEqual(error as? HardwareTransactionError, .unknownOriginal("scroll mode"))
        }
        XCTAssertTrue(client.setScrollModeCalls.isEmpty)
    }

    func testWheelRejectsUnknownCapability() {
        XCTAssertThrowsError(
            try HardwareStateTransaction.rejectUnknownCapabilities(
                WheelHardwareCapability(scrollMode: .unknown, acceleration: .notSupported, smartReel: .notSupported)
            )
        ) { error in
            XCTAssertEqual(error as? HardwareTransactionError, .unknownCapability("scroll mode"))
        }
    }

    func testWheelMutationRestoresExactValues() throws {
        let client = FakeHardwareClient()
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .supported,
            smartReel: .supported
        )
        let restored = try HardwareStateTransaction.runWheelProbeMutation(
            client: client,
            capability: capability
        )
        XCTAssertEqual(restored.scrollMode, .tactile)
        XCTAssertEqual(restored.accelerationEnabled, false)
        XCTAssertEqual(restored.smartReelEnabled, true)
    }

    func testWheelTemporaryMismatchFailsAndRestores() {
        let client = FakeHardwareClient()
        client.ignoreScrollModeWrites = true
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .notSupported,
            smartReel: .notSupported
        )
        XCTAssertThrowsError(
            try HardwareStateTransaction.runWheelProbeMutation(client: client, capability: capability)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("temporary scroll mode") || message.contains("verification"),
                message
            )
        }
        XCTAssertEqual(client.wheel.scrollMode, .tactile)
    }

    func testWheelNotSupportedSetterFails() {
        let client = FakeHardwareClient()
        client.scrollModeSetResult = .notSupported
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .notSupported,
            smartReel: .notSupported
        )
        XCTAssertThrowsError(
            try HardwareStateTransaction.runWheelProbeMutation(client: client, capability: capability)
        )
    }

    func testWheelFailureAfterMutateStillRestoresIndependently() {
        let client = FakeHardwareClient()
        let capability = WheelHardwareCapability(
            scrollMode: .supported,
            acceleration: .supported,
            smartReel: .supported
        )
        XCTAssertThrowsError(
            try HardwareStateTransaction.runWheelProbeMutation(
                client: client,
                capability: capability,
                failAfter: .verifyTemporaryWheel
            )
        )
        XCTAssertEqual(client.wheel.scrollMode, .tactile)
        XCTAssertEqual(client.wheel.accelerationEnabled, false)
        XCTAssertEqual(client.wheel.smartReelEnabled, true)
        // All three restores attempted (mutate + restore for each feature).
        XCTAssertGreaterThanOrEqual(client.setScrollModeCalls.count, 2)
        XCTAssertGreaterThanOrEqual(client.setAccelerationCalls.count, 2)
        XCTAssertGreaterThanOrEqual(client.setSmartReelCalls.count, 2)
    }
}
