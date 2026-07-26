import XCTest
@testable import RazerCore

final class RazerResponseValidatorTests: XCTestCase {
    private let encoder = RazerCommandEncoder(model: .viperV3HyperSpeed)
    func testAcceptsMatchingSuccessfulResponse() throws {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.arguments[1] = 200
        response.refreshCRC()

        let result = try RazerResponseValidator.validate(
            response: response,
            for: request,
            allowingUnsupported: false
        )
        guard case let .success(report) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(report.arguments[1], 200)
    }

    func testRejectsWrongTransactionID() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.transactionID = request.transactionID &+ 1
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("transaction ID mismatch"))
        }
    }

    func testRejectsRemainingPackets() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.remainingPackets = 1
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("remaining packets mismatch"))
        }
    }

    func testRejectsWrongProtocolType() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.protocolType = 0x09
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("protocol type mismatch"))
        }
    }

    func testRejectsWrongCommandClass() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.commandClass = 0x04
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("command class mismatch"))
        }
    }

    func testRejectsWrongCommandID() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.commandID = 0x84
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("command ID mismatch"))
        }
    }

    func testRejectsIncompatibleDataSizeForFixedResponse() {
        let request = encoder.getPollingRate()
        var response = request
        response.status = RazerReportStatus.successful.rawValue
        response.dataSize = 0x02
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .invalidResponse("data size mismatch"))
        }
    }

    func testAllowingUnsupportedReturnsNotSupported() throws {
        let request = encoder.getScrollMode()
        var response = request
        response.status = RazerReportStatus.notSupported.rawValue
        // Error/unsupported replies are not required to echo request dataSize.
        response.dataSize = 0x00
        response.refreshCRC()

        let result = try RazerResponseValidator.validate(
            response: response,
            for: request,
            allowingUnsupported: true
        )
        XCTAssertEqual(result, .notSupported)
    }

    func testBusyMapsToDeviceBusy() {
        let request = encoder.getBatteryLevel()
        var response = request
        response.status = RazerReportStatus.busy.rawValue
        response.refreshCRC()

        XCTAssertThrowsError(
            try RazerResponseValidator.validate(
                response: response,
                for: request,
                allowingUnsupported: false
            )
        ) { error in
            XCTAssertEqual(error as? RazerCommandError, .deviceBusy)
        }
    }

    func testDeviceBusyInvalidatesCachedSession() {
        XCTAssertTrue(RazerCommandError.deviceBusy.shouldInvalidateSession)
    }
}
