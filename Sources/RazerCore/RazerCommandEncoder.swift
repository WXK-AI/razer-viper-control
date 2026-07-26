import Foundation

/// Builds Razer configuration packets for one specific device.
///
/// The command bodies are family-wide (OpenRazer protocol reference); what varies per
/// device is the transaction ID stamped into byte 1 and the limits each write is
/// validated against. Holding the model as a value rather than reading a shared
/// constant is what lets a second model — or a runtime-probed transaction ID — coexist.
public struct RazerCommandEncoder: Sendable, Equatable {
    public let model: MouseModel

    public var limits: ProfileLimits { model.limits }
    public var transactionID: UInt8 { model.transactionID }

    public init(model: MouseModel) {
        // The stage write loop advances 7 bytes per stage into the 80-byte argument
        // field with no bounds check of its own.
        precondition(
            3 + model.maxDPIStages * 7 <= RazerReport.argumentLength,
            "maxDPIStages exceeds the \(RazerReport.argumentLength)-byte argument field."
        )
        self.model = model
    }

    public func makeCommand(
        commandClass: UInt8,
        commandID: UInt8,
        dataSize: UInt8,
        arguments: [UInt8] = []
    ) -> RazerReport {
        var report = RazerReport(
            transactionID: model.transactionID,
            dataSize: dataSize,
            commandClass: commandClass,
            commandID: commandID
        )
        for (index, value) in arguments.prefix(RazerReport.argumentLength).enumerated() {
            report.arguments[index] = value
        }
        report.refreshCRC()
        return report
    }

    // MARK: - Command builders (OpenRazer protocol reference)

    public func getBatteryLevel() -> RazerReport {
        makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
    }

    public func getChargingStatus() -> RazerReport {
        makeCommand(commandClass: 0x07, commandID: 0x84, dataSize: 0x02)
    }

    public func getPollingRate() -> RazerReport {
        makeCommand(commandClass: 0x00, commandID: 0x85, dataSize: 0x01)
    }

    public func setPollingRate(hz: Int) throws -> RazerReport {
        try limits.validatePollingRate(hz)
        let encoded: UInt8
        switch hz {
        case 1000: encoded = 0x01
        case 500: encoded = 0x02
        case 125: encoded = 0x08
        default:
            throw RazerValidationError.unsupportedPollingRate(hz, supported: limits.pollingRates)
        }
        return makeCommand(commandClass: 0x00, commandID: 0x05, dataSize: 0x01, arguments: [encoded])
    }

    /// Reads the live value, so `noStore` — unlike the writes below, which persist.
    public func getDPI() -> RazerReport {
        makeCommand(
            commandClass: 0x04,
            commandID: 0x85,
            dataSize: 0x07,
            arguments: [RazerVariableStorage.noStore.rawValue]
        )
    }

    public func setDPI(x: Int, y: Int) throws -> RazerReport {
        let clampedX = try limits.validateDPI(x)
        let clampedY = try limits.validateDPI(y)
        let args: [UInt8] = [
            RazerVariableStorage.varStore.rawValue,
            UInt8((clampedX >> 8) & 0xFF),
            UInt8(clampedX & 0xFF),
            UInt8((clampedY >> 8) & 0xFF),
            UInt8(clampedY & 0xFF),
            0x00,
            0x00
        ]
        return makeCommand(commandClass: 0x04, commandID: 0x05, dataSize: 0x07, arguments: args)
    }

    /// `dataSize` 0x26 is 38 == 3 header bytes + 5 stages × 7. Kept literal until a
    /// second model needs a different stage count.
    public func getDPIStages() -> RazerReport {
        makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 0x26,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public func setDPIStages(activeStage: Int, stages: [Int]) throws -> RazerReport {
        let validated = try limits.validateStages(stages, activeStage: activeStage)
        var args = [UInt8](repeating: 0, count: RazerReport.argumentLength)
        args[0] = RazerVariableStorage.varStore.rawValue
        args[1] = UInt8(validated.activeStage)
        args[2] = UInt8(validated.stages.count)

        var offset = 3
        for (index, dpi) in validated.stages.enumerated() {
            args[offset] = UInt8(index)
            offset += 1
            args[offset] = UInt8((dpi >> 8) & 0xFF)
            offset += 1
            args[offset] = UInt8(dpi & 0xFF)
            offset += 1
            args[offset] = UInt8((dpi >> 8) & 0xFF)
            offset += 1
            args[offset] = UInt8(dpi & 0xFF)
            offset += 1
            args[offset] = 0x00
            offset += 1
            args[offset] = 0x00
            offset += 1
        }

        return makeCommand(commandClass: 0x04, commandID: 0x06, dataSize: 0x26, arguments: args)
    }

    // MARK: - Scroll wheel commands (OpenRazer 0x02 class)

    public func getScrollMode() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x94,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public func setScrollMode(_ mode: ScrollWheelMode) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x14,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, mode.rawValue]
        )
    }

    public func getScrollAcceleration() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x96,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public func setScrollAcceleration(_ enabled: Bool) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x16,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, enabled ? 0x01 : 0x00]
        )
    }

    public func getScrollSmartReel() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x97,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public func setScrollSmartReel(_ enabled: Bool) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x17,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, enabled ? 0x01 : 0x00]
        )
    }
}
