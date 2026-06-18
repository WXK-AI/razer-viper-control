import Foundation

public enum RazerReportStatus: UInt8 {
    case newCommand = 0x00
    case busy = 0x01
    case successful = 0x02
    case failure = 0x03
    case timeout = 0x04
    case notSupported = 0x05
}

public enum RazerVariableStorage: UInt8 {
    case noStore = 0x00
    case varStore = 0x01
}

/// Independent encoder/decoder for the 90-byte Razer HID configuration packet.
public struct RazerReport: Equatable, Sendable {
    public static let length = DeviceDescriptor.featureReportLength

    public var status: UInt8
    public var transactionID: UInt8
    public var remainingPackets: UInt16
    public var protocolType: UInt8
    public var dataSize: UInt8
    public var commandClass: UInt8
    public var commandID: UInt8
    public var arguments: [UInt8]
    public var crc: UInt8
    public var reserved: UInt8

    public init(
        status: UInt8 = 0,
        transactionID: UInt8 = DeviceDescriptor.transactionID,
        remainingPackets: UInt16 = 0,
        protocolType: UInt8 = 0,
        dataSize: UInt8 = 0,
        commandClass: UInt8 = 0,
        commandID: UInt8 = 0,
        arguments: [UInt8] = Array(repeating: 0, count: 80),
        crc: UInt8 = 0,
        reserved: UInt8 = 0
    ) {
        self.status = status
        self.transactionID = transactionID
        self.remainingPackets = remainingPackets
        self.protocolType = protocolType
        self.dataSize = dataSize
        self.commandClass = commandClass
        self.commandID = commandID
        self.arguments = arguments
        self.crc = crc
        self.reserved = reserved
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.length else {
            throw RazerReportError.invalidLength(expected: Self.length, actual: bytes.count)
        }
        status = bytes[0]
        transactionID = bytes[1]
        remainingPackets = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        protocolType = bytes[4]
        dataSize = bytes[5]
        commandClass = bytes[6]
        commandID = bytes[7]
        arguments = Array(bytes[8..<88])
        crc = bytes[88]
        reserved = bytes[89]
    }

    public var bytes: [UInt8] {
        var report = Array(repeating: UInt8(0), count: Self.length)
        report[0] = status
        report[1] = transactionID
        report[2] = UInt8((remainingPackets >> 8) & 0xFF)
        report[3] = UInt8(remainingPackets & 0xFF)
        report[4] = protocolType
        report[5] = dataSize
        report[6] = commandClass
        report[7] = commandID
        for index in 0..<80 {
            report[8 + index] = arguments[index]
        }
        report[88] = crc
        report[89] = reserved
        return report
    }

    public mutating func refreshCRC() {
        let payload = bytes
        crc = Self.calculateCRC(for: payload)
    }

    public static func calculateCRC(for bytes: [UInt8]) -> UInt8 {
        guard bytes.count == length else { return 0 }
        return bytes[2..<88].reduce(0, ^)
    }

    public static func makeCommand(
        commandClass: UInt8,
        commandID: UInt8,
        dataSize: UInt8,
        arguments: [UInt8] = []
    ) -> RazerReport {
        var report = RazerReport(
            transactionID: DeviceDescriptor.transactionID,
            dataSize: dataSize,
            commandClass: commandClass,
            commandID: commandID
        )
        for (index, value) in arguments.prefix(80).enumerated() {
            report.arguments[index] = value
        }
        report.refreshCRC()
        return report
    }

    // MARK: - Command builders (OpenRazer protocol reference)

