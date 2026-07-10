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

    func testWheelCommandEncoding() {
        let getMode = RazerReport.getScrollMode()
        XCTAssertEqual(getMode.commandClass, 0x02)
        XCTAssertEqual(getMode.commandID, 0x94)
        XCTAssertEqual(getMode.dataSize, 0x02)
        XCTAssertEqual(getMode.arguments[0], 0x01)

        let setMode = RazerReport.setScrollMode(.freeSpin)
        XCTAssertEqual(setMode.commandClass, 0x02)
        XCTAssertEqual(setMode.commandID, 0x14)
        XCTAssertEqual(setMode.arguments[0], 0x01)
        XCTAssertEqual(setMode.arguments[1], 0x01)

        let setAccel = RazerReport.setScrollAcceleration(true)
        XCTAssertEqual(setAccel.commandID, 0x16)
        XCTAssertEqual(setAccel.arguments[1], 0x01)

        let setReel = RazerReport.setScrollSmartReel(false)
        XCTAssertEqual(setReel.commandID, 0x17)
        XCTAssertEqual(setReel.arguments[1], 0x00)
    }

    func testWheelDecoding() {
        var report = RazerReport.makeCommand(commandClass: 0x02, commandID: 0x94, dataSize: 0x02)
        report.arguments[1] = ScrollWheelMode.tactile.rawValue
        XCTAssertEqual(report.decodeScrollMode(), .tactile)

        report.arguments[1] = 1
        XCTAssertTrue(report.decodeBoolArgument())
        report.arguments[1] = 0
        XCTAssertFalse(report.decodeBoolArgument())
    }

    /// OpenRazer-compatible get-DPI-stages response: active stage 2, stages 400 / 800 / 1600.
    func testDecodeDPIStagesMatchesOpenRazerFixture() throws {
        let report = try Self.makeDPIStagesResponse(
            activeStage: 2,
            stages: [400, 800, 1600]
        )
        let decoded = try report.decodeDPIStages()
        XCTAssertEqual(decoded.activeStage, 2)
        XCTAssertEqual(decoded.stages.map(\.x), [400, 800, 1600])
        XCTAssertEqual(decoded.stages.map(\.y), [400, 800, 1600])
    }

    func testDecodeDPIStagesRejectsOversizedDataSize() throws {
        var bytes = try Self.makeDPIStagesResponse(activeStage: 1, stages: [800]).bytes
        bytes[5] = 81
        bytes[88] = RazerReport.calculateCRC(for: bytes)
        XCTAssertThrowsError(try RazerReport(bytes: bytes)) { error in
            XCTAssertEqual(error as? RazerReportError, .invalidDataSize(81))
        }
    }

    func testDecodeDPIStagesRejectsStageCountGreaterThanFive() throws {
        var report = try Self.makeDPIStagesResponse(activeStage: 1, stages: [400, 800, 1600])
        report.arguments[2] = 6
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages()) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6))
        }
    }

    func testDecodeDPIStagesRejectsTruncatedStagePayload() throws {
        var report = RazerReport.makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 0x26,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
        report.status = RazerReportStatus.successful.rawValue
        report.arguments[1] = 1
        report.arguments[2] = 2
        // Only first stage fully present; second stage truncated inside declared count.
        report.arguments[3] = 0
        report.arguments[4] = 0x03
        report.arguments[5] = 0x20
        report.arguments[6] = 0x03
        report.arguments[7] = 0x20
        report.arguments[8] = 0
        report.arguments[9] = 0
        report.arguments[10] = 1
        // Missing X/Y for stage index 1
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages())
    }

    func testDecodeDPIStagesRejectsActiveStageOutsideCount() throws {
        let report = try Self.makeDPIStagesResponse(activeStage: 4, stages: [400, 800, 1600])
        // Fixture helper writes the requested active stage even when invalid.
        XCTAssertThrowsError(try report.decodeDPIStages()) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(4, stageCount: 3))
        }
    }

    func testBytesSurvivesNon80ArgumentArrays() {
        let shortArgs = RazerReport(
            dataSize: 1,
            commandClass: 0x00,
            commandID: 0x85,
            arguments: [0x01, 0x02]
        )
        XCTAssertEqual(shortArgs.bytes.count, RazerReport.length)
        XCTAssertEqual(shortArgs.arguments.count, 80)

        let longArgs = RazerReport(
            dataSize: 1,
            commandClass: 0x00,
            commandID: 0x85,
            arguments: Array(repeating: 0xAB, count: 120)
        )
        XCTAssertEqual(longArgs.bytes.count, RazerReport.length)
        XCTAssertEqual(longArgs.arguments.count, 80)
        XCTAssertEqual(longArgs.arguments[0], 0xAB)
        XCTAssertEqual(longArgs.arguments[79], 0xAB)
    }

    private static func makeDPIStagesResponse(
        activeStage: Int,
        stages: [Int]
    ) throws -> RazerReport {
        var report = RazerReport.makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 0x26,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
        report.status = RazerReportStatus.successful.rawValue
        report.arguments[1] = UInt8(activeStage)
        report.arguments[2] = UInt8(stages.count)
        var offset = 3
        for (index, dpi) in stages.enumerated() {
            guard offset + 6 < report.arguments.count else { break }
            report.arguments[offset] = UInt8(index)
            report.arguments[offset + 1] = UInt8((dpi >> 8) & 0xFF)
            report.arguments[offset + 2] = UInt8(dpi & 0xFF)
            report.arguments[offset + 3] = UInt8((dpi >> 8) & 0xFF)
            report.arguments[offset + 4] = UInt8(dpi & 0xFF)
            report.arguments[offset + 5] = 0x00
            report.arguments[offset + 6] = 0x00
            offset += 7
        }
        report.refreshCRC()
        return report
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
