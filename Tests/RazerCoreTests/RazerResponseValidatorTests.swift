import XCTest
@testable import RazerCore

final class RazerResponseValidatorTests: XCTestCase {
    func testAcceptsMatchingSuccessfulResponse() throws {
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getBatteryLevel()
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
        let request = RazerReport.getPollingRate()
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
        let request = RazerReport.getScrollMode()
        var response = request
        response.status = RazerReportStatus.notSupported.rawValue
        response.refreshCRC()

        let result = try RazerResponseValidator.validate(
            response: response,
            for: request,
            allowingUnsupported: true
        )
        XCTAssertEqual(result, .notSupported)
    }

    func testBusyMapsToDeviceBusy() {
        let request = RazerReport.getBatteryLevel()
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
}
