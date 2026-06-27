import XCTest
@testable import RazerCore

final class MouseProfileMigrationTests: XCTestCase {
    private func sampleProfile(buttonMappings: [PhysicalControl: ButtonAction]) -> MouseProfile {
        MouseProfile(
            name: "Test",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000,
            buttonMappings: buttonMappings
        )
    }

    func testMigratesLegacyMiddleClickToWheelClick() {
        var profile = sampleProfile(buttonMappings: [.middleClick: .mouseButton(.right)])
        profile.migrateButton2Alias()
        XCTAssertEqual(profile.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(profile.buttonMappings[.middleClick])
    }

    func testExplicitWheelClickWinsOverLegacyMiddleClick() {
        var profile = sampleProfile(buttonMappings: [
            .wheelClick: .mouseButton(.left),
            .middleClick: .mouseButton(.right)
        ])
        profile.migrateButton2Alias()
        XCTAssertEqual(profile.buttonMappings[.wheelClick], .mouseButton(.left))
        XCTAssertNil(profile.buttonMappings[.middleClick])
    }

    func testPassthroughMiddleClickIsRemovedWithoutChangingWheelClick() {
        var profile = sampleProfile(buttonMappings: [
            .middleClick: .passthrough
        ])
        profile.migrateButton2Alias()
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .wheelClick, in: profile.buttonMappings),
            .passthrough
        )
        XCTAssertNil(profile.buttonMappings[.middleClick])
    }

    func testMigrationIsIdempotent() {
        var profile = sampleProfile(buttonMappings: [.middleClick: .mouseButton(.right)])
        profile.migrateButton2Alias()
        let once = profile
        profile.migrateButton2Alias()
        XCTAssertEqual(profile, once)
    }

    func testMigratedProfileMatchesResolvedActionWithoutAliasFallback() {
        var profile = sampleProfile(buttonMappings: [.middleClick: .mouseButton(.right)])
        profile.migrateButton2Alias()
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .wheelClick, in: profile.buttonMappings),
            profile.buttonMappings[.wheelClick]
        )
    }

    func testProfileStoreLoadMigratesLegacyBundle() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Legacy",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000,
            buttonMappings: [.middleClick: .mouseButton(.right)]
        )
        let bundle = ProfileBundle(selectedProfileID: profileID, profiles: [profile])

        let store = ProfileStore(deviceKey: "migration-test-\(UUID().uuidString)", fileManager: .default)
        try? FileManager.default.removeItem(at: store.storageURL)
        try store.save(bundle)

        let loaded = store.load()
        let migrated = try XCTUnwrap(loaded.profiles.first)
        XCTAssertEqual(migrated.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(migrated.buttonMappings[.middleClick])
    }

    func testDefaultButtonMappingsOmitsMiddleClick() {
        let mappings = PhysicalControl.defaultButtonMappings()
        XCTAssertNil(mappings[.middleClick])
        XCTAssertEqual(mappings[.wheelClick], .passthrough)
        XCTAssertEqual(mappings.count, PhysicalControl.assignableControls.count)
    }

    func testResetControlsToDefaultsOmitsMiddleClick() {
        var profile = sampleProfile(buttonMappings: [.middleClick: .mouseButton(.right)])
        profile.resetControlsToDefaults()
        XCTAssertNil(profile.buttonMappings[.middleClick])
        XCTAssertEqual(profile.buttonMappings[.wheelClick], .passthrough)
    }
}
