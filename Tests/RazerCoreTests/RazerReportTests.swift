import XCTest
@testable import RazerCore

final class RazerReportTests: XCTestCase {
    func testReportLengthIs90Bytes() throws {
        let report = RazerReport.makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
        XCTAssertEqual(report.bytes.count, 90)
        let roundTrip = try RazerReport(bytes: report.bytes)
        XCTAssertEqual(roundTrip.bytes, report.bytes)
    }

    func testCRCCalculatedOverExpectedRange() throws {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[1] = DeviceDescriptor.transactionID
        bytes[5] = 0x02
        bytes[6] = 0x07
        bytes[7] = 0x80
        let crc = RazerReport.calculateCRC(for: bytes)
        bytes[88] = crc
        let report = try RazerReport(bytes: bytes)
        XCTAssertEqual(report.crc, bytes[2..<88].reduce(0, ^))
    }

    func testBatteryCommandEncoding() {
        let report = RazerReport.getBatteryLevel()
        XCTAssertEqual(report.commandClass, 0x07)
        XCTAssertEqual(report.commandID, 0x80)
        XCTAssertEqual(report.dataSize, 0x02)
        XCTAssertEqual(report.transactionID, 0x1F)
    }

    func testBatteryPercentScalesFromRawByte() throws {
        var report = RazerReport.makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
        report.arguments[1] = 231
        XCTAssertEqual(report.decodeBatteryPercent(), 90) // (231 * 100) / 255

        report.arguments[1] = 255
        XCTAssertEqual(report.decodeBatteryPercent(), 100)

        report.arguments[1] = 0
        XCTAssertEqual(report.decodeBatteryPercent(), 0)
    }

    func testChargingCommandEncoding() {
        let report = RazerReport.getChargingStatus()
        XCTAssertEqual(report.commandClass, 0x07)
        XCTAssertEqual(report.commandID, 0x84)
        XCTAssertEqual(report.dataSize, 0x02)
    }

    func testDPICommandsEncoding() throws {
        let get = RazerReport.getDPI()
        XCTAssertEqual(get.commandClass, 0x04)
        XCTAssertEqual(get.commandID, 0x85)
        XCTAssertEqual(get.dataSize, 0x07)
        XCTAssertEqual(get.arguments[0], 0x00)

        let set = try RazerReport.setDPI(x: 1800, y: 1800)
        XCTAssertEqual(set.commandClass, 0x04)
        XCTAssertEqual(set.commandID, 0x05)
        XCTAssertEqual(set.dataSize, 0x07)
        XCTAssertEqual(set.arguments[0], 0x01)
        XCTAssertEqual((Int(set.arguments[1]) << 8) | Int(set.arguments[2]), 1800)
        XCTAssertEqual((Int(set.arguments[3]) << 8) | Int(set.arguments[4]), 1800)
    }

    func testDPIStageCommandEncoding() throws {
        let get = RazerReport.getDPIStages()
        XCTAssertEqual(get.commandClass, 0x04)
        XCTAssertEqual(get.commandID, 0x86)
        XCTAssertEqual(get.dataSize, 0x26)

        let set = try RazerReport.setDPIStages(activeStage: 2, stages: [400, 800, 1600])
        XCTAssertEqual(set.commandClass, 0x04)
        XCTAssertEqual(set.commandID, 0x06)
        XCTAssertEqual(set.dataSize, 0x26)
        XCTAssertEqual(set.arguments[1], 2)
        XCTAssertEqual(set.arguments[2], 3)
    }

    func testPollingCommandEncoding() throws {
        let get = RazerReport.getPollingRate()
        XCTAssertEqual(get.commandClass, 0x00)
        XCTAssertEqual(get.commandID, 0x85)
        XCTAssertEqual(get.dataSize, 0x01)

        XCTAssertEqual(try RazerReport.setPollingRate(hz: 1000).arguments[0], 0x01)
        XCTAssertEqual(try RazerReport.setPollingRate(hz: 500).arguments[0], 0x02)
        XCTAssertEqual(try RazerReport.setPollingRate(hz: 125).arguments[0], 0x08)
    }
}

final class ProfileValidatorTests: XCTestCase {
    func testPollingValidation() {
        XCTAssertNoThrow(try ProfileValidator.validatePollingRate(125))
        XCTAssertNoThrow(try ProfileValidator.validatePollingRate(500))
        XCTAssertNoThrow(try ProfileValidator.validatePollingRate(1000))
        XCTAssertThrowsError(try ProfileValidator.validatePollingRate(250)) { error in
            XCTAssertEqual(error as? RazerValidationError, .unsupportedPollingRate(250))
        }
    }

    func testProfileValidationRejectsInvalidInput() {
        XCTAssertThrowsError(try ProfileValidator.validateStages([], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .emptyDPIStages)
        }
        XCTAssertThrowsError(try ProfileValidator.validateStages([800], activeStage: 2)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(2, stageCount: 1))
        }
        XCTAssertThrowsError(try ProfileValidator.validateStages([50], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidDPI(50))
        }
        XCTAssertThrowsError(try ProfileValidator.validateStages([800, 900, 1000, 1100, 1200, 1300], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6))
        }
    }
}
