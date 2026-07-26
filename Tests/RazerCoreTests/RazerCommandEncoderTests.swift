import XCTest
@testable import RazerCore

/// Encoder behavior that the golden-bytes suite does not cover: rejected writes, the
/// stamped transaction ID, and the stage decoder's limit handling.
///
/// Exact wire bytes for every builder are pinned in `RazerReportGoldenBytesTests`.
final class RazerCommandEncoderTests: XCTestCase {
    private let encoder = RazerCommandEncoder(model: .viperV3HyperSpeed)
    private let limits = ProfileLimits.viperV3HyperSpeed

    func testRejectedWritesThrowLimitErrors() {
        XCTAssertThrowsError(try encoder.setPollingRate(hz: 250)) { error in
            XCTAssertEqual(
                error as? RazerValidationError,
                .unsupportedPollingRate(250, supported: [125, 500, 1000])
            )
        }
        XCTAssertThrowsError(try encoder.setDPI(x: 50, y: 50)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidDPI(50, allowed: 100...30_000))
        }
        XCTAssertThrowsError(try encoder.setDPI(x: 800, y: 30_001)) { error in
            XCTAssertEqual(
                error as? RazerValidationError,
                .invalidDPI(30_001, allowed: 100...30_000)
            )
        }
        XCTAssertThrowsError(
            try encoder.setDPIStages(activeStage: 1, stages: [800, 900, 1000, 1100, 1200, 1300])
        ) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6, maximum: 5))
        }
    }

    func testEncoderStampsTheModelTransactionID() {
        XCTAssertEqual(encoder.transactionID, 0x1F)
        XCTAssertEqual(encoder.getBatteryLevel().bytes[1], 0x1F)
        XCTAssertEqual(encoder.limits, limits)
        XCTAssertEqual(encoder.model, .viperV3HyperSpeed)
    }

    func testFrameConstantsAreProtocolWideNotPerDevice() {
        XCTAssertEqual(RazerReport.length, 90)
        XCTAssertEqual(RazerReport.argumentLength, 80)
        XCTAssertEqual(MouseModel.viperV3HyperSpeed.minimumFeatureReportSize, RazerReport.length)
    }

    // MARK: - Stage decoding against model limits

    func testDecodeReadsStagesBackFromAValidResponse() throws {
        let report = try makeStagesResponse(activeStage: 2, stages: [400, 800, 1600])
        let decoded = try report.decodeDPIStages(limits: limits)
        XCTAssertEqual(decoded.activeStage, 2)
        XCTAssertEqual(decoded.stages.map(\.x), [400, 800, 1600])
        XCTAssertEqual(decoded.stages.map(\.y), [400, 800, 1600])
    }

    func testDecodeRejectsStageCountAboveTheModelMaximum() throws {
        var report = try makeStagesResponse(activeStage: 1, stages: [400, 800, 1600])
        report.arguments[2] = 6
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6, maximum: 5))
        }
    }

    func testDecodeRejectsActiveStageOutsideTheReportedCount() throws {
        let report = try makeStagesResponse(activeStage: 4, stages: [400, 800, 1600])
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(4, stageCount: 3))
        }
    }

    func testDecodeRejectsAShortHeaderBeforeReadingActiveOrCount() {
        var report = encoder.makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 2,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
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

    func testDecodeRejectsAStageBelowTheModelFloor() throws {
        var report = try makeStagesResponse(activeStage: 1, stages: [800])
        report.arguments[4] = 0x00
        report.arguments[5] = 0x32 // 50 DPI
        report.refreshCRC()
        XCTAssertThrowsError(try report.decodeDPIStages(limits: limits)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidDPI(50, allowed: 100...30_000))
        }
    }

    private func makeStagesResponse(activeStage: Int, stages: [Int]) throws -> RazerReport {
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
