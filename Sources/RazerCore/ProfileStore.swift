import Darwin
import Foundation
import IOKit.hid

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
    public var selectedProfileID: UUID?
    public var profiles: [MouseProfile]

    public init(selectedProfileID: UUID? = nil, profiles: [MouseProfile] = []) {
        self.selectedProfileID = selectedProfileID
        self.profiles = profiles
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
        case .firstRun, .recovered:
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
        }
    }
}

public final class ProfileStore {
    private let fileURL: URL
    private let directoryURL: URL
    private let deviceKey: String
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date

    /// When true, `save` refuses to write the primary path so a corrupt source cannot be overwritten.
    public private(set) var writesBlockedForCorruptSource = false

    public init(
        deviceKey: String = DeviceDescriptor.deviceKey,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.deviceKey = deviceKey
        self.fileManager = fileManager
        self.now = now

        let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try? fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        directoryURL = folder
        fileURL = folder.appendingPathComponent("profiles-\(deviceKey).json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var storageURL: URL { fileURL }
    public var storageDirectoryURL: URL { directoryURL }

    public func load() -> ProfileBundle {
        loadOutcome().bundle
    }

    public func loadOutcome() -> ProfileLoadOutcome {
        writesBlockedForCorruptSource = false

        if !sourcePathExists() {
            let defaults = defaultBundle()
            do {
                try save(defaults)
                return .firstRun(defaults, persistenceWarning: nil)
            } catch {
                return .firstRun(defaults, persistenceWarning: error.localizedDescription)
            }
        }

        let data: Data
        do {
            try ProfileSafetyValidator.inspectSourceFile(at: fileURL, fileManager: fileManager)
            data = try Data(contentsOf: fileURL)
        } catch {
            return quarantineAndRecover(reason: "unsafe or unreadable profile file: \(error.localizedDescription)")
        }

        let decoded: ProfileBundle
        do {
            decoded = try decoder.decode(ProfileBundle.self, from: data)
        } catch {
            return quarantineAndRecover(reason: "malformed profile JSON: \(error.localizedDescription)")
        }

        var bundle = decoded
        for index in bundle.profiles.indices {
            bundle.profiles[index].migrateButton2Alias()
        }

        let validated: (bundle: ProfileBundle, repairWarnings: [String])
        do {
            validated = try ProfileSafetyValidator.validateAndRepair(bundle, fileManager: fileManager)
        } catch {
            return quarantineAndRecover(reason: "unsafe profile content: \(error.localizedDescription)")
        }
        let repaired = validated.bundle
        if repaired != decoded {
            do {
                try save(repaired)
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
        if writesBlockedForCorruptSource {
            throw ProfileStoreError.writeBlockedCorruptSource(fileURL.path)
        }

        let validated: (bundle: ProfileBundle, repairWarnings: [String])
        do {
            validated = try ProfileSafetyValidator.validateAndRepair(bundle, fileManager: fileManager)
        } catch let error as ProfileSafetyValidationError {
            if case let .invalidHardware(validationError) = error {
                throw ProfileStoreError.validation(validationError)
            }
            throw ProfileStoreError.safetyValidation(error)
        }

        do {
            let data = try encoder.encode(validated.bundle)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Retries moving the corrupt primary file aside, then clears the write block.
    @discardableResult
    public func retryQuarantineCorruptSource() throws -> URL {
        do {
            if sourcePathExists() {
                let quarantineURL = try performQuarantineMove()
                writesBlockedForCorruptSource = false
                return quarantineURL
            }
            writesBlockedForCorruptSource = false
            return try uniqueQuarantineURL()
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.quarantineFailed(error.localizedDescription)
        }
    }

    /// Explicitly removes the corrupt primary file and allows subsequent saves.
    public func discardCorruptSourceAndAllowWrites() throws {
        do {
            if sourcePathExists() {
                try fileManager.removeItem(at: fileURL)
            }
            writesBlockedForCorruptSource = false
        } catch {
            throw ProfileStoreError.writeFailed(error.localizedDescription)
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

    private func quarantineAndRecover(reason: String) -> ProfileLoadOutcome {
        let defaults = defaultBundle()
        do {
            let quarantineURL = try performQuarantineMove()
            writesBlockedForCorruptSource = false
            do {
                try save(defaults)
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
            writesBlockedForCorruptSource = true
            let combined = "\(reason); quarantine failed: \(error.localizedDescription)"
            return .corruptPreserved(defaults, sourceURL: fileURL, reason: combined)
        }
    }

    private func performQuarantineMove() throws -> URL {
        let quarantineURL = try uniqueQuarantineURL()
        var status = stat()
        if lstat(fileURL.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK {
            guard rename(fileURL.path, quarantineURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return quarantineURL
        }
        try fileManager.moveItem(at: fileURL, to: quarantineURL)
        return quarantineURL
    }

    private func sourcePathExists() -> Bool {
        var status = stat()
        return lstat(fileURL.path, &status) == 0
    }

    /// Picks a quarantine path that does not already exist. Never deletes prior artifacts.
    func uniqueQuarantineURL(uuid: @escaping () -> UUID = UUID.init) throws -> URL {
        let stamp = Self.quarantineTimestamp(from: now())
        let baseName = "profiles-\(deviceKey)-corrupt-\(stamp)"
        let primary = directoryURL.appendingPathComponent("\(baseName).json")
        if !fileManager.fileExists(atPath: primary.path) {
            return primary
        }

        for suffix in 2...1_000 {
            let candidate = directoryURL.appendingPathComponent("\(baseName)-\(suffix).json")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let fallback = directoryURL.appendingPathComponent("\(baseName)-\(uuid().uuidString).json")
        if fileManager.fileExists(atPath: fallback.path) {
            throw ProfileStoreError.quarantineFailed("Unable to allocate a unique quarantine filename.")
        }
        return fallback
    }

    private static func quarantineTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

public final class DeviceSession {
    private let discovery = HIDDeviceDiscovery()
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var client: RazerCommandClient?

    public init() {}

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client != nil
    }

    public func connect() throws -> RazerCommandClient {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }

        guard let device = try discovery.findControlDevice() else {
            throw RazerCommandError.deviceNotOpen
        }

        let client = RazerCommandClient(device: device)
        do {
            try client.open(nonSeizing: true)
        } catch {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            throw error
        }

        self.device = device
        self.client = client
        return client
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        client?.close()
        client = nil
        device = nil
    }

    public func reconnect() throws -> RazerCommandClient {
        disconnect()
        return try connect()
    }

    public func apply(
        profile: MouseProfile,
        to client: RazerCommandClient,
        wheelCapability: WheelHardwareCapability? = nil,
        isStillCurrent: () -> Bool = { true }
    ) throws -> Bool {
        let capability = wheelCapability ?? WheelHardwareCapability()
        return try HardwareProfileApplier.apply(
            target: profile,
            using: RazerCommandClientHardwareApplier(client: client),
            capability: capability,
            isStillCurrent: isStillCurrent
        )
    }

    public func applyWheelSettings(
        _ settings: HardwareWheelSettings,
        to client: RazerCommandClient,
        capability: WheelHardwareCapability? = nil
    ) throws {
        let resolved = capability ?? WheelHardwareCapability()
        if let mode = settings.scrollMode, resolved.scrollMode == .supported {
            _ = try client.setScrollMode(mode)
        }
        if let enabled = settings.accelerationEnabled, resolved.acceleration == .supported {
            _ = try client.setScrollAcceleration(enabled)
        }
        if let enabled = settings.smartReelEnabled, resolved.smartReel == .supported {
            _ = try client.setScrollSmartReel(enabled)
        }
    }
}

/// Adapts `RazerCommandClient` to the apply planner without colliding on return types.
final class RazerCommandClientHardwareApplier: HardwareProfileApplying {
    private let client: RazerCommandClient

    init(client: RazerCommandClient) {
        self.client = client
    }

    func readState() throws -> DeviceState {
        try client.readState()
    }

    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings {
        client.readWheelHardwareState(capability: capability).settings
    }

    func setDPIStages(activeStage: Int, stages: [Int]) throws {
        try client.setDPIStages(activeStage: activeStage, stages: stages)
    }

    func setDPI(_ dpi: Int) throws {
        try client.setDPI(dpi)
    }

    func setPollingRate(hz: Int) throws {
        try client.setPollingRate(hz: hz)
    }

    func setScrollMode(_ mode: ScrollWheelMode) throws {
        _ = try client.setScrollMode(mode)
    }

    func setScrollAcceleration(_ enabled: Bool) throws {
        _ = try client.setScrollAcceleration(enabled)
    }

    func setScrollSmartReel(_ enabled: Bool) throws {
        _ = try client.setScrollSmartReel(enabled)
    }
}
