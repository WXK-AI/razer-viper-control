import XCTest
@testable import RazerCore

final class RazerReportTests: XCTestCase {
    private let encoder = RazerCommandEncoder(model: .viperV3HyperSpeed)
    private let limits = ProfileLimits.viperV3HyperSpeed
    func testReportLengthIs90Bytes() throws {
        let report = encoder.makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
        XCTAssertEqual(report.bytes.count, 90)
        let roundTrip = try RazerReport(bytes: report.bytes)
        XCTAssertEqual(roundTrip.bytes, report.bytes)
    }

    func testCRCCalculatedOverExpectedRange() throws {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[1] = MouseModel.viperV3HyperSpeed.transactionID
        bytes[5] = 0x02
        bytes[6] = 0x07
        bytes[7] = 0x80
        let crc = RazerReport.calculateCRC(for: bytes)
        bytes[88] = crc
        let report = try RazerReport(bytes: bytes)
        XCTAssertEqual(report.crc, bytes[2..<88].reduce(0, ^))
    }

    func testBatteryCommandEncoding() {
        let report = encoder.getBatteryLevel()
        XCTAssertEqual(report.commandClass, 0x07)
        XCTAssertEqual(report.commandID, 0x80)
        XCTAssertEqual(report.dataSize, 0x02)
        XCTAssertEqual(report.transactionID, 0x1F)
    }

    func testBatteryPercentScalesFromRawByte() throws {
        var report = encoder.makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
        report.arguments[1] = 231
        XCTAssertEqual(report.decodeBatteryPercent(), 90) // (231 * 100) / 255

        report.arguments[1] = 255
        XCTAssertEqual(report.decodeBatteryPercent(), 100)

        report.arguments[1] = 0
        XCTAssertEqual(report.decodeBatteryPercent(), 0)
    }

    func testChargingCommandEncoding() {
        let report = encoder.getChargingStatus()
        XCTAssertEqual(report.commandClass, 0x07)
        XCTAssertEqual(report.commandID, 0x84)
        XCTAssertEqual(report.dataSize, 0x02)
    }

    func testDPICommandsEncoding() throws {
        let get = encoder.getDPI()
        XCTAssertEqual(get.commandClass, 0x04)
        XCTAssertEqual(get.commandID, 0x85)
        XCTAssertEqual(get.dataSize, 0x07)
        XCTAssertEqual(get.arguments[0], 0x00)

        let set = try encoder.setDPI(x: 1800, y: 1800)
        XCTAssertEqual(set.commandClass, 0x04)
        XCTAssertEqual(set.commandID, 0x05)
        XCTAssertEqual(set.dataSize, 0x07)
        XCTAssertEqual(set.arguments[0], 0x01)
        XCTAssertEqual((Int(set.arguments[1]) << 8) | Int(set.arguments[2]), 1800)
        XCTAssertEqual((Int(set.arguments[3]) << 8) | Int(set.arguments[4]), 1800)
    }

    func testDPIStageCommandEncoding() throws {
        let get = encoder.getDPIStages()
        XCTAssertEqual(get.commandClass, 0x04)
        XCTAssertEqual(get.commandID, 0x86)
        XCTAssertEqual(get.dataSize, 0x26)

        let set = try encoder.setDPIStages(activeStage: 2, stages: [400, 800, 1600])
        XCTAssertEqual(set.commandClass, 0x04)
        XCTAssertEqual(set.commandID, 0x06)
        XCTAssertEqual(set.dataSize, 0x26)
        XCTAssertEqual(set.arguments[1], 2)
        XCTAssertEqual(set.arguments[2], 3)
    }

    func testPollingCommandEncoding() throws {
        let get = encoder.getPollingRate()
        XCTAssertEqual(get.commandClass, 0x00)
        XCTAssertEqual(get.commandID, 0x85)
        XCTAssertEqual(get.dataSize, 0x01)

        XCTAssertEqual(try encoder.setPollingRate(hz: 1000).arguments[0], 0x01)
        XCTAssertEqual(try encoder.setPollingRate(hz: 500).arguments[0], 0x02)
        XCTAssertEqual(try encoder.setPollingRate(hz: 125).arguments[0], 0x08)
    }

    func testWheelCommandEncoding() {
        let getMode = encoder.getScrollMode()
        XCTAssertEqual(getMode.commandClass, 0x02)
        XCTAssertEqual(getMode.commandID, 0x94)
        XCTAssertEqual(getMode.dataSize, 0x02)
        XCTAssertEqual(getMode.arguments[0], 0x01)

        let setMode = encoder.setScrollMode(.freeSpin)
        XCTAssertEqual(setMode.commandClass, 0x02)
        XCTAssertEqual(setMode.commandID, 0x14)
        XCTAssertEqual(setMode.arguments[0], 0x01)
        XCTAssertEqual(setMode.arguments[1], 0x01)

        let setAccel = encoder.setScrollAcceleration(true)
        XCTAssertEqual(setAccel.commandID, 0x16)
        XCTAssertEqual(setAccel.arguments[1], 0x01)

        let setReel = encoder.setScrollSmartReel(false)
        XCTAssertEqual(setReel.commandID, 0x17)
        XCTAssertEqual(setReel.arguments[1], 0x00)
    }

