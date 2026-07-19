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

/// Compact remapper runtime state shown in Settings and the menu bar.
public enum RemapperRuntimeStatus: Equatable, Sendable {
    case disabled
    case awaitingConsent
    case circuitOpen
    case missingPermission(PermissionStatus)
    case active
    case paused
    case recovering
    case failed(String)

    public var title: String {
        switch self {
        case .disabled:
            return "Remapper disabled"
        case .awaitingConsent:
            return "Remapper awaiting consent"
        case .circuitOpen:
            return "Remapper paused"
        case .missingPermission:
            return "Remapper needs permissions"
        case .active:
            return "Remapper active"
        case .paused:
            return "Remapper paused"
        case .recovering:
            return "Remapper recovering"
        case .failed:
            return "Remapper failed"
        }
    }

    public var detail: String {
        switch self {
        case .disabled:
            return "Software remapping is turned off for the selected profile."
        case .awaitingConsent:
            return "Software remapping affects every mouse and trackpad in this login session. Arm this process to start."
        case .circuitOpen:
            return "Remapper paused after repeated event-tap timeouts."
        case let .missingPermission(permissions):
            return permissions.summary
        case .active:
            return "Session-wide button and wheel remapping is running."
        case .paused:
            return "Emergency pause is on (⌃⌥⌘R). Resume when ready."
        case .recovering:
            return "Event tap recovered and held buttons were released."
        case let .failed(message):
            return message
        }
    }

    public var recoveryAction: RemapperRecoveryAction? {
        switch self {
        case .disabled, .active:
            return nil
        case .awaitingConsent, .circuitOpen:
            return .armRemapper
        case let .missingPermission(permissions):
            switch (permissions.inputMonitoringGranted, permissions.accessibilityGranted) {
            case (false, false):
                return .openPrivacySettings
            case (false, true):
                return .openInputMonitoring
            case (true, false):
                return .openAccessibility
            case (true, true):
                return nil
            }
        case .paused:
            return .resume
        case .recovering:
            return .acknowledgeRecovery
        case .failed:
            return .retryStart
        }
    }
}

public enum RemapperRecoveryAction: Equatable, Sendable {
    case openInputMonitoring
    case openAccessibility
    case openPrivacySettings
    case armRemapper
    case resume
    case acknowledgeRecovery
    case retryStart

    public var buttonTitle: String {
        switch self {
        case .openInputMonitoring:
            return "Open Input Monitoring"
        case .openAccessibility:
            return "Open Accessibility"
        case .openPrivacySettings:
            return "Open Privacy Settings"
        case .armRemapper:
            return "Arm Remapper"
        case .resume:
            return "Resume Remapper"
        case .acknowledgeRecovery:
            return "Dismiss"
        case .retryStart:
            return "Retry"
        }
    }
}

public enum RemapperRuntimeStatusResolver {
    /// Priority: disabled → circuit open → awaitingConsent → missing permission → failed → recovering → paused → active.
    public static func resolve(
        remapperEnabled: Bool,
        remapperArmed: Bool,
        permissions: PermissionStatus,
        isRunning: Bool,
        isPaused: Bool,
        isRecovering: Bool,
        lastError: String?,
        circuitOpen: Bool = false
    ) -> RemapperRuntimeStatus {
        guard remapperEnabled else { return .disabled }
        if circuitOpen { return .circuitOpen }
        guard remapperArmed else { return .awaitingConsent }
        guard permissions.remapperReady else { return .missingPermission(permissions) }
        if !isRunning {
            return .failed(lastError ?? "Remapper failed to start")
        }
        if isRecovering { return .recovering }
        if isPaused { return .paused }
        return .active
    }
}

/// Pure UI pause decision after a remapper `resume()` attempt.
public enum RemapperPausePolicy {
    /// UI must stay paused when resume fails (e.g. open circuit breaker).
    public static func uiPaused(afterResumeSucceeded succeeded: Bool) -> Bool {
        !succeeded
    }
}
