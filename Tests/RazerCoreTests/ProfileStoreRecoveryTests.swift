import Darwin
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

    func testFirstRunWhenFileMissingPersistsDefaults() throws {
        let outcome = store.loadOutcome()
        guard case let .firstRun(bundle, warning) = outcome else {
            return XCTFail("Expected firstRun, got \(outcome)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(bundle.profiles.count, 1)
        XCTAssertEqual(bundle.profiles[0].name, "Default")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testMalformedJSONIsQuarantined() throws {
        try "{not-json".data(using: .utf8)!.write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .recovered(bundle, quarantinedURL, reason, warning) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(bundle.profiles.count, 1)
        XCTAssertTrue(reason.contains("malformed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
        XCTAssertTrue(quarantinedURL.lastPathComponent.contains("corrupt"))
    }

    func testOversizedFileIsQuarantinedBeforeDecode() throws {
        try Data(repeating: 0, count: ProfileSafetyLimits.maximumFileBytes + 1).write(to: store.storageURL)

        let outcome = store.loadOutcome()
        guard case let .recovered(_, quarantinedURL, reason, _) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("maximum"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
    }

    func testSymlinkIsQuarantinedWithoutFollowingTarget() throws {
        let target = tempDirectory.appendingPathComponent("symlink-target.json")
        let targetBytes = Data("{target-must-remain".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: store.storageURL, withDestinationURL: target)

        let outcome = store.loadOutcome()
        guard case let .recovered(_, quarantinedURL, reason, _) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("symbolic link"), reason)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        let values = try quarantinedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(values.isSymbolicLink == true)
    }

    func testUnreadableFileIsQuarantinedOrPreserved() throws {
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
        switch outcome {
        case let .recovered(_, _, reason, _):
            XCTAssertTrue(reason.contains("unreadable") || reason.contains("malformed"), reason)
        case let .corruptPreserved(_, _, reason):
            XCTAssertTrue(
                reason.contains("unreadable") || reason.contains("malformed") || reason.contains("quarantine failed"),
                reason
            )
            XCTAssertTrue(store.writesBlockedForCorruptSource)
        default:
            XCTFail("Expected recovered or corruptPreserved, got \(outcome)")
        }
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
        guard case let .loaded(bundle, warning) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        XCTAssertNil(warning)
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
        guard case let .loaded(loaded, _) = outcome else {
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

    func testActualWriteFailureIsReported() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("write-fail-support", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let fchmodToggle = OperationToggle()
        let localStore = ProfileStore(
            deviceKey: "write-fail",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            fchmodFile: { fd, mode in
                if fchmodToggle.fail {
                    throw POSIXError(.EACCES)
                }
                if fchmod(fd, mode) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                }
            }
        )
        let profile = MouseProfile(
            name: "Valid",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let bundle = ProfileBundle(selectedProfileID: profile.id, profiles: [profile])
        try localStore.save(bundle)

        fchmodToggle.fail = true
        XCTAssertThrowsError(try localStore.save(bundle)) { error in
            guard case .writeFailed = error as? ProfileStoreError else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
    }

    func testRepairSaveFailureSurfacesWarningWithoutClaimingCleanPersist() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("repair-fail-support", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let fchmodToggle = OperationToggle()
        let localStore = ProfileStore(
            deviceKey: "repair-fail",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            fchmodFile: { fd, mode in
                if fchmodToggle.fail {
                    throw POSIXError(.EACCES)
                }
                if fchmod(fd, mode) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                }
            }
        )
        let profile = MouseProfile(
            name: "Only",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        let dangling = ProfileBundle(selectedProfileID: UUID(), profiles: [profile])
        try JSONEncoder().encode(dangling).write(to: localStore.storageURL)

        fchmodToggle.fail = true
        let outcome = localStore.loadOutcome()
        guard case let .loaded(bundle, warning) = outcome else {
            return XCTFail("Expected loaded with warning, got \(outcome)")
        }
        XCTAssertEqual(bundle.selectedProfileID, profile.id)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.isEmpty == false, warning ?? "")
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
        guard case let .loaded(bundle, _) = outcome else {
            return XCTFail("Expected loaded, got \(outcome)")
        }
        let migrated = try XCTUnwrap(bundle.profiles.first)
        XCTAssertEqual(migrated.buttonMappings[.wheelClick], .mouseButton(.right))
        XCTAssertNil(migrated.buttonMappings[.middleClick])
    }

    func testFailedQuarantineBlocksLaterSavesEvenAfterPermissionsRestored() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("nested-support-locked", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let renameToggle = OperationToggle()
        let localStore = ProfileStore(
            deviceKey: "locked",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            renameEntry: { directoryFD, from, to in
                if renameToggle.fail {
                    throw POSIXError(.EACCES)
                }
                try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
            }
        )
        let corruptBytes = Data("{broken-source-must-survive".utf8)
        try corruptBytes.write(to: localStore.storageURL)

        renameToggle.fail = true
        let outcome = localStore.loadOutcome()
        guard case let .corruptPreserved(bundle, sourceURL, _) = outcome else {
            return XCTFail("Expected corruptPreserved, got \(outcome)")
        }
        XCTAssertTrue(localStore.writesBlockedForCorruptSource)
        XCTAssertEqual(try Data(contentsOf: sourceURL), corruptBytes)

        // Renames work again — durable corrupt-source block must still prevent overwrite.
        renameToggle.fail = false

        XCTAssertThrowsError(try localStore.save(bundle)) { error in
            guard case .writeBlockedCorruptSource = error as? ProfileStoreError else {
                return XCTFail("Expected writeBlockedCorruptSource, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), corruptBytes)

        // Explicit discard clears the block and allows a fresh save.
        try localStore.discardCorruptSourceAndAllowWrites()
        XCTAssertFalse(localStore.writesBlockedForCorruptSource)
        try localStore.save(bundle)
        XCTAssertNotEqual(try Data(contentsOf: localStore.storageURL), corruptBytes)
    }

    func testRetryQuarantineClearsWriteBlock() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("nested-support-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let renameToggle = OperationToggle()
        let localStore = ProfileStore(
            deviceKey: "retry",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            renameEntry: { directoryFD, from, to in
                if renameToggle.fail {
                    throw POSIXError(.EACCES)
                }
                try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
            }
        )
        let corruptBytes = Data("{retry-me".utf8)
        try corruptBytes.write(to: localStore.storageURL)

        renameToggle.fail = true
        _ = localStore.loadOutcome()
        XCTAssertTrue(localStore.writesBlockedForCorruptSource)

        renameToggle.fail = false
        let quarantined = try localStore.retryQuarantineCorruptSource()
        XCTAssertFalse(localStore.writesBlockedForCorruptSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
        XCTAssertEqual(try Data(contentsOf: quarantined), corruptBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localStore.storageURL.path))
    }

    func testQuarantineCollisionPreservesOlderArtifact() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let collisionStore = ProfileStore(
            deviceKey: "collision",
            applicationSupportDirectory: tempDirectory,
            now: { fixedNow }
        )

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let stampText = stamp.string(from: fixedNow).replacingOccurrences(of: ":", with: "-")
        let olderURL = collisionStore.storageDirectoryURL
            .appendingPathComponent("profiles-collision-corrupt-\(stampText).json")
        let olderBytes = Data("older-quarantine-artifact".utf8)
        try olderBytes.write(to: olderURL)

        let newerCorrupt = Data("newer-corrupt-source".utf8)
        try newerCorrupt.write(to: collisionStore.storageURL)

        let outcome = collisionStore.loadOutcome()
        guard case let .recovered(_, quarantinedURL, _, _) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }

        XCTAssertNotEqual(quarantinedURL, olderURL)
        XCTAssertTrue(quarantinedURL.lastPathComponent.contains("-2.json"))
        XCTAssertEqual(try Data(contentsOf: olderURL), olderBytes)
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), newerCorrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
    }

    func testSuccessfulQuarantineAllowsPersistingDefaults() throws {
        try "{not-json".data(using: .utf8)!.write(to: store.storageURL)
        let outcome = store.loadOutcome()
        guard case let .recovered(bundle, quarantinedURL, _, _) = outcome else {
            return XCTFail("Expected recovered, got \(outcome)")
        }
        XCTAssertTrue(outcome.shouldPersistDefaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        try store.save(bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
    }
}

private final class OperationToggle {
    var fail = false
}
