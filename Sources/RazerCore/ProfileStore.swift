import Darwin
import Foundation

public struct MouseProfile: Codable, Identifiable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, name, dpiStages, activeStage, pollingRateHz, autoReapplyEnabled
        case buttonMappings, wheelSettings, remapperEnabled
    }

    public var id: UUID
    public var name: String
    public var dpiStages: [Int]
    public var activeStage: Int
    public var pollingRateHz: Int
    public var autoReapplyEnabled: Bool
    public var buttonMappings: [PhysicalControl: ButtonAction]
    public var wheelSettings: WheelSettings
    public var remapperEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        dpiStages: [Int],
        activeStage: Int,
        pollingRateHz: Int,
        autoReapplyEnabled: Bool = true,
        buttonMappings: [PhysicalControl: ButtonAction] = PhysicalControl.defaultButtonMappings(),
        wheelSettings: WheelSettings = .default,
        remapperEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.dpiStages = dpiStages
        self.activeStage = activeStage
        self.pollingRateHz = pollingRateHz
        self.autoReapplyEnabled = autoReapplyEnabled
        self.buttonMappings = buttonMappings
        self.wheelSettings = wheelSettings
        self.remapperEnabled = remapperEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dpiStages = try container.decode([Int].self, forKey: .dpiStages)
        activeStage = try container.decode(Int.self, forKey: .activeStage)
        pollingRateHz = try container.decode(Int.self, forKey: .pollingRateHz)
        autoReapplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReapplyEnabled) ?? true
        buttonMappings = try container.decodeIfPresent([PhysicalControl: ButtonAction].self, forKey: .buttonMappings)
            ?? PhysicalControl.defaultButtonMappings()
        wheelSettings = try container.decodeIfPresent(WheelSettings.self, forKey: .wheelSettings) ?? .default
        remapperEnabled = try container.decodeIfPresent(Bool.self, forKey: .remapperEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(dpiStages, forKey: .dpiStages)
        try container.encode(activeStage, forKey: .activeStage)
        try container.encode(pollingRateHz, forKey: .pollingRateHz)
        try container.encode(autoReapplyEnabled, forKey: .autoReapplyEnabled)
        try container.encode(buttonMappings, forKey: .buttonMappings)
        try container.encode(wheelSettings, forKey: .wheelSettings)
        try container.encode(remapperEnabled, forKey: .remapperEnabled)
    }

    public var activeDPI: Int {
        guard !dpiStages.isEmpty else { return DeviceDescriptor.minDPI }
        let index = min(max(activeStage - 1, 0), dpiStages.count - 1)
        return dpiStages[index]
    }

    public mutating func resetControlsToDefaults() {
        buttonMappings = PhysicalControl.defaultButtonMappings()
        wheelSettings = .default
        remapperEnabled = false
    }

    /// Folds legacy `.middleClick` mappings into `.wheelClick` and removes the alias key.
    public mutating func migrateButton2Alias() {
        let wheel = buttonMappings[.wheelClick] ?? .passthrough
        let middle = buttonMappings[.middleClick] ?? .passthrough
        if wheel == .passthrough, middle != .passthrough {
            buttonMappings[.wheelClick] = middle
        }
        buttonMappings.removeValue(forKey: .middleClick)
    }
}

public struct ProfileBundle: Codable, Equatable, Sendable {
    /// On-disk schema version written by this build. Bump when the bundle shape changes.
    public static let currentSchemaVersion = 2
    /// Legacy files without `schemaVersion` decode as this value before load-time upgrade.
    public static let legacySchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedProfileID, profiles
    }

    public var schemaVersion: Int
    public var selectedProfileID: UUID?
    public var profiles: [MouseProfile]

    public init(
        selectedProfileID: UUID? = nil,
        profiles: [MouseProfile] = [],
        schemaVersion: Int = ProfileBundle.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.selectedProfileID = selectedProfileID
        self.profiles = profiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only schemaVersion is missing-key compatible (pre-versioning files → legacy v1).
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ProfileBundle.legacySchemaVersion
        selectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        // profiles remains required, matching the pre-schema synthesized Codable contract.
        profiles = try container.decode([MouseProfile].self, forKey: .profiles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(selectedProfileID, forKey: .selectedProfileID)
        try container.encode(profiles, forKey: .profiles)
    }

    public var selectedProfile: MouseProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }
}

