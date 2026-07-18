import IOKit.hid
import XCTest
@testable import RazerCore

final class RazerCommandClientTransportTests: XCTestCase {
    func testBusyResponsesRetryThenSucceed() throws {
        let request = RazerReport.getBatteryLevel()
        let transport = FakeRazerReportTransport(
            getResponses: [
                .success(response(for: request, status: .busy).bytes),
                .success(response(for: request, status: .busy).bytes),
                .success(response(for: request, status: .successful).bytes)
            ]
        )
        let client = RazerCommandClient(transport: transport)

        let report = try client.send(request)

        XCTAssertEqual(report.responseStatus, RazerReportStatus.successful)
        XCTAssertEqual(transport.setCount, 3)
        XCTAssertEqual(transport.getCount, 3)
    }

    func testBusyExhaustionThrowsDeviceBusy() {
        let request = RazerReport.getBatteryLevel()
        let busy = response(for: request, status: .busy).bytes
        let transport = FakeRazerReportTransport(
            getResponses: Array(
                repeating: .success(busy),
                count: DeviceDescriptor.maxCommandRetries
            )
        )
        let client = RazerCommandClient(transport: transport)

        XCTAssertThrowsError(try client.send(request)) { error in
            XCTAssertEqual(error as? RazerCommandError, .deviceBusy)
        }
        XCTAssertEqual(transport.setCount, DeviceDescriptor.maxCommandRetries)
        XCTAssertEqual(transport.getCount, DeviceDescriptor.maxCommandRetries)
    }

    func testTransportSetFailureDoesNotRetry() {
        let expected = RazerCommandError.permissionDenied("set result \(kIOReturnNotPermitted)")
        let transport = FakeRazerReportTransport(setErrors: [expected])
        let client = RazerCommandClient(transport: transport)

        XCTAssertThrowsError(try client.send(.getBatteryLevel())) { error in
            XCTAssertEqual(error as? RazerCommandError, expected)
        }
        XCTAssertEqual(transport.setCount, 1)
        XCTAssertEqual(transport.getCount, 0)
    }

    func testCRCMismatchThrowsInvalidResponse() {
        let request = RazerReport.getBatteryLevel()
        var invalid = response(for: request, status: .successful)
        invalid.crc ^= 0xFF
        let transport = FakeRazerReportTransport(getResponses: [.success(invalid.bytes)])
        let client = RazerCommandClient(transport: transport)

        XCTAssertThrowsError(try client.send(request)) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("CRC mismatch."))
        }
        XCTAssertEqual(transport.setCount, 1)
        XCTAssertEqual(transport.getCount, 1)
    }

    func testSleepDurationUsesDescriptorDefault() throws {
        let request = RazerReport.getBatteryLevel()
        let transport = FakeRazerReportTransport(
            getResponses: [.success(response(for: request, status: .successful).bytes)]
        )
        let client = RazerCommandClient(transport: transport)

        _ = try client.send(request)

        XCTAssertEqual(transport.sleeps, [DeviceDescriptor.responseWaitMilliseconds])
    }

    func testNewCommandResponsesPollGetThenSucceed() throws {
        let request = RazerReport.getBatteryLevel()
        let transport = FakeRazerReportTransport(
            getResponses: [
                .success(response(for: request, status: .newCommand).bytes),
                .success(response(for: request, status: .newCommand).bytes),
                .success(response(for: request, status: .successful).bytes)
            ]
        )
        let client = RazerCommandClient(transport: transport)

        let report = try client.send(request)

        XCTAssertEqual(report.responseStatus, RazerReportStatus.successful)
        XCTAssertEqual(transport.setCount, 1)
        XCTAssertEqual(transport.getCount, 3)
        XCTAssertEqual(
            transport.sleeps,
            [
                DeviceDescriptor.responseWaitMilliseconds,
                DeviceDescriptor.responsePollIntervalMilliseconds,
                DeviceDescriptor.responsePollIntervalMilliseconds
            ]
        )
    }

    func testNewCommandPollingStopsAtDeadlineAndReportsBlockedAccess() {
        let request = RazerReport.getBatteryLevel()
        let notReady: Result<[UInt8], RazerCommandError> = .success(
            response(for: request, status: .newCommand).bytes
        )
        let transport = FakeRazerReportTransport(
            getResponses: Array(repeating: notReady, count: 32)
        )
        let client = RazerCommandClient(transport: transport)

        XCTAssertThrowsError(try client.send(request)) { error in
            XCTAssertEqual(
                error as? RazerCommandError,
                .blockedDeviceAccess("status 0x00 — no acknowledgement")
            )
        }
        XCTAssertEqual(transport.setCount, 1)
        XCTAssertEqual(
            transport.sleeps.reduce(UInt64(0), +),
            DeviceDescriptor.responseDeadlineMilliseconds
        )
        XCTAssertLessThanOrEqual(
            transport.sleeps.reduce(UInt64(0), +),
            DeviceDescriptor.responseDeadlineMilliseconds
        )
    }

    private func response(for request: RazerReport, status: RazerReportStatus) -> RazerReport {
        var response = request
        response.status = status.rawValue
        response.refreshCRC()
        return response
    }
}

private final class FakeRazerReportTransport: RazerReportTransport, @unchecked Sendable {
    private var setErrors: [RazerCommandError?]
    private var getResponses: [Result<[UInt8], RazerCommandError>]

    private(set) var setCount = 0
    private(set) var getCount = 0
    private(set) var sleeps: [UInt64] = []

    init(
        setErrors: [RazerCommandError?] = [],
        getResponses: [Result<[UInt8], RazerCommandError>] = []
    ) {
        self.setErrors = setErrors
        self.getResponses = getResponses
    }

    func open(nonSeizing: Bool) throws {}

    func close() {}

    func setFeatureReport(_ report: [UInt8]) throws {
        setCount += 1
        if !setErrors.isEmpty, let error = setErrors.removeFirst() {
            throw error
        }
    }

    func getFeatureReport(length: Int) throws -> [UInt8] {
        getCount += 1
        guard !getResponses.isEmpty else {
            throw RazerCommandError.transport("No scripted GET response.")
        }
        return try getResponses.removeFirst().get()
    }

    func sleep(milliseconds: UInt64) {
        sleeps.append(milliseconds)
    }
}
