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
        if let mode = requested.scrollMode,
           capability.scrollMode == .supported,
           wheelCurrent.scrollMode != mode {
            plan.setScrollMode = true
        }
        if let enabled = requested.accelerationEnabled,
           capability.acceleration == .supported,
           wheelCurrent.accelerationEnabled != enabled {
            plan.setAcceleration = true
        }
        if let enabled = requested.smartReelEnabled,
           capability.smartReel == .supported,
           wheelCurrent.smartReelEnabled != enabled {
            plan.setSmartReel = true
        }

        return plan
    }

    public static func apply(
        target: MouseProfile,
        using client: HardwareProfileApplying,
        capability: WheelHardwareCapability
    ) throws {
        let current = try client.readState()
        let wheelCurrent = client.readWheelHardwareState(capability: capability)
        let plan = plan(
            current: current,
            target: target,
            wheelCurrent: wheelCurrent,
            capability: capability
        )
        try execute(plan: plan, target: target, using: client)
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
