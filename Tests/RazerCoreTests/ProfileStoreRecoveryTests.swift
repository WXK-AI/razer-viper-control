import XCTest
@testable import RazerCore

final class ProfileStoreRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("razer-profile-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ProfileStore(
            deviceKey: "test-device",
            applicationSupportDirectory: tempDirectory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        store = nil
    }

    func testFirstRunWhenFileMissing() {
        let outcome = store.loadOutcome()
        guard case let .firstRun(bundle) = outcome else {
            return XCTFail("Expected firstRun, got \(outcome)")
        }
        XCTAssertEqual(bundle.profiles.count, 1)
        XCTAssertEqual(bundle.profiles[0].name, "Default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testMalformedJSONIsQuarantined() throws {
        try "{not-json".data(using: .utf8)!.write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .recovered(bundle, quarantinedURL, reason) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertEqual(bundle.profiles.count, 1)
        XCTAssertTrue(reason.contains("malformed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        XCTAssertTrue(quarantinedURL.lastPathComponent.contains("corrupt"))
    }

    func testUnreadableFileIsQuarantined() throws {
        try Data("{}".utf8).write(to: store.storageURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: store.storageURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: store.storageURL.path
            )
        }

        let outcome = store.loadOutcome()
        guard case let .recovered(_, _, reason) = outcome else {
            return XCTFail("Expected recovered for unreadable file, got \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("unreadable") || reason.contains("malformed") || reason.contains("quarantine failed"),
            "Unexpected reason: \(reason)"
        )
    }

    func testDanglingSelectedProfileIDIsRepairedAndSaved() throws {
        let profile = MouseProfile(
            name: "Only",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let dangling = ProfileBundle(selectedProfileID: UUID(), profiles: [profile])
        let data = try JSONEncoder().encode(dangling)
        try data.write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .loaded(bundle) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        XCTAssertEqual(bundle.selectedProfileID, profile.id)

        let reloaded = try JSONDecoder().decode(ProfileBundle.self, from: Data(contentsOf: store.storageURL))
        XCTAssertEqual(reloaded.selectedProfileID, profile.id)
    }

    func testNilSelectedProfileIDIsRepaired() throws {
        let profile = MouseProfile(
            name: "Only",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let bundle = ProfileBundle(selectedProfileID: nil, profiles: [profile])
        try store.save(bundle)

        let outcome = store.loadOutcome()
        guard case let .loaded(loaded) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        XCTAssertEqual(loaded.selectedProfileID, profile.id)
    }

    func testSaveValidationFailureLeavesExistingFileUntouched() throws {
        let valid = MouseProfile(
            name: "Valid",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        try store.save(ProfileBundle(selectedProfileID: valid.id, profiles: [valid]))
        let before = try Data(contentsOf: store.storageURL)

        let invalid = MouseProfile(
            name: "Bad",
            dpiStages: [50],
            activeStage: 1,
            pollingRateHz: 1000
        )
        XCTAssertThrowsError(
            try store.save(ProfileBundle(selectedProfileID: invalid.id, profiles: [invalid]))
        ) { error in
            XCTAssertEqual(error as? ProfileStoreError, .validation(.invalidDPI(50)))
        }

        let after = try Data(contentsOf: store.storageURL)
        XCTAssertEqual(before, after)
    }

    func testLegacyAliasMigrationOnLoad() throws {
        let profileID = UUID()
        let profile = MouseProfile(
            id: profileID,
            name: "Legacy",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000,
            buttonMappings: [.middleClick: .mouseButton(.right)]
        )
        try store.save(ProfileBundle(selectedProfileID: profileID, profiles: [profile]))

        let outcome = store.loadOutcome()
        guard case let .loaded(bundle) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        let migrated = try XCTUnwrap(bundle.profiles.first)
        XCTAssertEqual(migrated.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(migrated.buttonMappings[.middleClick])
    }

    func testFailedQuarantineStillReturnsRecoveredDefaults() throws {
        let readOnlyParent = tempDirectory.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
        let nestedSupport = readOnlyParent.appendingPathComponent("nested-support", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let localStore = ProfileStore(
            deviceKey: "locked",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try "{broken".data(using: .utf8)!.write(to: localStore.storageURL)

        // Lock the RazerMenuBarApp directory so the quarantine move cannot create the destination rename.
        let appSupport = nestedSupport.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appSupport.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appSupport.path)
        }

        let outcome = localStore.loadOutcome()
        guard case let .recovered(bundle, _, reason) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertEqual(bundle.profiles.count, 1)
        XCTAssertTrue(reason.contains("malformed") || reason.contains("quarantine failed"), reason)
    }
}
