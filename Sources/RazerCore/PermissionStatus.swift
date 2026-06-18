import ApplicationServices
import Foundation

public struct PermissionStatus: Equatable, Sendable {
    public var inputMonitoringGranted: Bool
    public var accessibilityGranted: Bool

    public init(inputMonitoringGranted: Bool, accessibilityGranted: Bool) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public static func current() -> PermissionStatus {
        let listenGranted: Bool
        if #available(macOS 10.15, *) {
            listenGranted = CGPreflightListenEventAccess()
        } else {
            listenGranted = true
        }

        let accessibilityGranted = AXIsProcessTrusted()
        return PermissionStatus(
            inputMonitoringGranted: listenGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    public var remapperReady: Bool {
        inputMonitoringGranted && accessibilityGranted
    }

    public var summary: String {
        var parts: [String] = []
        parts.append("Input Monitoring: \(inputMonitoringGranted ? "granted" : "missing")")
        parts.append("Accessibility: \(accessibilityGranted ? "granted" : "missing")")
        return parts.joined(separator: " • ")
    }
}
