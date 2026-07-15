import Darwin
import XCTest
@testable import RazerCore

final class ProfileSafetyValidatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("razer-profile-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    private func profile(
        name: String = "Safe",
        mappings: [PhysicalControl: ButtonAction] = [:]
    ) -> MouseProfile {
        MouseProfile(name: name, dpiStages: [800], activeStage: 1, pollingRateHz: 1000, buttonMappings: mappings)
    }

    private func bundle(_ profile: MouseProfile? = nil) -> ProfileBundle {
        let profile = profile ?? self.profile()
        return ProfileBundle(selectedProfileID: profile.id, profiles: [profile])
    }

    func testProfileAndNameLimits() throws {
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(ProfileBundle())) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidProfileCount(0))
        }
        let profiles = (0...ProfileSafetyLimits.maximumProfiles).map { _ in profile() }
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(ProfileBundle(profiles: profiles))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidProfileCount(51))
        }
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(name: " \n ")))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidProfileName)
        }
        let tooLongName = String(repeating: "a", count: ProfileSafetyLimits.maximumProfileNameUTF8Bytes + 1)
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(name: tooLongName)))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .profileNameTooLong(actual: 257))
        }

        let maximumProfiles = (0..<ProfileSafetyLimits.maximumProfiles).map { _ in profile(name: String(repeating: "a", count: 256)) }
        XCTAssertNoThrow(try ProfileSafetyValidator.validateAndRepair(ProfileBundle(profiles: maximumProfiles)))
    }

    func testDuplicateIDAndDanglingSelection() throws {
        let first = profile()
        var duplicate = profile()
        duplicate.id = first.id
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(ProfileBundle(profiles: [first, duplicate]))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .duplicateProfileID(first.id))
        }

        let repaired = try ProfileSafetyValidator.validateAndRepair(
            ProfileBundle(selectedProfileID: UUID(), profiles: [first])
        )
        XCTAssertEqual(repaired.bundle.selectedProfileID, first.id)
    }

    func testShortcutLimits() {
        XCTAssertNoThrow(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [
            .sideButton1: .keyboardShortcut(
                KeyboardShortcut(
                    keyCode: ProfileSafetyLimits.maximumVirtualKeyCode,
                    modifierFlags: ProfileSafetyLimits.allowedShortcutModifierMask
                )
            )
        ]))))
        let badMask = profile(mappings: [
            .sideButton1: .keyboardShortcut(KeyboardShortcut(keyCode: 12, modifierFlags: 0x0000_0001))
        ])
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(badMask))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidShortcut)
        }
        let badKey = profile(mappings: [
            .sideButton1: .keyboardShortcut(KeyboardShortcut(keyCode: ProfileSafetyLimits.maximumVirtualKeyCode + 1, modifierFlags: 0))
        ])
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(badKey))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidShortcut)
        }
    }

    func testURLLimitsAndScheme() {
        let tooLong = String(repeating: "a", count: ProfileSafetyLimits.maximumURLUTF8Bytes) + "https://example.com"
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openURL(tooLong)])))) {
            guard case .urlTooLong = $0 as? ProfileSafetyValidationError else {
                return XCTFail("Expected urlTooLong, got \($0)")
            }
        }
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openURL("file:///tmp/test")])))) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidURL)
        }
        let maximumURL = "https://" + String(repeating: "a", count: ProfileSafetyLimits.maximumURLUTF8Bytes - 8)
        XCTAssertNoThrow(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openURL(maximumURL)]))))
    }

    func testAppPathsAreValidatedAndMissingAppsAreDisabled() throws {
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openApp("relative.app")]))))
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openApp("/tmp/not-an-app")]))))
        let longPath = "/" + String(repeating: "a", count: ProfileSafetyLimits.maximumAppPathUTF8Bytes)
        XCTAssertThrowsError(try ProfileSafetyValidator.validateAndRepair(bundle(profile(mappings: [.sideButton1: .openApp(longPath)])))) {
            guard case .appPathTooLong = $0 as? ProfileSafetyValidationError else {
                return XCTFail("Expected appPathTooLong, got \($0)")
            }
        }

        let missing = temporaryDirectory.appendingPathComponent("Moved.app").path
        let repaired = try ProfileSafetyValidator.validateAndRepair(
            bundle(profile(mappings: [.sideButton1: .openApp(missing)]))
        )
        XCTAssertEqual(repaired.bundle.profiles[0].buttonMappings[.sideButton1], .disabled)
        XCTAssertFalse(repaired.repairWarnings.isEmpty)

        let fakeAppDirectory = temporaryDirectory.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeAppDirectory, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try ProfileSafetyValidator.validateAndRepair(
                bundle(profile(mappings: [.sideButton1: .openApp(fakeAppDirectory.path)]))
            )
        ) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .invalidAppPath)
        }

        let realApp = try makeMinimalApplicationBundle(named: "Example.app")
        let valid = try ProfileSafetyValidator.validateAndRepair(
            bundle(profile(mappings: [.sideButton1: .openApp(realApp.path)]))
        )
        XCTAssertEqual(valid.bundle.profiles[0].buttonMappings[.sideButton1], .openApp(realApp.path))
    }

    func testReadValidatedSourceFileRejectsSymlinkAndReadsInode() throws {
        let target = temporaryDirectory.appendingPathComponent("target.json")
        let payload = Data("{\"ok\":true}".utf8)
        try payload.write(to: target)
        let link = temporaryDirectory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ProfileSafetyValidator.readValidatedSourceFile(at: link)) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .sourceSymlink)
        }

        let readBack = try ProfileSafetyValidator.readValidatedSourceFile(at: target)
        XCTAssertEqual(readBack, payload)
    }

    func testSaveHardensExistingSupportDirectoryMode() throws {
        let support = temporaryDirectory.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)

        let store = ProfileStore(applicationSupportDirectory: temporaryDirectory)
        XCTAssertFalse(store.writesBlockedForUnsafeSupportDirectory)
        try store.save(bundle())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.storageDirectoryURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSymlinkedSupportDirectoryIsRejectedWithoutTouchingTarget() throws {
        let target = temporaryDirectory.appendingPathComponent("real-support", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let marker = target.appendingPathComponent("marker.txt")
        try Data("keep".utf8).write(to: marker)

        let link = temporaryDirectory.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = ProfileStore(applicationSupportDirectory: temporaryDirectory)
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)

        let outcome = store.loadOutcome()
        guard case let .firstRun(_, warning) = outcome else {
            return XCTFail("Expected firstRun, got \(outcome)")
        }
        XCTAssertEqual(warning, ProfileSafetyValidationError.supportDirectorySymlink.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))

        XCTAssertThrowsError(try store.save(bundle())) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectorySymlink)
            )
        }

        let targetMode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(targetMode?.intValue, 0o755)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testRegularFileAtSupportDirectoryPathIsRejected() throws {
        let file = temporaryDirectory.appendingPathComponent("RazerMenuBarApp")
        try Data("not-a-directory".utf8).write(to: file)

        let store = ProfileStore(applicationSupportDirectory: temporaryDirectory)
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)
        XCTAssertThrowsError(try store.save(bundle())) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectoryNotDirectory)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        let outcome = store.loadOutcome()
        guard case .firstRun = outcome else {
            return XCTFail("Expected firstRun, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testWrongOwnerSupportDirectoryFailsViaInjectableUID() throws {
        let support = temporaryDirectory.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let store = ProfileStore(
            applicationSupportDirectory: temporaryDirectory,
            currentUID: { getuid() &+ 1 }
        )
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)
        XCTAssertThrowsError(try store.save(bundle())) { error in
            guard case let ProfileStoreError.unsafeSupportDirectory(inner) = error,
                  case .supportDirectoryWrongOwner = inner else {
                return XCTFail("Expected supportDirectoryWrongOwner, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testChmodFailureBlocksLoadAndSaveWithoutCreatingProfileFile() throws {
        let store = ProfileStore(
            applicationSupportDirectory: temporaryDirectory,
            fchmodDirectory: { _, _ in
                throw POSIXError(.EPERM)
            }
        )
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)

        let outcome = store.loadOutcome()
        guard case let .firstRun(_, warning) = outcome else {
            return XCTFail("Expected firstRun, got \(outcome)")
        }
        XCTAssertNotNil(warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))

        XCTAssertThrowsError(try store.save(bundle())) { error in
            guard case ProfileStoreError.unsafeSupportDirectory = error else {
                return XCTFail("Expected unsafeSupportDirectory, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testDirectorySwapBeforeHardeningLeavesReplacementAndTargetUntouched() throws {
        let support = temporaryDirectory.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        let target = temporaryDirectory.appendingPathComponent("swap-target", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let marker = target.appendingPathComponent("marker.txt")
        let markerBytes = Data("do-not-touch".utf8)
        try markerBytes.write(to: marker)

        XCTAssertThrowsError(
            try ProfileSafetyValidator.prepareSupportDirectory(
                at: support,
                openDirectory: { path in
                    // Simulate a pathname swap after the initial existence check and before open.
                    try FileManager.default.removeItem(at: support)
                    try FileManager.default.createSymbolicLink(at: support, withDestinationURL: target)
                    return try ProfileSafetyValidator.openSupportDirectoryFileDescriptor(atPath: path)
                }
            )
        ) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .supportDirectorySymlink)
        }

        let values = try support.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(values.isSymbolicLink == true)
        let targetMode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(targetMode?.intValue, 0o755)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
    }

    func testUnsafeSymlinkSupportDirectoryRejectsRetryQuarantineAndDiscard() throws {
        let fixture = try makeUnsafeSymlinkSupportFixture()
        let store = fixture.store

        XCTAssertThrowsError(try store.retryQuarantineCorruptSource()) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectorySymlink)
            )
        }
        XCTAssertThrowsError(try store.discardCorruptSourceAndAllowWrites()) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectorySymlink)
            )
        }
    }

    func testTargetProfileDataRemainsUnchangedAfterEveryRecoveryAction() throws {
        let fixture = try makeUnsafeSymlinkSupportFixture()
        let store = fixture.store

        // Exercise every recovery entry point; each must fail closed without touching the target.
        _ = store.loadOutcome()
        XCTAssertThrowsError(try store.retryQuarantineCorruptSource())
        XCTAssertThrowsError(try store.discardCorruptSourceAndAllowWrites())
        XCTAssertThrowsError(try store.save(bundle()))

        XCTAssertEqual(try Data(contentsOf: fixture.profileInTarget), fixture.profileBytes)
        let targetMode = try FileManager.default.attributesOfItem(atPath: fixture.target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(targetMode?.intValue, 0o755)
        let linkValues = try fixture.link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(linkValues.isSymbolicLink == true)
        let targetChildren = try FileManager.default.contentsOfDirectory(atPath: fixture.target.path)
        XCTAssertEqual(targetChildren, ["profiles-test-device.json"])
    }

    func testPostInitializationDirectorySwapRejectsRecoveryWithoutTouchingTarget() throws {
        let supportRoot = temporaryDirectory.appendingPathComponent("safe-root", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        let renameToggle = OperationToggle()
        let store = ProfileStore(
            deviceKey: "post-init",
            applicationSupportDirectory: supportRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            renameEntry: { directoryFD, from, to in
                if renameToggle.fail {
                    throw POSIXError(.EACCES)
                }
                try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
            }
        )
        XCTAssertFalse(store.writesBlockedForUnsafeSupportDirectory)

        let corruptBytes = Data("{post-init-corrupt".utf8)
        try corruptBytes.write(to: store.storageURL)
        renameToggle.fail = true
        _ = store.loadOutcome()
        XCTAssertTrue(store.writesBlockedForCorruptSource)
        // AppModel/SettingsView would offer quarantine/discard while the directory is still safe.
        XCTAssertTrue(store.allowsCorruptSourceRecoveryActions)

        let target = temporaryDirectory.appendingPathComponent("post-init-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let victim = target.appendingPathComponent("profiles-post-init.json")
        let victimBytes = Data("victim-profile-bytes".utf8)
        try victimBytes.write(to: victim)

        // Swap the previously validated support directory for a symlink after initialization.
        let supportDir = store.storageDirectoryURL
        try FileManager.default.removeItem(at: supportDir)
        try FileManager.default.createSymbolicLink(at: supportDir, withDestinationURL: target)

        // Live app-facing gate must hide destructive actions after the swap.
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)
        XCTAssertFalse(store.allowsCorruptSourceRecoveryActions)

        XCTAssertThrowsError(try store.retryQuarantineCorruptSource()) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectorySymlink)
            )
        }
        XCTAssertThrowsError(try store.discardCorruptSourceAndAllowWrites()) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .unsafeSupportDirectory(.supportDirectorySymlink)
            )
        }
        XCTAssertThrowsError(try store.save(bundle()))

        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        let targetMode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(targetMode?.intValue, 0o755)
        let targetChildren = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertEqual(Set(targetChildren), ["profiles-post-init.json"])
    }

    func testCheckUseWindowDirectorySwapDoesNotMutateSymlinkTarget() throws {
        let supportRoot = temporaryDirectory.appendingPathComponent("check-use-root", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        let target = temporaryDirectory.appendingPathComponent("check-use-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let victim = target.appendingPathComponent("profiles-check-use.json")
        let victimBytes = Data("check-use-victim".utf8)
        try victimBytes.write(to: victim)

        let supportDir = supportRoot.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        let orphanedReal = supportRoot.appendingPathComponent("orphaned-real-support", isDirectory: true)
        var didSwapDuringMutation = false
        let store = ProfileStore(
            deviceKey: "check-use",
            applicationSupportDirectory: supportRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            directoryReadyProbe: { _ in
                guard !didSwapDuringMutation else { return }
                didSwapDuringMutation = true
                // Move the validated inode aside and plant a symlink at the pathname. Mutations must
                // stay on the held FD (orphaned inode), never follow into `target`.
                try? FileManager.default.moveItem(at: supportDir, to: orphanedReal)
                try? FileManager.default.createSymbolicLink(at: supportDir, withDestinationURL: target)
            }
        )

        try store.save(bundle())
        XCTAssertTrue(didSwapDuringMutation)

        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        let targetMode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(targetMode?.intValue, 0o755)
        let targetChildren = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertEqual(Set(targetChildren), ["profiles-check-use.json"])

        let linkValues = try supportDir.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(linkValues.isSymbolicLink == true)
        // Profile bytes landed on the orphaned real directory inode, not the symlink target.
        let orphanedProfile = orphanedReal.appendingPathComponent("profiles-check-use.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanedProfile.path))
    }

    /// Mirrors AppModel.allowsCorruptSourceRecoveryActions / SettingsView recovery-button gating.
    func testAppFacingRecoveryGateHidesActionsWhenSupportDirectoryIsUnsafe() throws {
        let fixture = try makeUnsafeSymlinkSupportFixture()
        let store = fixture.store

        // Same property AppModel forwards to SettingsView.
        let allowsCorruptSourceRecoveryActions = store.allowsCorruptSourceRecoveryActions
        XCTAssertFalse(allowsCorruptSourceRecoveryActions)
        XCTAssertTrue(store.areWritesBlocked)

        let outcome = store.loadOutcome()
        guard case let .firstRun(_, warning) = outcome else {
            return XCTFail("Expected firstRun under unsafe support directory, got \(outcome)")
        }
        XCTAssertNotNil(warning)
        XCTAssertFalse(store.allowsCorruptSourceRecoveryActions)
        XCTAssertFalse(store.writesBlockedForCorruptSource)
    }

    func testPrepareSupportDirectoryHardensExisting0755() throws {
        let support = temporaryDirectory.appendingPathComponent("owned-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)

        try ProfileSafetyValidator.prepareSupportDirectory(at: support)
        let attributes = try FileManager.default.attributesOfItem(atPath: support.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testInspectRejectsSymlinksAndOversizedFiles() throws {
        let target = temporaryDirectory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = temporaryDirectory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ProfileSafetyValidator.inspectSourceFile(at: link)) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .sourceSymlink)
        }

        let oversized = temporaryDirectory.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: ProfileSafetyLimits.maximumFileBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try ProfileSafetyValidator.inspectSourceFile(at: oversized)) {
            guard case .sourceTooLarge = $0 as? ProfileSafetyValidationError else {
                return XCTFail("Expected sourceTooLarge, got \($0)")
            }
        }

        let maximum = temporaryDirectory.appendingPathComponent("maximum.json")
        try Data(repeating: 0, count: ProfileSafetyLimits.maximumFileBytes).write(to: maximum)
        XCTAssertNoThrow(try ProfileSafetyValidator.inspectSourceFile(at: maximum))
    }

    func testInspectAcceptsCurrentOwnerRegularFile() throws {
        let file = temporaryDirectory.appendingPathComponent("owned.json")
        try Data("{}".utf8).write(to: file)
        try ProfileSafetyValidator.inspectSourceFile(at: file)
    }

    func testInspectRejectsNonRegularFiles() {
        XCTAssertThrowsError(try ProfileSafetyValidator.inspectSourceFile(at: temporaryDirectory)) {
            XCTAssertEqual($0 as? ProfileSafetyValidationError, .sourceNotRegularFile)
        }
    }

    func testSaveSetsOwnerOnlyFileMode() throws {
        let store = ProfileStore(applicationSupportDirectory: temporaryDirectory)
        try store.save(bundle())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.storageURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private struct UnsafeSymlinkSupportFixture {
        let store: ProfileStore
        let target: URL
        let link: URL
        let profileInTarget: URL
        let profileBytes: Data
    }

    private func makeUnsafeSymlinkSupportFixture() throws -> UnsafeSymlinkSupportFixture {
        let target = temporaryDirectory.appendingPathComponent("real-support", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let profileBytes = Data("{\"profiles\":[]}".utf8)
        let profileInTarget = target.appendingPathComponent("profiles-test-device.json")
        try profileBytes.write(to: profileInTarget)

        let link = temporaryDirectory.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = ProfileStore(
            deviceKey: "test-device",
            applicationSupportDirectory: temporaryDirectory
        )
        XCTAssertTrue(store.writesBlockedForUnsafeSupportDirectory)
        return UnsafeSymlinkSupportFixture(
            store: store,
            target: target,
            link: link,
            profileInTarget: profileInTarget,
            profileBytes: profileBytes
        )
    }

    private func makeMinimalApplicationBundle(named name: String) throws -> URL {
        let appURL = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.razerviper.test.\(UUID().uuidString)</string>
            <key>CFBundleName</key>
            <string>Example</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleExecutable</key>
            <string>Example</string>
        </dict>
        </plist>
        """
        try Data(infoPlist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: macOS.appendingPathComponent("Example"))
        return appURL
    }
}

/// Force rename failures for quarantine paths without changing directory mode.
private final class OperationToggle {
    var fail = false
}

/// Shared helper for move-failure style tests that still use FileManager seams elsewhere.
private final class ToggleFileManager: FileManager, @unchecked Sendable {
    var failMoves = false

    override func moveItem(at src: URL, to dst: URL) throws {
        if failMoves {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)
        }
        try super.moveItem(at: src, to: dst)
    }
}