    public static func getBatteryLevel() -> RazerReport {
        makeCommand(commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
    }

    public static func getChargingStatus() -> RazerReport {
        makeCommand(commandClass: 0x07, commandID: 0x84, dataSize: 0x02)
    }

    public static func getPollingRate() -> RazerReport {
        makeCommand(commandClass: 0x00, commandID: 0x85, dataSize: 0x01)
    }

    public static func setPollingRate(hz: Int) throws -> RazerReport {
        let encoded: UInt8
        switch hz {
        case 1000: encoded = 0x01
        case 500: encoded = 0x02
        case 125: encoded = 0x08
        default:
            throw RazerValidationError.unsupportedPollingRate(hz)
        }
        return makeCommand(commandClass: 0x00, commandID: 0x05, dataSize: 0x01, arguments: [encoded])
    }

    public static func getDPI() -> RazerReport {
        makeCommand(
            commandClass: 0x04,
            commandID: 0x85,
            dataSize: 0x07,
            arguments: [RazerVariableStorage.noStore.rawValue]
        )
    }

    public static func setDPI(x: Int, y: Int) throws -> RazerReport {
        let clampedX = try clampDPI(x)
        let clampedY = try clampDPI(y)
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

    public static func getDPIStages() -> RazerReport {
        makeCommand(
            commandClass: 0x04,
            commandID: 0x86,
            dataSize: 0x26,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    // MARK: - Scroll wheel commands (OpenRazer 0x02 class)

    public static func getScrollMode() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x94,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public static func setScrollMode(_ mode: ScrollWheelMode) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x14,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, mode.rawValue]
        )
    }

    public static func getScrollAcceleration() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x96,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public static func setScrollAcceleration(_ enabled: Bool) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x16,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, enabled ? 0x01 : 0x00]
        )
    }

    public static func getScrollSmartReel() -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x97,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue]
        )
    }

    public static func setScrollSmartReel(_ enabled: Bool) -> RazerReport {
        makeCommand(
            commandClass: 0x02,
            commandID: 0x17,
            dataSize: 0x02,
            arguments: [RazerVariableStorage.varStore.rawValue, enabled ? 0x01 : 0x00]
        )
    }

    public static func setDPIStages(activeStage: Int, stages: [Int]) throws -> RazerReport {
        let validated = try ProfileValidator.validateStages(stages, activeStage: activeStage)
        var args = [UInt8](repeating: 0, count: 80)
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

    // MARK: - Response parsing

    public var responseStatus: RazerReportStatus? {
        RazerReportStatus(rawValue: status)
    }

    public func decodeBatteryPercent() -> Int {
        let raw = Int(arguments[1])
        guard raw >= 0 else { return 0 }
        // OpenRazer: charge_level sysfs is 0-255; scale to 0-100 for display.
        return min(100, (raw * 100) / 255)
    }

    public func decodeCharging() -> Bool {
        arguments[1] != 0
    }

    public func decodePollingRateHz() -> Int? {
        switch arguments[0] {
        case 0x01: return 1000
        case 0x02: return 500
        case 0x08: return 125
        default: return nil
        }
    }

    public func decodeDPI() -> (x: Int, y: Int) {
        let x = (Int(arguments[1]) << 8) | Int(arguments[2])
        let y = (Int(arguments[3]) << 8) | Int(arguments[4])
        return (x, y)
    }

    public func decodeScrollMode() -> ScrollWheelMode? {
        ScrollWheelMode(rawValue: arguments[1])
    }

    public func decodeBoolArgument() -> Bool {
        arguments[1] != 0
    }

    public func decodeDPIStages() -> (activeStage: Int, stages: [(x: Int, y: Int)]) {
        let activeStage = Int(arguments[1])
        let count = Int(arguments[2])
        var stages: [(x: Int, y: Int)] = []
        var offset = 4
        for _ in 0..<count where offset + 6 < arguments.count {
            let x = (Int(arguments[offset + 1]) << 8) | Int(arguments[offset + 2])
            let y = (Int(arguments[offset + 3]) << 8) | Int(arguments[offset + 4])
            stages.append((x, y))
            offset += 7
        }
        return (activeStage, stages)
    }

    private static func clampDPI(_ dpi: Int) throws -> Int {
        guard (DeviceDescriptor.minDPI...DeviceDescriptor.maxDPI).contains(dpi) else {
            throw RazerValidationError.invalidDPI(dpi)
        }
        return dpi
    }
}

public enum RazerReportError: Error, LocalizedError {
    case invalidLength(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidLength(expected, actual):
            return "Razer report must be \(expected) bytes, got \(actual)."
        }
    }
}

public enum RazerValidationError: Error, LocalizedError, Equatable {
    case emptyDPIStages
    case invalidActiveStage(Int, stageCount: Int)
    case invalidDPI(Int)
    case unsupportedPollingRate(Int)
    case tooManyDPIStages(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyDPIStages:
            return "At least one DPI stage is required."
        case let .invalidActiveStage(stage, stageCount):
            return "Active DPI stage \(stage) is invalid for \(stageCount) stages."
        case let .invalidDPI(dpi):
            return "DPI \(dpi) is outside the supported range \(DeviceDescriptor.minDPI)-\(DeviceDescriptor.maxDPI)."
        case let .unsupportedPollingRate(rate):
            return "Polling rate \(rate) Hz is not supported. Use 125, 500, or 1000 Hz."
        case let .tooManyDPIStages(count):
            return "Too many DPI stages (\(count)). Maximum is \(DeviceDescriptor.maxDPIStages)."
        }
    }
}

public enum ProfileValidator {
    public struct ValidatedStages: Equatable {
        public let stages: [Int]
        public let activeStage: Int
    }

    public static func validateStages(_ stages: [Int], activeStage: Int) throws -> ValidatedStages {
        guard !stages.isEmpty else {
            throw RazerValidationError.emptyDPIStages
        }
        guard stages.count <= DeviceDescriptor.maxDPIStages else {
            throw RazerValidationError.tooManyDPIStages(stages.count)
        }
        guard activeStage >= 1, activeStage <= stages.count else {
            throw RazerValidationError.invalidActiveStage(activeStage, stageCount: stages.count)
        }
        for dpi in stages {
            guard (DeviceDescriptor.minDPI...DeviceDescriptor.maxDPI).contains(dpi) else {
                throw RazerValidationError.invalidDPI(dpi)
            }
        }
        return ValidatedStages(stages: stages, activeStage: activeStage)
    }

    public static func validatePollingRate(_ rate: Int) throws {
        guard DeviceDescriptor.supportedPollingRates.contains(rate) else {
            throw RazerValidationError.unsupportedPollingRate(rate)
        }
    }
}
