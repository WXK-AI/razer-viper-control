import Foundation
import RazerCore

@main
struct RazerProbeCLI {
    static func main() {
        let options: ProbeOptions
        do {
            options = try ProbeArgumentParser.parse(CommandLine.arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(64)
        }

        do {
            try run(options)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
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
            let report = WheelCapabilityProbe.probe(client: client)
            print("Wheel hardware capability:")
            let readback = client.readWheelHardwareState(capability: report.capability)
            print(WheelCapabilityProbe.summary(probeReport: report, readback: readback))
        }
    }

    private static func runWheelProbe() throws {
        try withClient { client in
            let report = WheelCapabilityProbe.probe(client: client)
            print("Wheel probe results:")
            print(report.summary)

            let capability = report.capability
            try HardwareStateTransaction.rejectUnknownCapabilities(capability)

            guard capability.scrollMode == .supported ||
                    capability.acceleration == .supported ||
                    capability.smartReel == .supported else {
                print("No supported hardware wheel commands on this device.")
                return
            }

            let restored = try HardwareStateTransaction.runWheelProbeMutation(
                client: client,
                capability: capability
            )
            print(
                "Restored wheel state: mode=\(restored.scrollMode?.displayName ?? "n/a"), acceleration=\(restored.accelerationEnabled.map { $0 ? "on" : "off" } ?? "n/a"), smartReel=\(restored.smartReelEnabled.map { $0 ? "on" : "off" } ?? "n/a")"
            )
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

        let entries = session.snapshotEntries()
        if entries.isEmpty {
            print("No events captured.")
            return
        }

        print("Captured \(entries.count) events:")
        for entry in entries {
            print(" - \(entry.summary)")
        }
    }

    private static func runIntegration(dpi: Int, pollingHz: Int) throws {
        try withClient { client in
            let result = try HardwareStateTransaction.runIntegration(
                client: client,
                temporaryDPI: dpi,
                temporaryPollingHz: pollingHz
            )
            print("Original state: DPI \(result.original.dpiX)x\(result.original.dpiY), polling \(result.original.pollingRateHz) Hz")
            print("Temporary DPI readback: \(result.temporaryDPI.x) x \(result.temporaryDPI.y)")
            print("Temporary polling: \(result.temporaryPollingHz) Hz")
            print("Restored state: DPI \(result.restored.dpiX)x\(result.restored.dpiY), polling \(result.restored.pollingRateHz) Hz")
        }
    }
}