public enum ProfileLoadOutcome: Equatable, Sendable {
    case loaded(ProfileBundle, persistenceWarning: String?)
    case firstRun(ProfileBundle, persistenceWarning: String?)
    /// Corrupt source was moved aside successfully; defaults may be persisted.
    case recovered(ProfileBundle, quarantinedURL: URL, reason: String, persistenceWarning: String?)
    /// Quarantine failed; corrupt source must not be overwritten until quarantined or discarded.
    case corruptPreserved(ProfileBundle, sourceURL: URL, reason: String)

    public var bundle: ProfileBundle {
        switch self {
        case let .loaded(bundle, _), let .firstRun(bundle, _), let .recovered(bundle, _, _, _), let .corruptPreserved(bundle, _, _):
            return bundle
        }
    }

    public var persistenceWarning: String? {
        switch self {
        case let .loaded(_, warning), let .firstRun(_, warning), let .recovered(_, _, _, warning):
            return warning
        case let .corruptPreserved(_, _, reason):
            return reason
        }
    }

    /// Whether it is safe to write a default bundle to the primary storage URL immediately after load.
    public var shouldPersistDefaults: Bool {
        switch self {
        case let .firstRun(_, warning):
            // A persistenceWarning on firstRun means the support directory or initial save is unsafe.
            return warning == nil
        case .recovered:
            return true
        case .loaded, .corruptPreserved:
            return false
        }
    }
}

public enum ProfileStoreError: Error, LocalizedError, Equatable {
    case validation(RazerValidationError)
    case safetyValidation(ProfileSafetyValidationError)
    case writeFailed(String)
    case quarantineFailed(String)
    case writeBlockedCorruptSource(String)
    case unsafeSupportDirectory(ProfileSafetyValidationError)
    /// Restore source is outside the support dir, wrong device, not a quarantine name, etc.
    case invalidRestoreSource(String)

    public var errorDescription: String? {
        switch self {
        case let .validation(error):
            return error.localizedDescription
        case let .safetyValidation(error):
            return error.localizedDescription
        case let .writeFailed(details):
            return "Failed to save profiles: \(details)"
        case let .quarantineFailed(details):
            return "Failed to quarantine corrupt profiles: \(details)"
        case let .writeBlockedCorruptSource(path):
            return "Profile saves are blocked until the corrupt file is quarantined or discarded: \(path)"
        case let .unsafeSupportDirectory(error):
            return error.localizedDescription
        case let .invalidRestoreSource(details):
            return "Cannot restore quarantined profiles: \(details)"
        }
    }
}

public final class ProfileStore {
    private let fileURL: URL
    private let directoryURL: URL
    private let profileFileName: String
    private let deviceKey: String
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    private let currentUID: () -> uid_t
    private let openDirectory: (String) throws -> Int32
    private let fchmodDirectory: (Int32, mode_t) throws -> Void
    private let fchmodFile: (Int32, mode_t) throws -> Void
    private let renameEntry: (Int32, String, String) throws -> Void
    private let unlinkEntry: (Int32, String) throws -> Void
    /// Test seam: invoked after the support directory FD is validated and before mutation via that FD.
    private let directoryReadyProbe: ((Int32) -> Void)?
    /// Serializes all store operations that touch shared mutable state, encoder/decoder, or files.
    /// Recursive so nested public APIs (e.g. load → save defaults) cannot deadlock.
    private let storeLock = NSRecursiveLock()
    /// Cached result of the latest support-directory check. Revalidated before mutations and
    /// app-facing recovery gates so a post-init pathname swap cannot stay trusted.
    private var supportDirectoryError: ProfileSafetyValidationError?

