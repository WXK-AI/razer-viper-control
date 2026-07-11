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
        remapperEnabled: Bool = true
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
        remapperEnabled = try container.decodeIfPresent(Bool.self, forKey: .remapperEnabled) ?? true
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
        remapperEnabled = true
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
    case loaded(ProfileBundle)
    case firstRun(ProfileBundle)
    /// Corrupt source was moved aside successfully; defaults may be persisted.
    case recovered(ProfileBundle, quarantinedURL: URL, reason: String)
    /// Quarantine failed; corrupt source must not be overwritten.
    case corruptPreserved(ProfileBundle, sourceURL: URL, reason: String)

    /// Whether it is safe to write a default bundle to the primary storage URL.
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
    case writeFailed(String)
    case quarantineFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .validation(error):
            return error.localizedDescription
        case let .writeFailed(details):
            return "Failed to save profiles: \(details)"
        case let .quarantineFailed(details):
            return "Failed to quarantine corrupt profiles: \(details)"
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
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        directoryURL = folder
        fileURL = folder.appendingPathComponent("profiles-\(deviceKey).json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var storageURL: URL { fileURL }
    public var storageDirectoryURL: URL { directoryURL }

    public func load() -> ProfileBundle {
        switch loadOutcome() {
        case let .loaded(bundle), let .firstRun(bundle), let .recovered(bundle, _, _), let .corruptPreserved(bundle, _, _):
            return bundle
        }
    }

    public func loadOutcome() -> ProfileLoadOutcome {
        if !fileManager.fileExists(atPath: fileURL.path) {
            return .firstRun(defaultBundle())
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return quarantineAndRecover(reason: "unreadable profile file: \(error.localizedDescription)")
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

        let repaired = repairSelection(bundle)
        if repaired != decoded {
            try? save(repaired)
        }
        return .loaded(repaired)
    }

    public func save(_ bundle: ProfileBundle) throws {
        for profile in bundle.profiles {
            do {
                _ = try ProfileValidator.validateStages(profile.dpiStages, activeStage: profile.activeStage)
                try ProfileValidator.validatePollingRate(profile.pollingRateHz)
            } catch let error as RazerValidationError {
                throw ProfileStoreError.validation(error)
            }
        }

        do {
            let data = try encoder.encode(bundle)
            try data.write(to: fileURL, options: .atomic)
        } catch let error as ProfileStoreError {
            throw error
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

    private func repairSelection(_ bundle: ProfileBundle) -> ProfileBundle {
        var repaired = bundle
        if repaired.profiles.isEmpty {
            return defaultBundle()
        }
        if let selected = repaired.selectedProfileID,
           repaired.profiles.contains(where: { $0.id == selected }) {
            return repaired
        }
        repaired.selectedProfileID = repaired.profiles[0].id
        return repaired
    }

    private func quarantineAndRecover(reason: String) -> ProfileLoadOutcome {
        let defaults = defaultBundle()
        let stamp = Self.quarantineTimestamp(from: now())
        let quarantineURL = directoryURL.appendingPathComponent(
            "profiles-\(deviceKey)-corrupt-\(stamp).json"
        )

        do {
            if fileManager.fileExists(atPath: quarantineURL.path) {
                try fileManager.removeItem(at: quarantineURL)
            }
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            return .recovered(defaults, quarantinedURL: quarantineURL, reason: reason)
        } catch {
            let combined = "\(reason); quarantine failed: \(error.localizedDescription)"
            return .corruptPreserved(defaults, sourceURL: fileURL, reason: combined)
        }
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

    public func apply(profile: MouseProfile, to client: RazerCommandClient, wheelCapability: WheelHardwareCapability? = nil) throws {
        try client.setDPIStages(activeStage: profile.activeStage, stages: profile.dpiStages)
        try client.setDPI(profile.activeDPI)
        try client.setPollingRate(hz: profile.pollingRateHz)
        try applyWheelSettings(profile.wheelSettings.hardware, to: client, capability: wheelCapability)
    }

    public func applyWheelSettings(
        _ settings: HardwareWheelSettings,
        to client: RazerCommandClient,
        capability: WheelHardwareCapability? = nil
    ) throws {
        if let mode = settings.scrollMode, capability?.scrollMode != .notSupported {
            _ = try client.setScrollMode(mode)
        }
        if let enabled = settings.accelerationEnabled, capability?.acceleration != .notSupported {
            _ = try client.setScrollAcceleration(enabled)
        }
        if let enabled = settings.smartReelEnabled, capability?.smartReel != .notSupported {
            _ = try client.setScrollSmartReel(enabled)
        }
    }
}
