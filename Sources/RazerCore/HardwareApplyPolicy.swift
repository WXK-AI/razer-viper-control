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

/// Rules for updating the last-applied hardware baseline after an apply attempt.
public enum HardwareApplyBaseline {
    /// Unverified, superseded, or failed applies must not advance the baseline.
    public static func settingsToRecord(
        result: HardwareApplyResult,
        applied: HardwareProfileSettings?
    ) -> HardwareProfileSettings? {
        guard result == .verified else { return nil }
        return applied
    }
}

/// Decides whether an explicit apply failure makes the cached HID session unsafe to reuse.
public enum HardwareApplyFailurePolicy {
    public static func shouldInvalidate(error: Error) -> Bool {
        if let commandError = error as? RazerCommandError {
            return commandError.shouldInvalidateSession
        }
        if error is HardwareApplyError {
            return false
        }
        if error is RazerValidationError {
            return false
        }
        return true
    }
}

/// Keeps wheel capability evidence across ordinary refreshes and requests a
/// bounded re-probe only when an apply needs a field whose support is unknown.
public enum WheelCapabilityRefreshPolicy {
    public static func resolvedCapability(
        fresh: WheelHardwareCapability?,
        cached: WheelHardwareCapability
    ) -> WheelHardwareCapability {
        fresh ?? cached
    }

    public static func requiresProbe(
        profile: MouseProfile,
        capability: WheelHardwareCapability
    ) -> Bool {
        let requested = profile.wheelSettings.hardware
        return (requested.scrollMode != nil && capability.scrollMode == .unknown)
            || (requested.accelerationEnabled != nil && capability.acceleration == .unknown)
            || (requested.smartReelEnabled != nil && capability.smartReel == .unknown)
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

    /// Current generation without claiming a new apply. Used by reconnect observation.
    public func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }
}
