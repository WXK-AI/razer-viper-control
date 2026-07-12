import Foundation

public struct HardwareApplyPlan: Equatable, Sendable {
    public var setDPIStages = false
    public var setDPI = false
    public var setPolling = false
    public var setScrollMode = false
    public var setAcceleration = false
    public var setSmartReel = false

    public init() {}

    public var isEmpty: Bool {
        !(setDPIStages || setDPI || setPolling || setScrollMode || setAcceleration || setSmartReel)
    }
}

/// Minimal surface for planning and applying durable profile hardware settings.
public protocol HardwareProfileApplying: AnyObject {
    func readState() throws -> DeviceState
    func readWheelHardwareState(capability: WheelHardwareCapability) -> HardwareWheelSettings
    func setDPIStages(activeStage: Int, stages: [Int]) throws
    func setDPI(_ dpi: Int) throws
    func setPollingRate(hz: Int) throws
    func setScrollMode(_ mode: ScrollWheelMode) throws
    func setScrollAcceleration(_ enabled: Bool) throws
    func setScrollSmartReel(_ enabled: Bool) throws
}

public enum HardwareProfileApplier {
    public static func plan(
        current: DeviceState,
        target: MouseProfile,
        wheelCurrent: HardwareWheelSettings,
        capability: WheelHardwareCapability
    ) -> HardwareApplyPlan {
        var plan = HardwareApplyPlan()

        if current.dpiStages != target.dpiStages || current.activeDPIStage != target.activeStage {
            plan.setDPIStages = true
        }
        if current.dpiX != target.activeDPI || current.dpiY != target.activeDPI {
            plan.setDPI = true
        }
        if current.pollingRateHz != target.pollingRateHz {
            plan.setPolling = true
        }

        let requested = target.wheelSettings.hardware
        // Supported fields with missing readback (nil) are unknown — never write.
        if let mode = requested.scrollMode,
           capability.scrollMode == .supported,
           let currentMode = wheelCurrent.scrollMode,
           currentMode != mode {
            plan.setScrollMode = true
        }
        if let enabled = requested.accelerationEnabled,
           capability.acceleration == .supported,
           let currentEnabled = wheelCurrent.accelerationEnabled,
           currentEnabled != enabled {
            plan.setAcceleration = true
        }
        if let enabled = requested.smartReelEnabled,
           capability.smartReel == .supported,
           let currentEnabled = wheelCurrent.smartReelEnabled,
           currentEnabled != enabled {
            plan.setSmartReel = true
        }

        return plan
    }

    /// Plans and applies durable settings. Returns `false` when superseded before the first write.
    @discardableResult
    public static func apply(
        target: MouseProfile,
        using client: HardwareProfileApplying,
        capability: WheelHardwareCapability,
        isStillCurrent: () -> Bool = { true }
    ) throws -> Bool {
        let current = try client.readState()
        guard isStillCurrent() else { return false }

        let wheelCurrent = client.readWheelHardwareState(capability: capability)
        guard isStillCurrent() else { return false }

        let plan = plan(
            current: current,
            target: target,
            wheelCurrent: wheelCurrent,
            capability: capability
        )
        // Final freshness check immediately before the first HID write.
        guard isStillCurrent() else { return false }

        try execute(plan: plan, target: target, using: client)
        return true
    }

    public static func execute(
        plan: HardwareApplyPlan,
        target: MouseProfile,
        using client: HardwareProfileApplying
    ) throws {
        if plan.setDPIStages {
            try client.setDPIStages(activeStage: target.activeStage, stages: target.dpiStages)
        }
        if plan.setDPI {
            try client.setDPI(target.activeDPI)
        }
        if plan.setPolling {
            try client.setPollingRate(hz: target.pollingRateHz)
        }
        let wheel = target.wheelSettings.hardware
        if plan.setScrollMode, let mode = wheel.scrollMode {
            try client.setScrollMode(mode)
        }
        if plan.setAcceleration, let enabled = wheel.accelerationEnabled {
            try client.setScrollAcceleration(enabled)
        }
        if plan.setSmartReel, let enabled = wheel.smartReelEnabled {
            try client.setScrollSmartReel(enabled)
        }
    }
}
