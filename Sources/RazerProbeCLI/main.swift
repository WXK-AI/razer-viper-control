import Foundation
import RazerCore

enum ProbeCommand: String {
    case list
    case battery
    case charging
    case dpi
    case stages
    case polling
    case integration
    case help
}

struct ProbeOptions {
    var command: ProbeCommand = .help
    var temporaryDPI: Int = 1600
    var temporaryPollingHz: Int = 500
}

@main
struct RazerProbeCLI {
    static func main() {
        let options = parseArguments(CommandLine.arguments)
        do {
            try run(options)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseArguments(_ arguments: [String]) -> ProbeOptions {
        var options = ProbeOptions()
        guard arguments.count > 1 else { return options }

        let command = ProbeCommand(rawValue: arguments[1].lowercased()) ?? .help
        options.command = command

        if command == .integration {
            if arguments.count > 2, let dpi = Int(arguments[2]) {
                options.temporaryDPI = dpi
            }
            if arguments.count > 3, let polling = Int(arguments[3]) {
                options.temporaryPollingHz = polling
            }
        }

        return options
    }

    private static func run(_ options: ProbeOptions) throws {
        switch options.command {
        case .help:
            printUsage()
        case .list:
            try listInterfaces()
        case .battery:
            try printBattery()
        case .charging:
            try printCharging()
        case .dpi:
            try printDPI()
        case .stages:
            try printStages()
        case .polling:
            try printPolling()
        case .integration:
            try runIntegration(dpi: options.temporaryDPI, pollingHz: options.temporaryPollingHz)
        }
    }

    private static func printUsage() {
        print("""
        RazerProbeCLI — diagnostics for Razer Viper V3 HyperSpeed (1532:00B8)

        Usage:
          RazerProbeCLI list
          RazerProbeCLI battery
          RazerProbeCLI charging
          RazerProbeCLI dpi
          RazerProbeCLI stages
          RazerProbeCLI polling
          RazerProbeCLI integration [temporaryDPI] [temporaryPollingHz]
        """)
    }

    private static func listInterfaces() throws {
        let discovery = HIDDeviceDiscovery()
        let interfaces = try discovery.listRazerInterfaces()
        if interfaces.isEmpty {
            print("No Razer HID interfaces found for \(DeviceDescriptor.deviceKey).")
            return
        }

        print("Detected Razer HID interfaces:")
        for interface in interfaces {
            print(" - \(interface.summary)")
        }

        if interfaces.contains(where: \.isTargetControlInterface) {
            print("Control interface candidate: usage 1:2 with feature report >= \(DeviceDescriptor.featureReportLength) bytes.")
        } else {
            print("Warning: no 90-byte feature-report control interface detected.")
        }
    }

    private static func withClient<T>(_ body: (RazerCommandClient) throws -> T) throws -> T {
        let session = DeviceSession()
        let client = try session.connect()
        defer { session.disconnect() }
        return try body(client)
    }

    private static func printBattery() throws {
        let percent = try withClient { client in
            try client.send(.getBatteryLevel()).decodeBatteryPercent()
        }
        print("Battery: \(percent)%")
    }

    private static func printCharging() throws {
        let charging = try withClient { client in
            try client.send(.getChargingStatus()).decodeCharging()
        }
        print("Charging: \(charging ? "yes" : "no")")
    }

    private static func printDPI() throws {
        let dpi = try withClient { client in
            try client.send(.getDPI()).decodeDPI()
        }
        print("DPI: \(dpi.x) x \(dpi.y)")
    }

    private static func printStages() throws {
        let decoded = try withClient { client in
            try client.send(.getDPIStages()).decodeDPIStages()
        }
        print("Active stage: \(decoded.activeStage)")
        for (index, stage) in decoded.stages.enumerated() {
            print(" Stage \(index + 1): \(stage.x) x \(stage.y)")
        }
    }

    private static func printPolling() throws {
        let hz = try withClient { client in
            try client.send(.getPollingRate()).decodePollingRateHz()
        }
        print("Polling rate: \(hz.map(String.init) ?? "unknown") Hz")
    }

    private static func runIntegration(dpi: Int, pollingHz: Int) throws {
        try ProfileValidator.validatePollingRate(pollingHz)
        guard (DeviceDescriptor.minDPI...DeviceDescriptor.maxDPI).contains(dpi) else {
            throw RazerValidationError.invalidDPI(dpi)
        }

        try withClient { client in
            let original = try client.readState()
            print("Original state: DPI \(original.dpiX), polling \(original.pollingRateHz) Hz")

            print("Applying temporary DPI \(dpi)...")
            try client.setDPI(dpi)
            let readDPI = try client.send(.getDPI()).decodeDPI()
            print("Readback DPI: \(readDPI.x) x \(readDPI.y)")

            print("Applying temporary polling \(pollingHz) Hz...")
            try client.setPollingRate(hz: pollingHz)
            let readPolling = try client.send(.getPollingRate()).decodePollingRateHz()
            print("Readback polling: \(readPolling ?? -1) Hz")

            print("Restoring previous values...")
            try client.setDPI(original.dpiX)
            try client.setPollingRate(hz: original.pollingRateHz)

            let restored = try client.readState()
            print("Restored state: DPI \(restored.dpiX), polling \(restored.pollingRateHz) Hz")
        }
    }
}
