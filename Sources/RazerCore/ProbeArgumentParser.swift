import Foundation

public struct ProbeOptions: Equatable, Sendable {
    public var command: ProbeCommand
    public var temporaryDPI: Int
    public var temporaryPollingHz: Int
    public var captureSeconds: Int

    public init(
        command: ProbeCommand = .help,
        temporaryDPI: Int = 1600,
        temporaryPollingHz: Int = 500,
        captureSeconds: Int = 15
    ) {
        self.command = command
        self.temporaryDPI = temporaryDPI
        self.temporaryPollingHz = temporaryPollingHz
        self.captureSeconds = captureSeconds
    }
}

public enum ProbeCommand: String, Equatable, Sendable {
    case list
    case battery
    case charging
    case dpi
    case stages
    case polling
    case wheel
    case wheelProbe = "wheel-probe"
    case inputCapture = "input-capture"
    case integration
    case help
}

public enum ProbeParseError: Error, Equatable, LocalizedError {
    case unknownCommand(String)
    case missingParameter(String)
    case extraParameter(String)
    case invalidInteger(String)
    case nonPositiveDuration(Int)

    public var errorDescription: String? {
        switch self {
        case let .unknownCommand(command):
            return "Unknown command '\(command)'."
        case let .missingParameter(name):
            return "Missing required parameter: \(name)."
        case let .extraParameter(value):
            return "Unexpected extra argument: \(value)."
        case let .invalidInteger(value):
            return "Invalid integer: \(value)."
        case let .nonPositiveDuration(value):
            return "Capture duration must be positive, got \(value)."
        }
    }
}

public enum ProbeArgumentParser {
    /// Parses `CommandLine`-style arguments where `arguments[0]` is the executable path.
    public static func parse(_ arguments: [String]) throws -> ProbeOptions {
        guard arguments.count > 1 else {
            return ProbeOptions(command: .help)
        }

        let rawCommand = arguments[1].lowercased()
        guard let command = ProbeCommand(rawValue: rawCommand) else {
            throw ProbeParseError.unknownCommand(arguments[1])
        }

        let rest = Array(arguments.dropFirst(2))
        var options = ProbeOptions(command: command)

        switch command {
        case .help, .list, .battery, .charging, .dpi, .stages, .polling, .wheel, .wheelProbe:
            if let extra = rest.first {
                throw ProbeParseError.extraParameter(extra)
            }
        case .inputCapture:
            if rest.isEmpty {
                break
            }
            guard rest.count == 1 else {
                throw ProbeParseError.extraParameter(rest[1])
            }
            options.captureSeconds = try parsePositiveInt(rest[0], name: "seconds")
        case .integration:
            if rest.count > 2 {
                throw ProbeParseError.extraParameter(rest[2])
            }
            if rest.count >= 1 {
                options.temporaryDPI = try parseInt(rest[0], name: "temporaryDPI")
            }
            if rest.count >= 2 {
                options.temporaryPollingHz = try parseInt(rest[1], name: "temporaryPollingHz")
            }
        }

        return options
    }

    private static func parseInt(_ value: String, name: String) throws -> Int {
        guard let parsed = Int(value) else {
            throw ProbeParseError.invalidInteger(value)
        }
        _ = name
        return parsed
    }

    private static func parsePositiveInt(_ value: String, name: String) throws -> Int {
        let parsed = try parseInt(value, name: name)
        guard parsed > 0 else {
            throw ProbeParseError.nonPositiveDuration(parsed)
        }
        return parsed
    }
}
