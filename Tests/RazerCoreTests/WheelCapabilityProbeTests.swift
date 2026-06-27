import XCTest
@testable import RazerCore

final class WheelCapabilityProbeTests: XCTestCase {
    func testSuccessMapsToSupported() {
        XCTAssertEqual(WheelCapabilityProbe.capability(from: .success(RazerReport())), .supported)
    }

    func testNotSupportedMapsToNotSupported() {
        XCTAssertEqual(WheelCapabilityProbe.capability(from: .notSupported), .notSupported)
    }

    func testTransportFailureMapsToUnknown() {
        struct ProbeError: Error {}
        let result: Result<CommandSendResult, Error> = .failure(ProbeError())
        XCTAssertEqual(WheelCapabilityProbe.capability(from: result), .unknown)
    }

    func testProbeReportIncludesErrors() {
        let report = WheelCapabilityProbe.ProbeReport(
            capability: WheelHardwareCapability(scrollMode: .unknown, acceleration: .notSupported, smartReel: .unknown),
            errors: ["scroll mode: timed out", "smart reel: permission denied"]
        )
        XCTAssertTrue(report.summary.contains("Unknown (probe error)"))
        XCTAssertTrue(report.summary.contains("scroll mode: timed out"))
        XCTAssertTrue(report.summary.contains("smart reel: permission denied"))
    }

    func testSummaryPreservesProbeReportWhenReadbackFails() {
        let report = WheelCapabilityProbe.ProbeReport(
            capability: WheelHardwareCapability(scrollMode: .supported, acceleration: .unknown, smartReel: .notSupported),
            errors: ["acceleration: timed out"]
        )
        let readback = RazerCommandClient.WheelHardwareReadback(
            settings: HardwareWheelSettings(),
            errors: ["scroll mode readback: device busy"]
        )
        let summary = WheelCapabilityProbe.summary(probeReport: report, readback: readback)
        XCTAssertTrue(summary.contains("Supported"))
        XCTAssertTrue(summary.contains("acceleration: timed out"))
        XCTAssertTrue(summary.contains("scroll mode readback: device busy"))
    }
}
