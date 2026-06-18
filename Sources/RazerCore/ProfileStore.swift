import Foundation

public struct MouseProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var dpiStages: [Int]
    public var activeStage: Int
    public var pollingRateHz: Int
    public var autoReapplyEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        dpiStages: [Int],
        activeStage: Int,
        pollingRateHz: Int,
        autoReapplyEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.dpiStages = dpiStages
        self.activeStage = activeStage
        self.pollingRateHz = pollingRateHz
        self.autoReapplyEnabled = autoReapplyEnabled
    }

    public var activeDPI: Int {
        guard !dpiStages.isEmpty else { return DeviceDescriptor.minDPI }
        let index = min(max(activeStage - 1, 0), dpiStages.count - 1)
        return dpiStages[index]
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

public enum ProfileStoreError: Error, LocalizedError {
    case validation(RazerValidationError)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .validation(error):
            return error.localizedDescription
        case let .writeFailed(details):
            return "Failed to save profiles: \(details)"
        }
    }
}

public final class ProfileStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(deviceKey: String = DeviceDescriptor.deviceKey, fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("RazerMenuBarApp", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("profiles-\(deviceKey).json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var storageURL: URL { fileURL }

    public func load() -> ProfileBundle {
        guard let data = try? Data(contentsOf: fileURL),
              let bundle = try? decoder.decode(ProfileBundle.self, from: data) else {
            return defaultBundle()
        }
        return bundle
    }

    public func save(_ bundle: ProfileBundle) throws {
        for profile in bundle.profiles {
            _ = try ProfileValidator.validateStages(profile.dpiStages, activeStage: profile.activeStage)
            try ProfileValidator.validatePollingRate(profile.pollingRateHz)
        }

        do {
            let data = try encoder.encode(bundle)
            try data.write(to: fileURL, options: .atomic)
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
}

public final class DeviceSession {
    private let discovery = HIDDeviceDiscovery()
    private var device: IOHIDDevice?
    private var client: RazerCommandClient?

    public init() {}

    public var isConnected: Bool { client != nil }

    public func connect() throws -> RazerCommandClient {
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
        client?.close()
        client = nil
        device = nil
    }

    public func reconnect() throws -> RazerCommandClient {
        disconnect()
        return try connect()
    }

    public func apply(profile: MouseProfile, to client: RazerCommandClient) throws {
        try client.setDPIStages(activeStage: profile.activeStage, stages: profile.dpiStages)
        try client.setDPI(profile.activeDPI)
        try client.setPollingRate(hz: profile.pollingRateHz)
    }
}
