import XCTest
@testable import RazerCore

final class MouseProfileMigrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("razer-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

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

        let store = ProfileStore(
            deviceKey: "migration-test-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory
        )
        try store.save(bundle)

        let loaded = store.load()
        let migrated = try XCTUnwrap(loaded.profiles.first)
        XCTAssertEqual(migrated.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(migrated.buttonMappings[.middleClick])
        XCTAssertEqual(loaded.schemaVersion, ProfileBundle.currentSchemaVersion)
    }

    func testProfileStoreLoadUpgradesMissingSchemaVersionAndPersists() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Legacy V1",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000,
            buttonMappings: [.middleClick: .mouseButton(.right)]
        )
        // Simulate a pre-schemaVersion file: encode then strip the key.
        let v1Bundle = ProfileBundle(
            selectedProfileID: profileID,
            profiles: [profile],
            schemaVersion: 1
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(v1Bundle)) as? [String: Any]
        )
        object.removeValue(forKey: "schemaVersion")
        let legacyJSON = try JSONSerialization.data(withJSONObject: object)

        let store = ProfileStore(
            deviceKey: "schema-upgrade-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory
        )
        try legacyJSON.write(to: store.storageURL)

        let onDiskBefore = try JSONDecoder().decode(ProfileBundle.self, from: legacyJSON)
        XCTAssertEqual(onDiskBefore.schemaVersion, 1)

        let outcome = store.loadOutcome()
        guard case let .loaded(bundle, warning) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(bundle.schemaVersion, ProfileBundle.currentSchemaVersion)
        XCTAssertEqual(bundle.profiles.first?.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(bundle.profiles.first?.buttonMappings[.middleClick])

        let persisted = try JSONDecoder().decode(
            ProfileBundle.self,
            from: Data(contentsOf: store.storageURL)
        )
        XCTAssertEqual(persisted.schemaVersion, ProfileBundle.currentSchemaVersion)
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.storageURL)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, 2)
    }

    func testProfileStoreLoadRejectsFutureSchemaVersionWithQuarantine() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Future",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let futureBundle = ProfileBundle(
            selectedProfileID: profileID,
            profiles: [profile],
            schemaVersion: 99
        )
        let futureJSON = try JSONEncoder().encode(futureBundle)

        let store = ProfileStore(
            deviceKey: "schema-future-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory
        )
        try futureJSON.write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .recovered(bundle, quarantinedURL, reason, warning) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(bundle.schemaVersion, ProfileBundle.currentSchemaVersion)
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("schema")
                || reason.localizedCaseInsensitiveContains("version"),
            reason
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        let quarantinedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: quarantinedURL)) as? [String: Any]
        )
        XCTAssertEqual(quarantinedObject["schemaVersion"] as? Int, 99)

        let defaultsOnDisk = try JSONDecoder().decode(
            ProfileBundle.self,
            from: Data(contentsOf: store.storageURL)
        )
        XCTAssertEqual(defaultsOnDisk.schemaVersion, ProfileBundle.currentSchemaVersion)
    }

    func testFutureSchemaVersionPreservesSourceWhenQuarantineFails() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Future",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let futureJSON = try JSONEncoder().encode(
            ProfileBundle(selectedProfileID: profileID, profiles: [profile], schemaVersion: 99)
        )

        let renameToggle = SchemaMigrationRenameToggle()
        renameToggle.fail = true
        let store = ProfileStore(
            deviceKey: "schema-future-preserve-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory,
            renameEntry: { directoryFD, from, to in
                if renameToggle.fail {
                    throw POSIXError(.EACCES)
                }
                try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
            }
        )
        try futureJSON.write(to: store.storageURL)
        let before = try Data(contentsOf: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .corruptPreserved(_, sourceURL, reason) = outcome else {
            return XCTFail("Expected corruptPreserved, got \(outcome)")
        }
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("schema")
                || reason.localizedCaseInsensitiveContains("version")
                || reason.localizedCaseInsensitiveContains("quarantine"),
            reason
        )
        XCTAssertEqual(sourceURL.path, store.storageURL.path)
        XCTAssertTrue(store.writesBlockedForCorruptSource)
        XCTAssertEqual(try Data(contentsOf: store.storageURL), before)
    }

    func testProfileStoreLoadRejectsSchemaVersionZeroWithQuarantine() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Zero",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let zeroJSON = try JSONEncoder().encode(
            ProfileBundle(selectedProfileID: profileID, profiles: [profile], schemaVersion: 0)
        )

        let store = ProfileStore(
            deviceKey: "schema-zero-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory
        )
        try zeroJSON.write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .recovered(bundle, quarantinedURL, reason, warning) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(bundle.schemaVersion, ProfileBundle.currentSchemaVersion)
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("schema")
                || reason.localizedCaseInsensitiveContains("version"),
            reason
        )
        let quarantinedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: quarantinedURL)) as? [String: Any]
        )
        XCTAssertEqual(quarantinedObject["schemaVersion"] as? Int, 0)

        let defaultsOnDisk = try JSONDecoder().decode(
            ProfileBundle.self,
            from: Data(contentsOf: store.storageURL)
        )
        XCTAssertEqual(defaultsOnDisk.schemaVersion, ProfileBundle.currentSchemaVersion)
    }

    func testProfileStoreSaveRejectsSchemaVersionZeroWithoutNormalizing() throws {
        let profile = MouseProfile(
            name: "Zero",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let store = ProfileStore(
            deviceKey: "schema-zero-save-\(UUID().uuidString)",
            applicationSupportDirectory: tempDirectory
        )
        // Establish a known good primary file first.
        try store.save(
            ProfileBundle(selectedProfileID: profile.id, profiles: [profile])
        )
        let before = try Data(contentsOf: store.storageURL)

        XCTAssertThrowsError(
            try store.save(
                ProfileBundle(
                    selectedProfileID: profile.id,
                    profiles: [profile],
                    schemaVersion: 0
                )
            )
        ) { error in
            guard case let .writeFailed(message) = error as? ProfileStoreError else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("schema")
                    || message.localizedCaseInsensitiveContains("version"),
                message
            )
        }

        // Impossible versions must not be rewritten as current on disk.
        XCTAssertEqual(try Data(contentsOf: store.storageURL), before)
        let stillCurrent = try JSONDecoder().decode(
            ProfileBundle.self,
            from: Data(contentsOf: store.storageURL)
        )
        XCTAssertEqual(stillCurrent.schemaVersion, ProfileBundle.currentSchemaVersion)
    }

    func testDefaultButtonMappingsOmitsMiddleClick() {
        let mappings = PhysicalControl.defaultButtonMappings()
        XCTAssertNil(mappings[.middleClick])
        XCTAssertEqual(mappings[.wheelClick], .passthrough)
        XCTAssertEqual(mappings.count, PhysicalControl.assignableControls.count)
    }

    func testResetControlsToDefaultsOmitsMiddleClick() {
        var profile = sampleProfile(buttonMappings: [.middleClick: .mouseButton(.right)])
        profile.remapperEnabled = true
        profile.resetControlsToDefaults()
        XCTAssertNil(profile.buttonMappings[.middleClick])
        XCTAssertEqual(profile.buttonMappings[.wheelClick], .passthrough)
        XCTAssertFalse(profile.remapperEnabled)
    }
}

/// Local seam toggle (mirrors ProfileStoreRecoveryTests helper; kept file-private).
private final class SchemaMigrationRenameToggle {
    var fail = false
}
