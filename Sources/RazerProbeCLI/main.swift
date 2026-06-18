import Foundation
import RazerCore

enum ProbeCommand: String {
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

struct ProbeOptions {
    var command: ProbeCommand = .help
    var temporaryDPI: Int = 1600
    var temporaryPollingHz: Int = 500
    var captureSeconds: Int = 15
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

        if command == .inputCapture, arguments.count > 2, let seconds = Int(arguments[2]) {
            options.captureSeconds = seconds
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
        case .wheel:
            try printWheel()
        case .wheelProbe:
            try runWheelProbe()
        case .inputCapture:
            try runInputCapture(seconds: options.captureSeconds)
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
          RazerProbeCLI wheel
          RazerProbeCLI wheel-probe
          RazerProbeCLI input-capture [seconds]
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

    private static func printWheel() throws {
        try withClient { client in
            let capability = WheelCapabilityProbe.probe(client: client)
            print("Wheel hardware capability:")
            print(" scroll mode: \(capability.scrollMode.displayName)")
            print(" acceleration: \(capability.acceleration.displayName)")
            print(" smart reel: \(capability.smartReel.displayName)")

            if capability.scrollMode == .supported {
                let state = try client.readWheelHardwareState()
                if let mode = state.scrollMode {
                    print("Current scroll mode: \(mode.displayName)")
                }
                if let enabled = state.accelerationEnabled {
                    print("Scroll acceleration: \(enabled ? "on" : "off")")
                }
                if let enabled = state.smartReelEnabled {
                    print("Smart reel: \(enabled ? "on" : "off")")
                }
            }
        }
    }

    private static func runWheelProbe() throws {
        try withClient { client in
            let capability = WheelCapabilityProbe.probe(client: client)
            print("Wheel probe results:")
            print(" scroll mode: \(capability.scrollMode.displayName)")
            print(" acceleration: \(capability.acceleration.displayName)")
            print(" smart reel: \(capability.smartReel.displayName)")

            guard capability.scrollMode == .supported ||
                    capability.acceleration == .supported ||
                    capability.smartReel == .supported else {
                print("No supported hardware wheel commands on this device.")
                return
            }

            let original = try client.readWheelHardwareState()
            print("Original wheel state: mode=\(original.scrollMode?.displayName ?? "n/a"), acceleration=\(original.accelerationEnabled.map { $0 ? "on" : "off" } ?? "n/a"), smartReel=\(original.smartReelEnabled.map { $0 ? "on" : "off" } ?? "n/a")")

            if capability.scrollMode == .supported, let mode = original.scrollMode {
                let alternate: ScrollWheelMode = mode == .tactile ? .freeSpin : .tactile
                print("Trying alternate scroll mode: \(alternate.displayName)")
                switch client.setScrollMode(alternate) {
                case .success:
                    let readback = try client.readWheelHardwareState()
                    print("Readback scroll mode: \(readback.scrollMode?.displayName ?? "unknown")")
                case .notSupported:
                    print("Set scroll mode: not supported")
                }
            }

            if capability.acceleration == .supported {
                let target = !(original.accelerationEnabled ?? false)
                print("Trying scroll acceleration: \(target ? "on" : "off")")
                switch client.setScrollAcceleration(target) {
                case .success:
                    let readback = try client.readWheelHardwareState()
                    print("Readback acceleration: \(readback.accelerationEnabled.map { $0 ? "on" : "off" } ?? "unknown")")
                case .notSupported:
                    print("Set acceleration: not supported")
                }
            }

            print("Restoring original wheel state...")
            if let mode = original.scrollMode {
                _ = client.setScrollMode(mode)
            }
            if let enabled = original.accelerationEnabled {
                _ = client.setScrollAcceleration(enabled)
            }
            if let enabled = original.smartReelEnabled {
                _ = client.setScrollSmartReel(enabled)
            }
            let restored = try client.readWheelHardwareState()
            print("Restored wheel state: mode=\(restored.scrollMode?.displayName ?? "n/a"), acceleration=\(restored.accelerationEnabled.map { $0 ? "on" : "off" } ?? "n/a")")
        }
    }

    private static func runInputCapture(seconds: Int) throws {
        let permissions = PermissionStatus.current()
        print("Permissions: \(permissions.summary)")
        guard permissions.inputMonitoringGranted else {
            throw InputCaptureError.missingInputMonitoring
        }

        let session = InputCaptureSession()
        try session.start()
        defer { session.stop() }

        print("Capturing mouse events for \(seconds)s. Press buttons and scroll on the mouse...")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), false)
        }

        if session.entries.isEmpty {
            print("No events captured.")
            return
        }

        print("Captured \(session.entries.count) events:")
        for entry in session.entries {
            print(" - \(entry.summary)")
        }
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