    func testWheelDecoding() {
        var report = encoder.makeCommand(commandClass: 0x02, commandID: 0x94, dataSize: 0x02)
        report.arguments[1] = ScrollWheelMode.tactile.rawValue
        XCTAssertEqual(report.decodeScrollMode(), .tactile)

        report.arguments[1] = 1
        XCTAssertTrue(report.decodeBoolArgument())
        report.arguments[1] = 0
        XCTAssertFalse(report.decodeBoolArgument())
    }

    /// OpenRazer-compatible get-DPI-stages response: active stage 2, stages 400 / 800 / 1600.
    func testDecodeDPIStagesMatchesOpenRazerFixture() throws {
        let report = try makeDPIStagesResponse(
            activeStage: 2,
            stages: [400, 800, 1600]
        )
        let decoded = try report.decodeDPIStages(limits: limits)
        XCTAssertEqual(decoded.activeStage, 2)
        XCTAssertEqual(decoded.stages.map(\.x), [400, 800, 1600])
        XCTAssertEqual(decoded.stages.map(\.y), [400, 800, 1600])
    }

    func testDecodeDPIStagesRejectsOversizedDataSize() throws {
        var bytes = try makeDPIStagesResponse(activeStage: 1, stages: [800]).bytes
        bytes[5] = 81
        bytes[88] = RazerReport.calculateCRC(for: bytes)
        XCTAssertThrowsError(try RazerReport(bytes: bytes)) { error in
            XCTAssertEqual(error as? RazerReportError, .invalidDataSize(81))
        }
    }

    func testDecodeDPIStagesRejectsStageCountGreaterThanFive() throws {
        var report = try makeDPIStagesResponse(activeStage: 1, stages: [400, 800, 1600])
        report.arguments[2] = 6
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6, maximum: 5))
        }
    }

    func testDecodeDPIStagesRejectsTruncatedStagePayload() throws {
        // count=2 requires 3 + 2*7 = 17 argument bytes; declare only 11 so truncation is real.
        var report = encoder.makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 11,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
        report.status = RazerReportStatus.successful.rawValue
        report.arguments[1] = 1
        report.arguments[2] = 2
        // First stage fully present so a weak guard cannot pass via invalidDPI(0).
        report.arguments[3] = 0
        report.arguments[4] = 0x03
        report.arguments[5] = 0x20
        report.arguments[6] = 0x03
        report.arguments[7] = 0x20
        report.arguments[8] = 0
        report.arguments[9] = 0
        report.arguments[10] = 1
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(
                error as? RazerReportError,
                .truncatedDPIStagesPayload(requiredBytes: 17, available: 11)
            )
        }
    }

    func testDecodeDPIStagesRejectsShortHeaderBeforeReadingActiveOrCount() throws {
        var report = encoder.makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 2,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
        report.status = RazerReportStatus.successful.rawValue
        // Plausible undeclared bytes outside dataSize — must not drive empty/tooMany/invalidActive.
        report.arguments[1] = 1
        report.arguments[2] = 0
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(
                error as? RazerReportError,
                .truncatedDPIStagesPayload(requiredBytes: 3, available: 2)
            )
        }
    }

    func testDecodeDPIStagesRejectsActiveStageOutsideCount() throws {
        let report = try makeDPIStagesResponse(activeStage: 4, stages: [400, 800, 1600])
        // Fixture helper writes the requested active stage even when invalid.
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(4, stageCount: 3))
        }
    }

    func testBytesSurvivesNon80ArgumentArrays() {
        let shortArgs = RazerReport(
            transactionID: 0,
            dataSize: 1,
            commandClass: 0x00,
            commandID: 0x85,
            arguments: [0x01, 0x02]
        )
        XCTAssertEqual(shortArgs.bytes.count, RazerReport.length)
        XCTAssertEqual(shortArgs.arguments.count, 80)

        let longArgs = RazerReport(
            transactionID: 0,
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

    private func makeDPIStagesResponse(
        activeStage: Int,
        stages: [Int]
    ) throws -> RazerReport {
        var report = encoder.makeCommand(
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
    private let limits = ProfileLimits.viperV3HyperSpeed
    func testPollingValidation() {
        XCTAssertNoThrow(try limits.validatePollingRate(125))
        XCTAssertNoThrow(try limits.validatePollingRate(500))
        XCTAssertNoThrow(try limits.validatePollingRate(1000))
        XCTAssertThrowsError(try limits.validatePollingRate(250)) { error in
            XCTAssertEqual(error as? RazerValidationError, .unsupportedPollingRate(250, supported: [125, 500, 1000]))
        }
    }

    func testProfileValidationRejectsInvalidInput() {
        XCTAssertThrowsError(try limits.validateStages([], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .emptyDPIStages)
        }
        XCTAssertThrowsError(try limits.validateStages([800], activeStage: 2)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(2, stageCount: 1))
        }
        XCTAssertThrowsError(try limits.validateStages([50], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidDPI(50, allowed: 100...30_000))
        }
        XCTAssertThrowsError(try limits.validateStages([800, 900, 1000, 1100, 1200, 1300], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6, maximum: 5))
        }
    }
}
