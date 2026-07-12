import Foundation

/// Why a hardware apply was requested. Software-only edits must never use these paths.
public enum HardwareApplyReason: String, Equatable, Sendable {
    case explicitApply
    case profileSelection
    case dpiCycle
    case reconnect
}

/// Hardware-relevant subset of a profile used to detect whether an HID apply is needed.
public struct HardwareProfileSettings: Equatable, Sendable {
    public let dpiStages: [Int]
    public let activeStage: Int
    public let pollingRateHz: Int
    public let wheel: HardwareWheelSettings

    public init(profile: MouseProfile) {
        dpiStages = profile.dpiStages
        activeStage = profile.activeStage
        pollingRateHz = profile.pollingRateHz
        wheel = profile.wheelSettings.hardware
    }
}

public enum HardwarePendingDetector {
    /// True when a successful apply baseline exists and the selected profile's hardware differs.
    public static func hasPendingChanges(
        profile: MouseProfile?,
        lastApplied: HardwareProfileSettings?
    ) -> Bool {
        guard let profile, let lastApplied else { return false }
        return HardwareProfileSettings(profile: profile) != lastApplied
    }
}

/// Monotonic gate so stale queued hardware applies can be discarded before their first write.
public final class LatestHardwareApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func issue() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }
}