    /// When true, `save` refuses to write the primary path so a corrupt source cannot be overwritten.
    private var writesBlockedForCorruptSourceStorage = false

    /// Thread-safe view of the durable corrupt-source write block.
    public var writesBlockedForCorruptSource: Bool {
        withStoreLock { writesBlockedForCorruptSourceStorage }
    }

    /// When true, support-directory validation failed and no profile files may be created.
    public var writesBlockedForUnsafeSupportDirectory: Bool {
        withStoreLock {
            _ = refreshSupportDirectorySafetyLocked()
            return supportDirectoryError != nil
        }
    }

    /// Combined write gate used by the app UI and recovery paths.
    public var areWritesBlocked: Bool {
        withStoreLock {
            writesBlockedForCorruptSourceStorage
                || (refreshSupportDirectorySafetyLocked() != nil)
        }
    }

    /// Corrupt-file quarantine/discard UI is only valid when the support directory itself is safe.
    /// Revalidates the directory so AppModel/SettingsView cannot offer destructive actions after a
    /// post-initialization swap to an unsafe path.
    public var allowsCorruptSourceRecoveryActions: Bool {
        withStoreLock {
            _ = refreshSupportDirectorySafetyLocked()
            return writesBlockedForCorruptSourceStorage && supportDirectoryError == nil
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        return try body()
    }

    public init(
        deviceKey: String = DeviceDescriptor.deviceKey,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        currentUID: @escaping () -> uid_t = { getuid() },
        openDirectory: @escaping (String) throws -> Int32 = { path in
            try ProfileSafetyValidator.openSupportDirectoryFileDescriptor(atPath: path)
        },
        fchmodDirectory: @escaping (Int32, mode_t) throws -> Void = { fd, mode in
            if fchmod(fd, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        },
        fchmodFile: @escaping (Int32, mode_t) throws -> Void = { fd, mode in
            if fchmod(fd, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        },
        renameEntry: @escaping (Int32, String, String) throws -> Void = { directoryFD, from, to in
            try ProfileSafetyValidator.renameEntry(directoryFD: directoryFD, from: from, to: to)
        },
        unlinkEntry: @escaping (Int32, String) throws -> Void = { directoryFD, fileName in
            try ProfileSafetyValidator.unlinkEntry(directoryFD: directoryFD, fileName: fileName)
        },
        directoryReadyProbe: ((Int32) -> Void)? = nil
    ) {
        self.deviceKey = deviceKey
        self.fileManager = fileManager
        self.now = now
        self.currentUID = currentUID
        self.openDirectory = openDirectory
        self.fchmodDirectory = fchmodDirectory
        self.fchmodFile = fchmodFile
        self.renameEntry = renameEntry
        self.unlinkEntry = unlinkEntry
        self.directoryReadyProbe = directoryReadyProbe

        let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        directoryURL = folder
        profileFileName = "profiles-\(deviceKey).json"
        fileURL = folder.appendingPathComponent(profileFileName)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Single-threaded init path; still goes through the locked helper for consistency.
        _ = refreshSupportDirectorySafety()
    }

    /// Re-runs FD-based support-directory hardening and updates the cached safety error.
    @discardableResult
    public func refreshSupportDirectorySafety() -> ProfileSafetyValidationError? {
        withStoreLock { refreshSupportDirectorySafetyLocked() }
    }

    @discardableResult
    private func refreshSupportDirectorySafetyLocked() -> ProfileSafetyValidationError? {
        do {
            try ProfileSafetyValidator.prepareSupportDirectory(
                at: directoryURL,
                fileManager: fileManager,
                currentUID: currentUID,
                openDirectory: openDirectory,
                fchmodDirectory: fchmodDirectory
            )
            supportDirectoryError = nil
        } catch let error as ProfileSafetyValidationError {
            supportDirectoryError = error
        } catch {
            supportDirectoryError = .supportDirectoryPermissionFailure(error.localizedDescription)
        }
        return supportDirectoryError
    }

    /// Opens and hardens the support directory, keeps that FD for `body`, then closes it.
    /// Pathname swaps after validation cannot redirect `body`'s `*at` mutations.
    /// Caller must already hold `storeLock` (public entry points lock first).
    private func withSafeSupportDirectoryFD<T>(_ body: (Int32) throws -> T) throws -> T {
        let fd: Int32
        do {
            fd = try ProfileSafetyValidator.openPreparedSupportDirectory(
                at: directoryURL,
                fileManager: fileManager,
                currentUID: currentUID,
                openDirectory: openDirectory,
                fchmodDirectory: fchmodDirectory
            )
        } catch let error as ProfileSafetyValidationError {
            supportDirectoryError = error
            throw ProfileStoreError.unsafeSupportDirectory(error)
        } catch {
            let wrapped = ProfileSafetyValidationError.supportDirectoryPermissionFailure(
                error.localizedDescription
            )
            supportDirectoryError = wrapped
            throw ProfileStoreError.unsafeSupportDirectory(wrapped)
        }
        defer { close(fd) }
        supportDirectoryError = nil
        // Probe runs while the store lock is held (reentrant). Injected callbacks must not
        // wait on a different lock that could invert with this one; re-entering ProfileStore is OK.
        directoryReadyProbe?(fd)
        return try body(fd)
    }

    public var storageURL: URL { fileURL }
    public var storageDirectoryURL: URL { directoryURL }

    /// Prefer `loadOutcome()` so callers retain recovery / persistence metadata.
    @available(*, deprecated, message: "Use loadOutcome().bundle to preserve recovery metadata")
    public func load() -> ProfileBundle {
        loadOutcome().bundle
    }

    public func loadOutcome() -> ProfileLoadOutcome {
        withStoreLock {
            do {
                return try withSafeSupportDirectoryFD { directoryFD in
                    try loadOutcome(directoryFD: directoryFD)
                }
            } catch let error as ProfileStoreError {
                if case let .unsafeSupportDirectory(validationError) = error {
                    return .firstRun(
                        defaultBundle(),
                        persistenceWarning: validationError.localizedDescription
                    )
                }
                return .firstRun(defaultBundle(), persistenceWarning: error.localizedDescription)
            } catch {
                return .firstRun(defaultBundle(), persistenceWarning: error.localizedDescription)
            }
        }
    }

    private func loadOutcome(directoryFD: Int32) throws -> ProfileLoadOutcome {
        writesBlockedForCorruptSourceStorage = false

        if !ProfileSafetyValidator.entryExists(directoryFD: directoryFD, fileName: profileFileName) {
            let defaults = defaultBundle()
            do {
                try save(defaults, directoryFD: directoryFD)
                return .firstRun(defaults, persistenceWarning: nil)
            } catch {
                return .firstRun(defaults, persistenceWarning: error.localizedDescription)
            }
        }

        let data: Data
        do {
            data = try ProfileSafetyValidator.readValidatedSourceFile(
                directoryFD: directoryFD,
                fileName: profileFileName
            )
        } catch {
            return quarantineAndRecover(
                directoryFD: directoryFD,
                reason: "unsafe or unreadable profile file: \(error.localizedDescription)"
            )
        }

        let decoded: ProfileBundle
        do {
            decoded = try decoder.decode(ProfileBundle.self, from: data)
        } catch {
            return quarantineAndRecover(
                directoryFD: directoryFD,
                reason: "malformed profile JSON: \(error.localizedDescription)"
            )
        }

        // Unsupported versions fail closed: future (> current) and sub-legacy (< 1).
        // Missing schemaVersion decodes as legacy v1 and is upgraded below; explicit 0/negative are not legacy.
        if decoded.schemaVersion > ProfileBundle.currentSchemaVersion
            || decoded.schemaVersion < ProfileBundle.legacySchemaVersion {
            return quarantineAndRecover(
                directoryFD: directoryFD,
                reason: "unsupported profile schema version \(decoded.schemaVersion) (supported \(ProfileBundle.legacySchemaVersion)...\(ProfileBundle.currentSchemaVersion))"
            )
        }

        var bundle = decoded
        for index in bundle.profiles.indices {
            bundle.profiles[index].migrateButton2Alias()
        }
        // Upgrade known legacy (explicit or missing-key v1) bundles to the current schema.
        if bundle.schemaVersion < ProfileBundle.currentSchemaVersion {
            bundle.schemaVersion = ProfileBundle.currentSchemaVersion
        }

        let validated: (bundle: ProfileBundle, repairWarnings: [String])
        do {
            validated = try ProfileSafetyValidator.validateAndRepair(bundle, fileManager: fileManager)
        } catch {
            return quarantineAndRecover(
                directoryFD: directoryFD,
                reason: "unsafe profile content: \(error.localizedDescription)"
            )
        }
        let repaired = validated.bundle
        if repaired != decoded {
            do {
                try save(repaired, directoryFD: directoryFD)
                return .loaded(
                    repaired,
                    persistenceWarning: validated.repairWarnings.isEmpty
                        ? nil
                        : validated.repairWarnings.joined(separator: " ")
                )
            } catch {
                let warnings = (validated.repairWarnings + [error.localizedDescription]).joined(separator: " ")
                return .loaded(repaired, persistenceWarning: warnings)
            }
        }
        return .loaded(
            repaired,
            persistenceWarning: validated.repairWarnings.isEmpty ? nil : validated.repairWarnings.joined(separator: " ")
        )
    }

    public func save(_ bundle: ProfileBundle) throws {
        try withStoreLock {
            try withSafeSupportDirectoryFD { directoryFD in
                try save(bundle, directoryFD: directoryFD)
            }
        }
    }

    private func save(_ bundle: ProfileBundle, directoryFD: Int32) throws {
        if writesBlockedForCorruptSourceStorage {
            throw ProfileStoreError.writeBlockedCorruptSource(fileURL.path)
        }

        // Reject unsupported versions; only known legacy (v1) is normalized up to current.
        // Do not silently upgrade impossible versions (0/negative) or accept future schemas.
        var normalized = bundle
        if normalized.schemaVersion > ProfileBundle.currentSchemaVersion
            || normalized.schemaVersion < ProfileBundle.legacySchemaVersion {
            throw ProfileStoreError.writeFailed(
                "unsupported profile schema version \(normalized.schemaVersion) (supported \(ProfileBundle.legacySchemaVersion)...\(ProfileBundle.currentSchemaVersion))"
            )
        }
        if normalized.schemaVersion < ProfileBundle.currentSchemaVersion {
            normalized.schemaVersion = ProfileBundle.currentSchemaVersion
        }

        let validated: (bundle: ProfileBundle, repairWarnings: [String])
        do {
            validated = try ProfileSafetyValidator.validateAndRepair(normalized, fileManager: fileManager)
        } catch let error as ProfileSafetyValidationError {
            if case let .invalidHardware(validationError) = error {
                throw ProfileStoreError.validation(validationError)
            }
            throw ProfileStoreError.safetyValidation(error)
        }

        do {
            let data = try encoder.encode(validated.bundle)
            try ProfileSafetyValidator.writeOwnerOnlyRegularFile(
                directoryFD: directoryFD,
                fileName: profileFileName,
                data: data,
                temporaryFileName: ".\(profileFileName).tmp",
                fchmodFile: fchmodFile
            )
        } catch let error as ProfileStoreError {
            throw error
        } catch let error as ProfileSafetyValidationError {
            throw ProfileStoreError.unsafeSupportDirectory(error)
        } catch {
            throw ProfileStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Retries moving the corrupt primary file aside, then clears the write block.
    @discardableResult
    public func retryQuarantineCorruptSource() throws -> URL {
        try withStoreLock {
            try withSafeSupportDirectoryFD { directoryFD in
                do {
                    if ProfileSafetyValidator.entryExists(directoryFD: directoryFD, fileName: profileFileName) {
                        let quarantineURL = try performQuarantineMove(directoryFD: directoryFD)
                        writesBlockedForCorruptSourceStorage = false
                        return quarantineURL
                    }
                    writesBlockedForCorruptSourceStorage = false
                    return try uniqueQuarantineURL(directoryFD: directoryFD)
                } catch let error as ProfileStoreError {
                    throw error
                } catch {
                    throw ProfileStoreError.quarantineFailed(error.localizedDescription)
                }
            }
        }
    }

    /// Explicitly removes the corrupt primary file and allows subsequent saves.
    public func discardCorruptSourceAndAllowWrites() throws {
        try withStoreLock {
            try withSafeSupportDirectoryFD { directoryFD in
                do {
                    if ProfileSafetyValidator.entryExists(directoryFD: directoryFD, fileName: profileFileName) {
                        try unlinkEntry(directoryFD, profileFileName)
                    }
                    writesBlockedForCorruptSourceStorage = false
                } catch {
                    throw ProfileStoreError.writeFailed(error.localizedDescription)
                }
            }
        }
    }

    /// Lists this device's quarantine artifacts (newest first). Ignores other devices and the primary file.
    public func listQuarantineArtifacts() throws -> [URL] {
        try withStoreLock {
            try withSafeSupportDirectoryFD { directoryFD in
                try listQuarantineArtifacts(directoryFD: directoryFD)
            }
        }
    }

    /// Re-validates a quarantine artifact and atomically replaces the primary only if fully valid.
    /// Does not create a new quarantine entry. Leaves primary + artifact untouched on failure.
    @discardableResult
    public func attemptRestore(from url: URL) throws -> ProfileBundle {
        try withStoreLock {
            try withSafeSupportDirectoryFD { directoryFD in
                try attemptRestore(from: url, directoryFD: directoryFD)
            }
        }
    }

    public func defaultBundle() -> ProfileBundle {
        let profile = MouseProfile(
            name: "Default",
            dpiStages: [400, 800, 1600, 3200],
            activeStage: 2,
            pollingRateHz: 1000,
            autoReapplyEnabled: true
        )
        return ProfileBundle(selectedProfileID: profile.id, profiles: [profile])
    }

    private func quarantineAndRecover(directoryFD: Int32, reason: String) -> ProfileLoadOutcome {
        let defaults = defaultBundle()
        do {
            let quarantineURL = try performQuarantineMove(directoryFD: directoryFD)
            writesBlockedForCorruptSourceStorage = false
            do {
                try save(defaults, directoryFD: directoryFD)
                return .recovered(defaults, quarantinedURL: quarantineURL, reason: reason, persistenceWarning: nil)
            } catch {
                return .recovered(
                    defaults,
                    quarantinedURL: quarantineURL,
                    reason: reason,
                    persistenceWarning: error.localizedDescription
                )
            }
        } catch {
            writesBlockedForCorruptSourceStorage = true
            let combined = "\(reason); quarantine failed: \(error.localizedDescription)"
            return .corruptPreserved(defaults, sourceURL: fileURL, reason: combined)
        }
    }

    private func performQuarantineMove(directoryFD: Int32) throws -> URL {
        // Already under storeLock from public entry points; use locked helper directly.
        let quarantineURL = try uniqueQuarantineURLLocked(directoryFD: directoryFD)
        do {
            try renameEntry(directoryFD, profileFileName, quarantineURL.lastPathComponent)
        } catch {
            throw ProfileStoreError.quarantineFailed(error.localizedDescription)
        }
        return quarantineURL
    }

    /// Picks a quarantine path that does not already exist. Never deletes prior artifacts.
    /// Public-ish for tests; serializes with the store lock for race-free allocation.
    func uniqueQuarantineURL(
        directoryFD: Int32? = nil,
        uuid: @escaping () -> UUID = UUID.init
    ) throws -> URL {
        try withStoreLock {
            try uniqueQuarantineURLLocked(directoryFD: directoryFD, uuid: uuid)
        }
    }

    private func uniqueQuarantineURLLocked(
        directoryFD: Int32? = nil,
        uuid: @escaping () -> UUID = UUID.init
    ) throws -> URL {
        let stamp = Self.quarantineTimestamp(from: now())
        let baseName = "profiles-\(deviceKey)-corrupt-\(stamp)"

        func exists(_ fileName: String) -> Bool {
            if let directoryFD {
                return ProfileSafetyValidator.entryExists(directoryFD: directoryFD, fileName: fileName)
            }
            return fileManager.fileExists(atPath: directoryURL.appendingPathComponent(fileName).path)
        }

        let primaryName = "\(baseName).json"
        if !exists(primaryName) {
            return directoryURL.appendingPathComponent(primaryName)
        }

        for suffix in 2...1_000 {
            let candidateName = "\(baseName)-\(suffix).json"
            if !exists(candidateName) {
                return directoryURL.appendingPathComponent(candidateName)
            }
        }

        let fallbackName = "\(baseName)-\(uuid().uuidString).json"
        if exists(fallbackName) {
            throw ProfileStoreError.quarantineFailed("Unable to allocate a unique quarantine filename.")
        }
        return directoryURL.appendingPathComponent(fallbackName)
    }

    private static func quarantineTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Basename pattern for this device's quarantine files.
    private var quarantineFileNamePrefix: String {
        "profiles-\(deviceKey)-corrupt-"
    }

    private func isQuarantineFileName(_ fileName: String) -> Bool {
        guard fileName != profileFileName else { return false }
        guard !fileName.contains("/") && fileName != "." && fileName != ".." else { return false }
        return fileName.hasPrefix(quarantineFileNamePrefix) && fileName.hasSuffix(".json")
    }

    private func listQuarantineArtifacts(directoryFD: Int32) throws -> [URL] {
        // Enumerate exclusively via the validated directory FD — never re-open directoryURL.
        let names = try Self.readDirectoryBasenames(fromDirectoryFD: directoryFD)
        let expectedUID = currentUID()
        var scored: [(name: String, sec: Int64, nsec: Int64)] = []

        for name in names {
            guard isQuarantineFileName(name) else { continue }

            var status = stat()
            let result = name.withCString { cName in
                fstatat(directoryFD, cName, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { continue }

            let fileType = status.st_mode & S_IFMT
            // Skip symlinks and non-regular entries without following.
            guard fileType != S_IFLNK else { continue }
            guard fileType == S_IFREG else { continue }
            guard status.st_uid == expectedUID else { continue }
            guard status.st_size <= Int64(ProfileSafetyLimits.maximumFileBytes) else { continue }

            scored.append((name, Int64(status.st_mtimespec.tv_sec), Int64(status.st_mtimespec.tv_nsec)))
        }

        scored.sort { lhs, rhs in
            if lhs.sec != rhs.sec { return lhs.sec > rhs.sec }
            if lhs.nsec != rhs.nsec { return lhs.nsec > rhs.nsec }
            return lhs.name > rhs.name
        }

        // URLs are display handles only; subsequent restore re-validates via openat on the FD path.
        return scored.map { directoryURL.appendingPathComponent($0.name) }
    }

    /// `dup` + `fdopendir`/`readdir` so listing cannot follow a post-validation pathname swap.
    private static func readDirectoryBasenames(fromDirectoryFD directoryFD: Int32) throws -> [String] {
        let dupFD = dup(directoryFD)
        guard dupFD >= 0 else {
            throw ProfileStoreError.writeFailed(
                "Unable to duplicate support directory FD: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)"
            )
        }
        guard let dir = fdopendir(dupFD) else {
            let code = errno
            close(dupFD)
            throw ProfileStoreError.writeFailed(
                "Unable to open support directory stream: \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)"
            )
        }
        // `closedir` owns `dupFD`.
        defer { closedir(dir) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 {
                    throw ProfileStoreError.writeFailed(
                        "Unable to read support directory: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)"
                    )
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cPtr in
                    String(cString: cPtr)
                }
            }
            if name == "." || name == ".." { continue }
            if name.hasPrefix(".") { continue }
            names.append(name)
        }
        return names
    }

    private func attemptRestore(from url: URL, directoryFD: Int32) throws -> ProfileBundle {
        // Durable fail-closed gate: never replace an unquarantined corrupt primary.
        if writesBlockedForCorruptSourceStorage {
            throw ProfileStoreError.writeBlockedCorruptSource(fileURL.path)
        }

        let fileName = try validatedQuarantineFileName(for: url)

        let data: Data
        do {
            data = try ProfileSafetyValidator.readValidatedSourceFile(
                directoryFD: directoryFD,
                fileName: fileName
            )
        } catch let error as ProfileSafetyValidationError {
            throw ProfileStoreError.invalidRestoreSource(error.localizedDescription)
        } catch {
            throw ProfileStoreError.invalidRestoreSource(error.localizedDescription)
        }

        let validated = try decodeMigrateAndValidate(data)

        // Atomic replace only after complete validation; failure leaves prior primary intact.
        do {
            let encoded = try encoder.encode(validated.bundle)
            try ProfileSafetyValidator.writeOwnerOnlyRegularFile(
                directoryFD: directoryFD,
                fileName: profileFileName,
                data: encoded,
                temporaryFileName: ".\(profileFileName).tmp",
                fchmodFile: fchmodFile
            )
        } catch let error as ProfileSafetyValidationError {
            throw ProfileStoreError.unsafeSupportDirectory(error)
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.writeFailed(error.localizedDescription)
        }

        return validated.bundle
    }

    private func validatedQuarantineFileName(for url: URL) throws -> String {
        let candidate = url.standardizedFileURL
        let support = directoryURL.standardizedFileURL
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        guard parent.path == support.path else {
            throw ProfileStoreError.invalidRestoreSource("path is outside the profile support directory")
        }
        let fileName = candidate.lastPathComponent
        guard isQuarantineFileName(fileName) else {
            throw ProfileStoreError.invalidRestoreSource("not a quarantine artifact for this device")
        }
        return fileName
    }

    /// Shared decode → schema gate → button migration → schema upgrade → safety validation.
    private func decodeMigrateAndValidate(
        _ data: Data
    ) throws -> (bundle: ProfileBundle, repairWarnings: [String]) {
        let decoded: ProfileBundle
        do {
            decoded = try decoder.decode(ProfileBundle.self, from: data)
        } catch {
            throw ProfileStoreError.writeFailed("malformed profile JSON: \(error.localizedDescription)")
        }

        if decoded.schemaVersion > ProfileBundle.currentSchemaVersion
            || decoded.schemaVersion < ProfileBundle.legacySchemaVersion {
            throw ProfileStoreError.writeFailed(
                "unsupported profile schema version \(decoded.schemaVersion) (supported \(ProfileBundle.legacySchemaVersion)...\(ProfileBundle.currentSchemaVersion))"
            )
        }

        var bundle = decoded
        for index in bundle.profiles.indices {
            bundle.profiles[index].migrateButton2Alias()
        }
        if bundle.schemaVersion < ProfileBundle.currentSchemaVersion {
            bundle.schemaVersion = ProfileBundle.currentSchemaVersion
        }

        do {
            return try ProfileSafetyValidator.validateAndRepair(bundle, fileManager: fileManager)
        } catch let error as ProfileSafetyValidationError {
            if case let .invalidHardware(validationError) = error {
                throw ProfileStoreError.validation(validationError)
            }
            throw ProfileStoreError.safetyValidation(error)
        }
    }
}
