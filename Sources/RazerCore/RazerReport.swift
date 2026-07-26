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
    /// The Razer configuration packet is a fixed 90-byte frame for the whole family,
    /// not a per-device parameter: the frame offsets below (`bytes[8..<88]`, `[88]`,
    /// `[89]`, and the CRC slice `bytes[2..<88]`) encode it independently, and
    /// `calculateCRC` returns 0 rather than throwing on a length mismatch, so a
    /// per-device length would surface as a misleading CRC error. `MouseModel`'s
    /// `minimumFeatureReportSize` is the separate discovery threshold.
    public static let length = 90
    public static let argumentLength = 80

    public var status: UInt8
    public var transactionID: UInt8
    public var remainingPackets: UInt16
    public var protocolType: UInt8
    public var dataSize: UInt8
    public var commandClass: UInt8
    public var commandID: UInt8
    public var arguments: [UInt8] {
        get { _arguments }
        set { _arguments = Self.normalizedArguments(newValue) }
    }
    public var crc: UInt8
    public var reserved: UInt8

    private var _arguments: [UInt8]

    public init(
        status: UInt8 = 0,
        transactionID: UInt8,
        remainingPackets: UInt16 = 0,
        protocolType: UInt8 = 0,
        dataSize: UInt8 = 0,
        commandClass: UInt8 = 0,
        commandID: UInt8 = 0,
        arguments: [UInt8] = Array(repeating: 0, count: argumentLength),
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
        self._arguments = Self.normalizedArguments(arguments)
        self.crc = crc
        self.reserved = reserved
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.length else {
            throw RazerReportError.invalidLength(expected: Self.length, actual: bytes.count)
        }
        let size = bytes[5]
        guard size <= UInt8(Self.argumentLength) else {
            throw RazerReportError.invalidDataSize(size)
        }
        status = bytes[0]
        transactionID = bytes[1]
        remainingPackets = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        protocolType = bytes[4]
        dataSize = size
        commandClass = bytes[6]
        commandID = bytes[7]
        _arguments = Array(bytes[8..<88])
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
        for index in 0..<Self.argumentLength {
            report[8 + index] = _arguments[index]
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

    public static func normalizedArguments(_ arguments: [UInt8]) -> [UInt8] {
        if arguments.count == argumentLength {
            return arguments
        }
        if arguments.count > argumentLength {
            return Array(arguments.prefix(argumentLength))
        }
        return arguments + Array(repeating: 0, count: argumentLength - arguments.count)
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

    /// Unlike `decodeDPI`, this rejects out-of-range x/y: a device reporting a DPI
    /// above the ceiling reads fine through `getDPI` but throws when the same value
    /// appears in a stage list.
    public func decodeDPIStages(
        limits: ProfileLimits
    ) throws -> (activeStage: Int, stages: [(x: Int, y: Int)]) {
        // Layout: [store][active][count] then count × [index][x_hi][x_lo][y_hi][y_lo][0][0]
        // Compare against declared dataSize — arguments is always normalized to 80 bytes.
        let declaredPayloadLength = Int(dataSize)
        guard declaredPayloadLength >= 3 else {
            throw RazerReportError.truncatedDPIStagesPayload(
                requiredBytes: 3,
                available: declaredPayloadLength
            )
        }

        let activeStage = Int(arguments[1])
        let count = Int(arguments[2])

        guard count > 0 else {
            throw RazerValidationError.emptyDPIStages
        }
        guard count <= limits.maxDPIStages else {
            throw RazerValidationError.tooManyDPIStages(count, maximum: limits.maxDPIStages)
        }
        guard activeStage >= 1, activeStage <= count else {
            throw RazerValidationError.invalidActiveStage(activeStage, stageCount: count)
        }

        let requiredArgumentBytes = 3 + (count * 7)
        guard requiredArgumentBytes <= declaredPayloadLength else {
            throw RazerReportError.truncatedDPIStagesPayload(
                requiredBytes: requiredArgumentBytes,
                available: declaredPayloadLength
            )
        }

        var stages: [(x: Int, y: Int)] = []
        var offset = 4
        for _ in 0..<count {
            let x = (Int(arguments[offset]) << 8) | Int(arguments[offset + 1])
            let y = (Int(arguments[offset + 2]) << 8) | Int(arguments[offset + 3])
            try limits.validateDPI(x)
            try limits.validateDPI(y)
            stages.append((x, y))
            offset += 7
        }
        return (activeStage, stages)
    }

}

public enum RazerReportError: Error, LocalizedError, Equatable {
    case invalidLength(expected: Int, actual: Int)
    case invalidDataSize(UInt8)
    case truncatedDPIStagesPayload(requiredBytes: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidLength(expected, actual):
            return "Razer report must be \(expected) bytes, got \(actual)."
        case let .invalidDataSize(size):
            return "Razer report data size \(size) exceeds the \(RazerReport.argumentLength)-byte argument field."
        case let .truncatedDPIStagesPayload(requiredBytes, available):
            return "DPI stage payload needs \(requiredBytes) argument bytes, only \(available) available."
        }
    }
}

/// Device-dependent limits travel in the payload so the message is a pure function of
/// the error. Reading them from a shared constant would render the wrong device's
/// limits once more than one model is supported.
public enum RazerValidationError: Error, LocalizedError, Equatable {
    case emptyDPIStages
    case invalidActiveStage(Int, stageCount: Int)
    case invalidDPI(Int, allowed: ClosedRange<Int>)
    case unsupportedPollingRate(Int, supported: [Int])
    case tooManyDPIStages(Int, maximum: Int)
    case invalidWheelSpeedMultiplier

    public var errorDescription: String? {
        switch self {
        case .emptyDPIStages:
            return "At least one DPI stage is required."
        case let .invalidActiveStage(stage, stageCount):
            return "Active DPI stage \(stage) is invalid for \(stageCount) stages."
        case let .invalidDPI(dpi, allowed):
            return "DPI \(dpi) is outside the supported range \(allowed.lowerBound)-\(allowed.upperBound)."
        case let .unsupportedPollingRate(rate, supported):
            return "Polling rate \(rate) Hz is not supported. Use \(Self.humanList(supported)) Hz."
        case let .tooManyDPIStages(count, maximum):
            return "Too many DPI stages (\(count)). Maximum is \(maximum)."
        case .invalidWheelSpeedMultiplier:
            return "Wheel speed multiplier must be a finite value between \(SoftwareWheelSettings.minimumSpeedMultiplier) and \(SoftwareWheelSettings.maximumSpeedMultiplier)."
        }
    }

    /// Renders "125, 500, or 1000". `joined(separator:)` would drop the "or" and
    /// interpolating the array directly would emit brackets.
    static func humanList(_ values: [Int]) -> String {
        switch values.count {
        case 0:
            return "a supported rate"
        case 1:
            return "\(values[0])"
        case 2:
            return "\(values[0]) or \(values[1])"
        default:
            let leading = values.dropLast().map(String.init).joined(separator: ", ")
            return "\(leading), or \(values[values.count - 1])"
        }
    }
}

/// Device-independent validation. Device-dependent bounds live on `ProfileLimits`.
public enum ProfileValidator {
    public static func validateWheelSpeedMultiplier(_ multiplier: Double) throws {
        guard multiplier.isFinite else {
            throw RazerValidationError.invalidWheelSpeedMultiplier
        }
        guard (SoftwareWheelSettings.minimumSpeedMultiplier...SoftwareWheelSettings.maximumSpeedMultiplier)
            .contains(multiplier) else {
            throw RazerValidationError.invalidWheelSpeedMultiplier
        }
    }
}
