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
        try store.save(bundle())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.storageDirectoryURL.path)
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
