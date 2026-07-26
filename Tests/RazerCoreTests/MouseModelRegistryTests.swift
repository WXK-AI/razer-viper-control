import XCTest
@testable import RazerCore

/// Pins every parameter of the single registry entry. These literals are the values
/// the Viper V3 HyperSpeed protocol requires; drift here is a wire-format change.
final class MouseModelRegistryTests: XCTestCase {
    private let model = MouseModel.viperV3HyperSpeed

    func testSeedFieldsAreTheViperConstants() {
        XCTAssertEqual(model.family, .razer)
        XCTAssertEqual(model.supportTier, .verified)
        XCTAssertEqual(model.vendorID, 0x1532)
        XCTAssertEqual(model.productID, 0x00B8)
        XCTAssertEqual(model.name, "Razer Viper V3 HyperSpeed")
        XCTAssertEqual(model.transactionID, 0x1F)
        XCTAssertEqual(model.primaryUsagePage, 1)
        XCTAssertEqual(model.primaryUsage, 2)
        XCTAssertEqual(model.minimumFeatureReportSize, 90)
        XCTAssertEqual(model.responseWaitMilliseconds, 15)
        XCTAssertEqual(model.responsePollIntervalMilliseconds, 15)
        XCTAssertEqual(model.responseDeadlineMilliseconds, 200)
        XCTAssertEqual(model.maxCommandRetries, 5)
        XCTAssertEqual(model.dpiRange, 100...30_000)
        XCTAssertEqual(model.maxDPIStages, 5)
        XCTAssertEqual(model.pollingRates, [125, 500, 1000])
    }

    /// On-disk compatibility guard for `profiles-1532:00B8.json`.
    func testDeviceKeyRenderingIsFrozen() {
        XCTAssertEqual(model.deviceKey, "1532:00B8")
        XCTAssertEqual(model.id, "1532:00B8")
    }

    /// The default store path must keep resolving existing user profiles.
    func testDefaultProfileStorePathIsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-path-\(UUID().uuidString)", isDirectory: true)
        let store = ProfileStore(
            limits: .viperV3HyperSpeed,
            applicationSupportDirectory: directory
        )
        XCTAssertEqual(store.storageURL.lastPathComponent, "profiles-1532:00B8.json")
    }

    func testBuiltInRegistryHoldsExactlyTheSeed() {
        XCTAssertEqual(DeviceRegistry.builtIn.models.count, 1)
        XCTAssertEqual(
            DeviceRegistry.builtIn.model(vendorID: 0x1532, productID: 0x00B8)?.name,
            "Razer Viper V3 HyperSpeed"
        )
        XCTAssertNil(DeviceRegistry.builtIn.model(vendorID: 0x1532, productID: 0x0099))
        XCTAssertEqual(DeviceRegistry.builtIn.model(forDeviceKey: "1532:00B8")?.productID, 0x00B8)
        XCTAssertTrue(DeviceRegistry.builtIn.contains(vendorID: 0x1532))
        XCTAssertFalse(DeviceRegistry.builtIn.contains(vendorID: 0x3434))
    }

    /// `dataSize: 0x26` on both DPI-stage commands is silently `3 + maxDPIStages * 7`.
    func testStagePayloadSizeMatchesTheDeclaredDataSize() {
        XCTAssertEqual(3 + model.maxDPIStages * 7, 0x26)
        XCTAssertLessThanOrEqual(3 + model.maxDPIStages * 7, RazerReport.argumentLength)
    }

    func testLimitsProjectionMatchesTheModel() {
        let limits = model.limits
        XCTAssertEqual(limits.dpiRange, model.dpiRange)
        XCTAssertEqual(limits.maxDPIStages, model.maxDPIStages)
        XCTAssertEqual(limits.pollingRates, model.pollingRates)
        XCTAssertEqual(limits, ProfileLimits.viperV3HyperSpeed)
    }

    // MARK: - Polling-rate prose

    func testHumanListRendersOxfordForm() {
        XCTAssertEqual(RazerValidationError.humanList([125, 500, 1000]), "125, 500, or 1000")
    }

    func testHumanListEdgeCounts() {
        XCTAssertEqual(RazerValidationError.humanList([]), "a supported rate")
        XCTAssertEqual(RazerValidationError.humanList([125]), "125")
        XCTAssertEqual(RazerValidationError.humanList([125, 500]), "125 or 500")
        XCTAssertEqual(
            RazerValidationError.humanList([125, 500, 1000, 8000]),
            "125, 500, 1000, or 8000"
        )
    }

    // MARK: - Limit validation boundaries

    func testValidateDPIBoundaries() {
        let limits = ProfileLimits.viperV3HyperSpeed
        XCTAssertThrowsError(try limits.validateDPI(99))
        XCTAssertNoThrow(try limits.validateDPI(100))
        XCTAssertNoThrow(try limits.validateDPI(30_000))
        XCTAssertThrowsError(try limits.validateDPI(30_001)) { error in
            XCTAssertEqual(
                error as? RazerValidationError,
                .invalidDPI(30_001, allowed: 100...30_000)
            )
        }
    }

    func testValidateStagesGuardOrder() throws {
        let limits = ProfileLimits.viperV3HyperSpeed
        XCTAssertThrowsError(try limits.validateStages([], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .emptyDPIStages)
        }
        XCTAssertThrowsError(
            try limits.validateStages([800, 900, 1000, 1100, 1200, 1300], activeStage: 1)
        ) { error in
            XCTAssertEqual(error as? RazerValidationError, .tooManyDPIStages(6, maximum: 5))
        }
        XCTAssertThrowsError(try limits.validateStages([800], activeStage: 2)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidActiveStage(2, stageCount: 1))
        }
        XCTAssertThrowsError(try limits.validateStages([50], activeStage: 1)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidDPI(50, allowed: 100...30_000))
        }
        let validated = try limits.validateStages([400, 800, 1600], activeStage: 2)
        XCTAssertEqual(validated.stages, [400, 800, 1600])
        XCTAssertEqual(validated.activeStage, 2)
    }

    func testValidatePollingRate() {
        let limits = ProfileLimits.viperV3HyperSpeed
        XCTAssertNoThrow(try limits.validatePollingRate(125))
        XCTAssertNoThrow(try limits.validatePollingRate(500))
        XCTAssertNoThrow(try limits.validatePollingRate(1000))
        XCTAssertThrowsError(try limits.validatePollingRate(250)) { error in
            XCTAssertEqual(
                error as? RazerValidationError,
                .unsupportedPollingRate(250, supported: [125, 500, 1000])
            )
        }
    }
}
