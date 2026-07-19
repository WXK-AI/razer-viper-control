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

public enum HardwareApplyField: String, Equatable, Sendable, CaseIterable {
    case dpiStages
    case dpi
    case pollingRate
    case scrollMode
    case acceleration
    case smartReel

    public var displayName: String {
        switch self {
        case .dpiStages: return "DPI stages"
        case .dpi: return "DPI"
        case .pollingRate: return "polling rate"
        case .scrollMode: return "scroll mode"
        case .acceleration: return "scroll acceleration"
        case .smartReel: return "smart reel"
        }
    }
}

public enum HardwareApplyResult: Equatable, Sendable {
    case verified
    case unverified(mismatches: [HardwareApplyField])
    case superseded

    public var verificationWarning: String? {
        guard case let .unverified(mismatches) = self else { return nil }
        let fields = mismatches.map(\.displayName).joined(separator: ", ")
        return "Profile applied, but device readback still differs for \(fields). Check the device connection and apply again."
    }
}

public enum HardwareApplyError: Error, Equatable, LocalizedError, Sendable {
    /// Requested wheel fields are supported but current values could not be read.
    case unknownWheelReadback(fields: [HardwareApplyField])

    public var errorDescription: String? {
        switch self {
        case let .unknownWheelReadback(fields):
            let list = fields.map(\.displayName).joined(separator: ", ")
            return "Could not read current wheel state (\(list)). Retry Apply when the device responds."
        }
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
    /// Requested wheel fields whose support could not be established. They are
    /// never written, but must keep the apply result from claiming verification.
    public static func unknownRequestedWheelFields(
        target: MouseProfile,
        capability: WheelHardwareCapability
    ) -> [HardwareApplyField] {
        let requested = target.wheelSettings.hardware
        var fields: [HardwareApplyField] = []
        if requested.scrollMode != nil, capability.scrollMode == .unknown {
            fields.append(.scrollMode)
        }
        if requested.accelerationEnabled != nil, capability.acceleration == .unknown {
            fields.append(.acceleration)
        }
        if requested.smartReelEnabled != nil, capability.smartReel == .unknown {
            fields.append(.smartReel)
        }
        return fields
    }

    /// Requested + supported wheel fields whose current value is unknown (nil readback).
    public static func unresolvedRequestedWheelFields(
        target: MouseProfile,
        wheelCurrent: HardwareWheelSettings,
        capability: WheelHardwareCapability
    ) -> [HardwareApplyField] {
        let requested = target.wheelSettings.hardware
        var fields: [HardwareApplyField] = []
        if requested.scrollMode != nil,
           capability.scrollMode == .supported,
           wheelCurrent.scrollMode == nil {
            fields.append(.scrollMode)
        }
        if requested.accelerationEnabled != nil,
           capability.acceleration == .supported,
           wheelCurrent.accelerationEnabled == nil {
            fields.append(.acceleration)
        }
        if requested.smartReelEnabled != nil,
           capability.smartReel == .supported,
           wheelCurrent.smartReelEnabled == nil {
            fields.append(.smartReel)
        }
        return fields
    }

    public static func plan(
        current: DeviceState,
        target: MouseProfile,
        wheelCurrent: HardwareWheelSettings,
        capability: WheelHardwareCapability
    ) -> HardwareApplyPlan {
        var plan = HardwareApplyPlan()

        if current.dpiStages != target.dpiStages
            || current.dpiStagesY != target.dpiStages
            || current.activeDPIStage != target.activeStage {
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

    /// Plans, applies, and verifies durable settings. A readable mismatch is retried once.
    /// Throws `HardwareApplyError.unknownWheelReadback` and writes nothing when requested
    /// supported wheel values cannot be read.
    @discardableResult
    public static func apply(
        target: MouseProfile,
        using client: HardwareProfileApplying,
        capability: WheelHardwareCapability,
        isStillCurrent: () -> Bool = { true }
    ) throws -> HardwareApplyResult {
        let current: DeviceState
        do {
            current = try client.readState()
        } catch {
            guard isStillCurrent() else { return .superseded }
            throw error
        }
        guard isStillCurrent() else { return .superseded }

        let wheelCurrent = client.readWheelHardwareState(capability: capability)
        guard isStillCurrent() else { return .superseded }

        let unresolved = unresolvedRequestedWheelFields(
            target: target,
            wheelCurrent: wheelCurrent,
            capability: capability
        )
        if !unresolved.isEmpty {
            guard isStillCurrent() else { return .superseded }
            throw HardwareApplyError.unknownWheelReadback(fields: unresolved)
        }
        let unknownCapabilityFields = unknownRequestedWheelFields(
            target: target,
            capability: capability
        )

        let plan = plan(
            current: current,
            target: target,
            wheelCurrent: wheelCurrent,
            capability: capability
        )
        // Final freshness check immediately before the first HID write.
        guard isStillCurrent() else { return .superseded }

        guard try execute(
            plan: plan,
            target: target,
            using: client,
            isStillCurrent: isStillCurrent
        ) else {
            return .superseded
        }

        // Empty plans still need a last-generation check before they are declared verified.
        guard isStillCurrent() else { return .superseded }
        guard !plan.isEmpty else {
            return unknownCapabilityFields.isEmpty
                ? .verified
                : .unverified(mismatches: unknownCapabilityFields)
        }

        let firstReadback = try readVerification(
            target: target,
            using: client,
            capability: capability,
            isStillCurrent: isStillCurrent
        )
        guard let firstReadback else { return .superseded }
        guard !firstReadback.mismatches.isEmpty else { return .verified }
        guard !firstReadback.retryPlan.isEmpty else {
            return .unverified(mismatches: firstReadback.mismatches)
        }

        guard isStillCurrent() else { return .superseded }
        guard try execute(
            plan: firstReadback.retryPlan,
            target: target,
            using: client,
            isStillCurrent: isStillCurrent
        ) else {
            return .superseded
        }

        guard isStillCurrent() else { return .superseded }
        let finalReadback = try readVerification(
            target: target,
            using: client,
            capability: capability,
            isStillCurrent: isStillCurrent
        )
        guard let finalReadback else { return .superseded }
        guard !finalReadback.mismatches.isEmpty else { return .verified }
        return .unverified(mismatches: finalReadback.mismatches)
    }

    private struct VerificationReadback {
        var mismatches: [HardwareApplyField]
        var retryPlan: HardwareApplyPlan
    }

    /// Returns nil when the apply was superseded during readback.
    private static func readVerification(
        target: MouseProfile,
        using client: HardwareProfileApplying,
        capability: WheelHardwareCapability,
        isStillCurrent: () -> Bool
    ) throws -> VerificationReadback? {
        let state: DeviceState
        do {
            state = try client.readState()
        } catch {
            guard isStillCurrent() else { return nil }
            throw error
        }
        guard isStillCurrent() else { return nil }
        let wheel = client.readWheelHardwareState(capability: capability)
        guard isStillCurrent() else { return nil }
        return verificationReadback(
            current: state,
            target: target,
            wheelCurrent: wheel,
            capability: capability
        )
    }

    private static func verificationReadback(
        current: DeviceState,
        target: MouseProfile,
        wheelCurrent: HardwareWheelSettings,
        capability: WheelHardwareCapability
    ) -> VerificationReadback {
        var mismatches = unknownRequestedWheelFields(target: target, capability: capability)
        var retryPlan = HardwareApplyPlan()

        if current.dpiStages != target.dpiStages
            || current.dpiStagesY != target.dpiStages
            || current.activeDPIStage != target.activeStage {
            mismatches.append(.dpiStages)
            retryPlan.setDPIStages = true
        }
        if current.dpiX != target.activeDPI || current.dpiY != target.activeDPI {
            mismatches.append(.dpi)
            retryPlan.setDPI = true
        }
        if current.pollingRateHz != target.pollingRateHz {
            mismatches.append(.pollingRate)
            // Unknown post-write polling is not safe evidence for another blind write.
            retryPlan.setPolling = current.pollingRateHz != nil
        }

        let requested = target.wheelSettings.hardware
        if let targetMode = requested.scrollMode,
           capability.scrollMode == .supported,
           wheelCurrent.scrollMode != targetMode {
            mismatches.append(.scrollMode)
            retryPlan.setScrollMode = wheelCurrent.scrollMode != nil
        }
        if let targetAcceleration = requested.accelerationEnabled,
           capability.acceleration == .supported,
           wheelCurrent.accelerationEnabled != targetAcceleration {
            mismatches.append(.acceleration)
            retryPlan.setAcceleration = wheelCurrent.accelerationEnabled != nil
        }
        if let targetSmartReel = requested.smartReelEnabled,
           capability.smartReel == .supported,
           wheelCurrent.smartReelEnabled != targetSmartReel {
            mismatches.append(.smartReel)
            retryPlan.setSmartReel = wheelCurrent.smartReelEnabled != nil
        }

        return VerificationReadback(mismatches: mismatches, retryPlan: retryPlan)
    }

    /// Executes complete HID commands and checks freshness only at command boundaries.
    @discardableResult
    public static func execute(
        plan: HardwareApplyPlan,
        target: MouseProfile,
        using client: HardwareProfileApplying,
        isStillCurrent: () -> Bool = { true }
    ) throws -> Bool {
        if plan.setDPIStages {
            guard try performCommand(
                { try client.setDPIStages(activeStage: target.activeStage, stages: target.dpiStages) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        if plan.setDPI {
            guard try performCommand(
                { try client.setDPI(target.activeDPI) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        if plan.setPolling {
            guard try performCommand(
                { try client.setPollingRate(hz: target.pollingRateHz) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        let wheel = target.wheelSettings.hardware
        if plan.setScrollMode, let mode = wheel.scrollMode {
            guard try performCommand(
                { try client.setScrollMode(mode) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        if plan.setAcceleration, let enabled = wheel.accelerationEnabled {
            guard try performCommand(
                { try client.setScrollAcceleration(enabled) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        if plan.setSmartReel, let enabled = wheel.smartReelEnabled {
            guard try performCommand(
                { try client.setScrollSmartReel(enabled) },
                isStillCurrent: isStillCurrent
            ) else { return false }
        }
        return true
    }

    /// A stale generation owns neither a successful command nor its error.
    private static func performCommand(
        _ command: () throws -> Void,
        isStillCurrent: () -> Bool
    ) throws -> Bool {
        do {
            try command()
        } catch {
            guard isStillCurrent() else { return false }
            throw error
        }
        return isStillCurrent()
    }
}
