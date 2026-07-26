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
            limits: .viperV3HyperSpeed,
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
            XCTAssertEqual(error as? ProfileStoreError, .validation(.invalidDPI(50, allowed: 100...30_000)))
        }

        let after = try Data(contentsOf: store.storageURL)
        XCTAssertEqual(before, after)
    }

    func testActualWriteFailureIsReported() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("write-fail-support", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let fchmodToggle = OperationToggle()
        let localStore = ProfileStore(
            limits: .viperV3HyperSpeed,
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
            limits: .viperV3HyperSpeed,
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
            limits: .viperV3HyperSpeed,
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
            limits: .viperV3HyperSpeed,
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
            limits: .viperV3HyperSpeed,
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

    // MARK: - Quarantine list + guided restore (Task 16)

    private func makeValidProfile(name: String, id: UUID = UUID()) -> MouseProfile {
        MouseProfile(
            id: id,
            name: name,
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
    }

    private func writeQuarantineArtifact(
        named fileName: String,
        bundle: ProfileBundle,
        modificationDate: Date
    ) throws -> URL {
        let url = store.storageDirectoryURL.appendingPathComponent(fileName)
        try JSONEncoder().encode(bundle).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
        return url
    }

    func testListQuarantineArtifactsFiltersAndOrdersByNewest() throws {
        let older = try writeQuarantineArtifact(
            named: "profiles-test-device-corrupt-2020-01-01T00-00-00Z.json",
            bundle: ProfileBundle(
                selectedProfileID: nil,
                profiles: [makeValidProfile(name: "Older")]
            ),
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = try writeQuarantineArtifact(
            named: "profiles-test-device-corrupt-2021-01-01T00-00-00Z.json",
            bundle: ProfileBundle(
                selectedProfileID: nil,
                profiles: [makeValidProfile(name: "Newer")]
            ),
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        // Wrong device key — must not appear.
        _ = try writeQuarantineArtifact(
            named: "profiles-other-device-corrupt-2022-01-01T00-00-00Z.json",
            bundle: ProfileBundle(
                selectedProfileID: nil,
                profiles: [makeValidProfile(name: "Other")]
            ),
            modificationDate: Date(timeIntervalSince1970: 3_000)
        )
        // Primary file — must not appear.
        try store.save(
            ProfileBundle(
                selectedProfileID: nil,
                profiles: [makeValidProfile(name: "Primary")]
            )
        )

        let listed = try store.listQuarantineArtifacts()
        XCTAssertEqual(listed.map(\.lastPathComponent), [
            newer.lastPathComponent,
            older.lastPathComponent
        ])
        XCTAssertFalse(listed.contains(where: { $0.lastPathComponent == store.storageURL.lastPathComponent }))
        XCTAssertFalse(listed.contains(where: { $0.lastPathComponent.contains("other-device") }))
    }

    func testAttemptRestoreValidQuarantineReplacesPrimaryWithoutNewQuarantine() throws {
        let primaryID = UUID()
        let primary = makeValidProfile(name: "Primary", id: primaryID)
        try store.save(ProfileBundle(selectedProfileID: primaryID, profiles: [primary]))
        let primaryBefore = try Data(contentsOf: store.storageURL)

        let restoredID = UUID()
        let restoredProfile = makeValidProfile(name: "Restored", id: restoredID)
        let quarantineBundle = ProfileBundle(
            selectedProfileID: restoredID,
            profiles: [restoredProfile]
        )
        let quarantineURL = try writeQuarantineArtifact(
            named: "profiles-test-device-corrupt-restore-valid.json",
            bundle: quarantineBundle,
            modificationDate: Date(timeIntervalSince1970: 5_000)
        )
        let quarantineBytesBefore = try Data(contentsOf: quarantineURL)
        let quarantineCountBefore = try store.listQuarantineArtifacts().count

        let result = try store.attemptRestore(from: quarantineURL)
        XCTAssertEqual(result.profiles.first?.name, "Restored")
        XCTAssertEqual(result.selectedProfileID, restoredID)
        XCTAssertEqual(result.schemaVersion, ProfileBundle.currentSchemaVersion)

        let primaryAfter = try Data(contentsOf: store.storageURL)
        XCTAssertNotEqual(primaryAfter, primaryBefore)
        let onDisk = try JSONDecoder().decode(ProfileBundle.self, from: primaryAfter)
        XCTAssertEqual(onDisk.profiles.first?.name, "Restored")

        // Quarantine artifact untouched; no additional quarantine created.
        XCTAssertEqual(try Data(contentsOf: quarantineURL), quarantineBytesBefore)
        XCTAssertEqual(try store.listQuarantineArtifacts().count, quarantineCountBefore)
    }

    func testAttemptRestoreInvalidQuarantineLeavesPrimaryAndArtifactUntouched() throws {
        let primaryID = UUID()
        try store.save(
            ProfileBundle(
                selectedProfileID: primaryID,
                profiles: [makeValidProfile(name: "Keep", id: primaryID)]
            )
        )
        let primaryBefore = try Data(contentsOf: store.storageURL)

        let quarantineURL = store.storageDirectoryURL
            .appendingPathComponent("profiles-test-device-corrupt-invalid.json")
        let badBytes = Data("{not-valid-json".utf8)
        try badBytes.write(to: quarantineURL)

        XCTAssertThrowsError(try store.attemptRestore(from: quarantineURL))

        XCTAssertEqual(try Data(contentsOf: store.storageURL), primaryBefore)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), badBytes)
        XCTAssertEqual(try store.listQuarantineArtifacts().count, 1)
    }

    func testAttemptRestoreRejectsOutOfDirectoryAndWrongDeviceURLs() throws {
        let primaryID = UUID()
        try store.save(
            ProfileBundle(
                selectedProfileID: primaryID,
                profiles: [makeValidProfile(name: "Primary", id: primaryID)]
            )
        )
        let primaryBefore = try Data(contentsOf: store.storageURL)

        let outside = tempDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).json")
        try JSONEncoder().encode(
            ProfileBundle(profiles: [makeValidProfile(name: "Outside")])
        ).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try store.attemptRestore(from: outside)) { error in
            guard case .invalidRestoreSource = error as? ProfileStoreError else {
                return XCTFail("Expected invalidRestoreSource, got \(error)")
            }
        }

        let wrongDevice = try writeQuarantineArtifact(
            named: "profiles-wrong-device-corrupt-x.json",
            bundle: ProfileBundle(profiles: [makeValidProfile(name: "Wrong")]),
            modificationDate: Date()
        )
        XCTAssertThrowsError(try store.attemptRestore(from: wrongDevice)) { error in
            guard case .invalidRestoreSource = error as? ProfileStoreError else {
                return XCTFail("Expected invalidRestoreSource, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: store.storageURL), primaryBefore)
    }

    func testAttemptRestoreRejectsSymlinkWithoutFollowingTarget() throws {
        let primaryID = UUID()
        try store.save(
            ProfileBundle(
                selectedProfileID: primaryID,
                profiles: [makeValidProfile(name: "Primary", id: primaryID)]
            )
        )
        let primaryBefore = try Data(contentsOf: store.storageURL)

        let target = tempDirectory.appendingPathComponent("restore-symlink-target.json")
        let targetBytes = try JSONEncoder().encode(
            ProfileBundle(profiles: [makeValidProfile(name: "Target")])
        )
        try targetBytes.write(to: target)

        let linkURL = store.storageDirectoryURL
            .appendingPathComponent("profiles-test-device-corrupt-symlink.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.attemptRestore(from: linkURL))

        XCTAssertEqual(try Data(contentsOf: store.storageURL), primaryBefore)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func testAttemptRestoreRejectsUnsupportedSchemaWithoutTouchingPrimary() throws {
        let primaryID = UUID()
        try store.save(
            ProfileBundle(
                selectedProfileID: primaryID,
                profiles: [makeValidProfile(name: "Primary", id: primaryID)]
            )
        )
        let primaryBefore = try Data(contentsOf: store.storageURL)

        let futureID = UUID()
        let future = ProfileBundle(
            selectedProfileID: futureID,
            profiles: [makeValidProfile(name: "Future", id: futureID)],
            schemaVersion: 99
        )
        let quarantineURL = try writeQuarantineArtifact(
            named: "profiles-test-device-corrupt-future.json",
            bundle: future,
            modificationDate: Date()
        )
        let quarantineBefore = try Data(contentsOf: quarantineURL)

        XCTAssertThrowsError(try store.attemptRestore(from: quarantineURL))

        XCTAssertEqual(try Data(contentsOf: store.storageURL), primaryBefore)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), quarantineBefore)
    }

    func testAttemptRestoreWriteFailureLeavesPrimaryUntouched() throws {
        let nestedSupport = tempDirectory.appendingPathComponent("restore-write-fail", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let fchmodToggle = OperationToggle()
        let localStore = ProfileStore(
            limits: .viperV3HyperSpeed,
            deviceKey: "restore-write-fail",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            fchmodFile: { fd, mode in
                if fchmodToggle.fail {
                    throw POSIXError(.EPERM)
                }
                if fchmod(fd, mode) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                }
            }
        )

        let primaryID = UUID()
        try localStore.save(
            ProfileBundle(
                selectedProfileID: primaryID,
                profiles: [makeValidProfile(name: "Primary", id: primaryID)]
            )
        )
        let primaryBefore = try Data(contentsOf: localStore.storageURL)

        let restoredID = UUID()
        let quarantineURL = localStore.storageDirectoryURL
            .appendingPathComponent("profiles-restore-write-fail-corrupt-ok.json")
        try JSONEncoder().encode(
            ProfileBundle(
                selectedProfileID: restoredID,
                profiles: [makeValidProfile(name: "Restored", id: restoredID)]
            )
        ).write(to: quarantineURL)
        let quarantineBefore = try Data(contentsOf: quarantineURL)

        fchmodToggle.fail = true
        XCTAssertThrowsError(try localStore.attemptRestore(from: quarantineURL))

        XCTAssertEqual(try Data(contentsOf: localStore.storageURL), primaryBefore)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), quarantineBefore)
    }

    func testAttemptRestoreRejectsWhileCorruptSourceWriteBlocked() throws {
        let renameToggle = OperationToggle()
        let nestedSupport = tempDirectory.appendingPathComponent("restore-block-reject", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSupport, withIntermediateDirectories: true)

        let localStore = ProfileStore(
            limits: .viperV3HyperSpeed,
            deviceKey: "restore-block",
            applicationSupportDirectory: nestedSupport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            renameEntry: { directoryFD, from, to in
                if renameToggle.fail {
                    throw POSIXError(.EACCES)
                }
                try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
            }
        )

        // Force corrupt-preserved primary (writes blocked).
        let blockedPrimary = Data("{broken-must-survive-restore".utf8)
        try blockedPrimary.write(to: localStore.storageURL)
        renameToggle.fail = true
        _ = localStore.loadOutcome()
        XCTAssertTrue(localStore.writesBlockedForCorruptSource)

        let restoredID = UUID()
        let quarantineURL = localStore.storageDirectoryURL
            .appendingPathComponent("profiles-restore-block-corrupt-good.json")
        let quarantineBytes = try JSONEncoder().encode(
            ProfileBundle(
                selectedProfileID: restoredID,
                profiles: [makeValidProfile(name: "FromQuarantine", id: restoredID)]
            )
        )
        try quarantineBytes.write(to: quarantineURL)

        // Even with a valid quarantine artifact, restore must not replace the unquarantined primary.
        renameToggle.fail = false
        XCTAssertThrowsError(try localStore.attemptRestore(from: quarantineURL)) { error in
            guard case .writeBlockedCorruptSource = error as? ProfileStoreError else {
                return XCTFail("Expected writeBlockedCorruptSource, got \(error)")
            }
        }
        XCTAssertTrue(localStore.writesBlockedForCorruptSource)
        XCTAssertEqual(try Data(contentsOf: localStore.storageURL), blockedPrimary)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), quarantineBytes)
    }

    func testListQuarantineExcludesSymlinksAndNonRegularEntries() throws {
        let valid = try writeQuarantineArtifact(
            named: "profiles-test-device-corrupt-regular.json",
            bundle: ProfileBundle(profiles: [makeValidProfile(name: "Regular")]),
            modificationDate: Date(timeIntervalSince1970: 4_000)
        )

        let target = tempDirectory.appendingPathComponent("list-symlink-target.json")
        try JSONEncoder().encode(
            ProfileBundle(profiles: [makeValidProfile(name: "SymlinkTarget")])
        ).write(to: target)
        let linkURL = store.storageDirectoryURL
            .appendingPathComponent("profiles-test-device-corrupt-symlink.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        let dirURL = store.storageDirectoryURL
            .appendingPathComponent("profiles-test-device-corrupt-directory.json")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let listed = try store.listQuarantineArtifacts()
        XCTAssertEqual(listed.map(\.lastPathComponent), [valid.lastPathComponent])
        XCTAssertFalse(listed.contains(where: { $0.lastPathComponent.contains("symlink") }))
        XCTAssertFalse(listed.contains(where: { $0.lastPathComponent.contains("directory") }))
    }

    func testConcurrentSaveLoadListStressKeepsValidBundles() throws {
        let stressRoot = tempDirectory.appendingPathComponent("concurrent-stress", isDirectory: true)
        try FileManager.default.createDirectory(at: stressRoot, withIntermediateDirectories: true)
        let stressStore = ProfileStore(
            limits: .viperV3HyperSpeed,
            deviceKey: "stress",
            applicationSupportDirectory: stressRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let idA = UUID()
        let idB = UUID()
        let bundleA = ProfileBundle(
            selectedProfileID: idA,
            profiles: [makeValidProfile(name: "Alpha", id: idA)]
        )
        let bundleB = ProfileBundle(
            selectedProfileID: idB,
            profiles: [makeValidProfile(name: "Beta", id: idB)]
        )
        try stressStore.save(bundleA)

        let errorLock = NSLock()
        var failures: [String] = []
        func recordFailure(_ message: String) {
            errorLock.lock()
            failures.append(message)
            errorLock.unlock()
        }

        let iterations = 120
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                switch index % 5 {
                case 0:
                    try stressStore.save(index % 2 == 0 ? bundleA : bundleB)
                case 1:
                    let outcome = stressStore.loadOutcome()
                    switch outcome {
                    case let .loaded(bundle, _), let .firstRun(bundle, _):
                        _ = try ProfileSafetyValidator.validateAndRepair(bundle, limits: .viperV3HyperSpeed)
                        guard bundle.profiles.count == 1,
                              ["Alpha", "Beta", "Default"].contains(bundle.profiles[0].name) else {
                            recordFailure("unexpected loaded profile set: \(bundle.profiles.map(\.name))")
                            return
                        }
                    case let .recovered(_, _, reason, _):
                        recordFailure("unexpected recovered under concurrent valid ops: \(reason)")
                    case let .corruptPreserved(_, _, reason):
                        recordFailure("unexpected corruptPreserved under concurrent valid ops: \(reason)")
                    }
                case 2:
                    _ = try stressStore.listQuarantineArtifacts()
                    _ = stressStore.writesBlockedForCorruptSource
                    _ = stressStore.areWritesBlocked
                    _ = stressStore.allowsCorruptSourceRecoveryActions
                case 3:
                    try stressStore.save(bundleA)
                    let outcome = stressStore.loadOutcome()
                    if case .recovered = outcome {
                        recordFailure("save+load pair produced recovered")
                    } else if case .corruptPreserved = outcome {
                        recordFailure("save+load pair produced corruptPreserved")
                    } else {
                        _ = try ProfileSafetyValidator.validateAndRepair(outcome.bundle, limits: .viperV3HyperSpeed)
                    }
                default:
                    _ = stressStore.refreshSupportDirectorySafety()
                    _ = try stressStore.uniqueQuarantineURL()
                }
            } catch {
                recordFailure("iteration \(index) threw: \(error)")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))

        let finalOutcome = stressStore.loadOutcome()
        guard case let .loaded(finalBundle, warning) = finalOutcome else {
            return XCTFail("Expected final loaded outcome, got \(finalOutcome)")
        }
        XCTAssertNil(warning)
        XCTAssertNoThrow(try ProfileSafetyValidator.validateAndRepair(finalBundle, limits: .viperV3HyperSpeed))
        let onDisk = try JSONDecoder().decode(
            ProfileBundle.self,
            from: Data(contentsOf: stressStore.storageURL)
        )
        XCTAssertNoThrow(try ProfileSafetyValidator.validateAndRepair(onDisk, limits: .viperV3HyperSpeed))
        XCTAssertEqual(onDisk.schemaVersion, ProfileBundle.currentSchemaVersion)
        XCTAssertEqual(onDisk.profiles.count, 1)
        XCTAssertTrue(["Alpha", "Beta"].contains(onDisk.profiles[0].name))
    }

    func testListQuarantineDoesNotFollowPathnameSwapViaDirectoryReadyProbe() throws {
        let supportRoot = tempDirectory.appendingPathComponent("list-swap-root", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        // Seed a real quarantine artifact on the eventual support directory inode.
        let prep = ProfileStore(
            limits: .viperV3HyperSpeed,
            deviceKey: "list-swap",
            applicationSupportDirectory: supportRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let realQuarantineName = "profiles-list-swap-corrupt-real.json"
        let realURL = prep.storageDirectoryURL.appendingPathComponent(realQuarantineName)
        try JSONEncoder().encode(
            ProfileBundle(profiles: [makeValidProfile(name: "Real")])
        ).write(to: realURL)

        let supportDir = prep.storageDirectoryURL
        let orphanedReal = supportRoot.appendingPathComponent("orphaned-real-support", isDirectory: true)
        let attacker = supportRoot.appendingPathComponent("attacker-target", isDirectory: true)
        try FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        let fakeName = "profiles-list-swap-corrupt-fake.json"
        let fakeBytes = Data("attacker-should-never-be-listed".utf8)
        try fakeBytes.write(to: attacker.appendingPathComponent(fakeName))

        var didSwap = false
        let listingStore = ProfileStore(
            limits: .viperV3HyperSpeed,
            deviceKey: "list-swap",
            applicationSupportDirectory: supportRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            directoryReadyProbe: { _ in
                guard !didSwap else { return }
                didSwap = true
                // After FD validation, replace the pathname with a symlink into attacker.
                try? FileManager.default.moveItem(at: supportDir, to: orphanedReal)
                try? FileManager.default.createSymbolicLink(at: supportDir, withDestinationURL: attacker)
            }
        )

        let listed = try listingStore.listQuarantineArtifacts()
        XCTAssertTrue(didSwap)
        XCTAssertEqual(listed.map(\.lastPathComponent), [realQuarantineName])
        XCTAssertFalse(listed.contains(where: { $0.lastPathComponent == fakeName }))
        // Attacker payload must remain unread/unmutated.
        XCTAssertEqual(
            try Data(contentsOf: attacker.appendingPathComponent(fakeName)),
            fakeBytes
        )
        // Real artifact still lives on the orphaned inode held by the FD path.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: orphanedReal.appendingPathComponent(realQuarantineName).path
            )
        )
    }
}

private final class OperationToggle {
    var fail = false
}
