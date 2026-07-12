import Foundation

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
