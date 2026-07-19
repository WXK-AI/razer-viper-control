import Foundation

/// Transient reconnect outcome shown once in the menu bar after a link-up.
public enum MenuReconnectFeedback: Equatable, Sendable {
    case profileReapplied
    case profileNotApplied

    public var menuLine: String {
        switch self {
        case .profileReapplied:
            return "Reconnected — profile reapplied"
        case .profileNotApplied:
            return "Reconnected — profile not applied"
        }
    }
}

/// When to surface "Reconnected…" after a link-up (never on first-ever connect).
public enum MenuReconnectFeedbackPolicy {
    public static func shouldPublish(
        becameConnected: Bool,
        hadPriorSuccessfulConnection: Bool
    ) -> Bool {
        becameConnected && hadPriorSuccessfulConnection
    }

    public static func feedback(
        becameConnected: Bool,
        hadPriorSuccessfulConnection: Bool,
        profileApplied: Bool
    ) -> MenuReconnectFeedback? {
        guard shouldPublish(
            becameConnected: becameConnected,
            hadPriorSuccessfulConnection: hadPriorSuccessfulConnection
        ) else {
            return nil
        }
        return profileApplied ? .profileReapplied : .profileNotApplied
    }
}

/// Inputs for the pure menu-bar status mapper.
public struct MenuStatusInputs: Equatable, Sendable {
    public var isConnected: Bool
    public var batteryPercent: Int
    public var isCharging: Bool
    public var isLowBattery: Bool
    public var commandError: RazerCommandError?
    /// Pre-resolved connection line (friendly error or "Connected" / "Disconnected").
    public var connectionStatusLine: String
    public var remapperStatus: RemapperRuntimeStatus
    public var showRemapperSection: Bool
    public var persistenceWarning: String?
    public var reconnectFeedback: MenuReconnectFeedback?

    public init(
        isConnected: Bool,
        batteryPercent: Int,
        isCharging: Bool,
        isLowBattery: Bool,
        commandError: RazerCommandError? = nil,
        connectionStatusLine: String,
        remapperStatus: RemapperRuntimeStatus,
        showRemapperSection: Bool,
        persistenceWarning: String? = nil,
        reconnectFeedback: MenuReconnectFeedback? = nil
    ) {
        self.isConnected = isConnected
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isLowBattery = isLowBattery
        self.commandError = commandError
        self.connectionStatusLine = connectionStatusLine
        self.remapperStatus = remapperStatus
        self.showRemapperSection = showRemapperSection
        self.persistenceWarning = persistenceWarning
        self.reconnectFeedback = reconnectFeedback
    }
}

/// Battery slice of the menu presentation. `nil` while disconnected.
public struct MenuBatteryPresentation: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool
    public let isLow: Bool

    public init(percent: Int, isCharging: Bool, isLow: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isLow = isLow
    }

    public var menuLine: String {
        var line = "Battery: \(percent)%"
        if isCharging {
            line += " (charging)"
        }
        if isLow {
            line += " — low"
        }
        return line
    }

    public var statusItemText: String {
        "\(percent)%"
    }
}

/// Snapshot of device menu fields after a verified explicit apply.
public struct MenuDeviceStatusAfterApply: Equatable, Sendable {
    public let lastCommandError: RazerCommandError?
    public let hardwareVerificationWarning: String?
    public let warningMessage: String?
    public let statusMessage: String

    public init(
        lastCommandError: RazerCommandError?,
        hardwareVerificationWarning: String?,
        warningMessage: String?,
        statusMessage: String
    ) {
        self.lastCommandError = lastCommandError
        self.hardwareVerificationWarning = hardwareVerificationWarning
        self.warningMessage = warningMessage
        self.statusMessage = statusMessage
    }
}

/// Fully resolved menu-bar / status-item presentation. Views render this only.
public struct MenuStatusPresentation: Equatable, Sendable {
    public let isConnected: Bool
    public let connectionLine: String
    /// When connected, non-nil for non-default statuses (verify failure, degraded, apply errors).
    public let connectedDetailLine: String?
    public let battery: MenuBatteryPresentation?
    public let remapperTitle: String?
    public let remapperDetail: String?
    public let showPauseResume: Bool
    public let recoveryAction: RemapperRecoveryAction?
    public let recoveryButtonTitle: String?
    public let warningLines: [String]
    public let transientLine: String?

    public init(
        isConnected: Bool,
        connectionLine: String,
        connectedDetailLine: String?,
        battery: MenuBatteryPresentation?,
        remapperTitle: String?,
        remapperDetail: String?,
        showPauseResume: Bool,
        recoveryAction: RemapperRecoveryAction?,
        recoveryButtonTitle: String?,
        warningLines: [String],
        transientLine: String?
    ) {
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.connectedDetailLine = connectedDetailLine
        self.battery = battery
        self.remapperTitle = remapperTitle
        self.remapperDetail = remapperDetail
        self.showPauseResume = showPauseResume
        self.recoveryAction = recoveryAction
        self.recoveryButtonTitle = recoveryButtonTitle
        self.warningLines = warningLines
        self.transientLine = transientLine
    }

    public var batteryMenuLine: String? {
        battery?.menuLine
    }

    public var statusItemBatteryText: String? {
        battery?.statusItemText
    }

    public var statusItemShowsCharging: Bool {
        battery?.isCharging == true
    }

    public var statusItemIsLowBattery: Bool {
        battery?.isLow == true
    }
}

/// Pure menu status mapping for the menu bar. No AppKit / SwiftUI.
public enum MenuStatusModel {
    public static let lowBatteryEnterPercent = 15
    public static let lowBatteryClearPercent = 20
    /// Boring default while linked — not shown as a connected detail line.
    public static let plainConnectedStatus = "Connected"

    /// Short, user-facing strings for the menu. Never dumps raw `localizedDescription`.
    public static func friendlyMessage(for error: RazerCommandError) -> String {
        switch error {
        case .deviceNotOpen:
            return "Mouse not found"
        case .permissionDenied:
            return "Permission needed — open Settings"
        case .blockedDeviceAccess:
            return "Another app controls the mouse"
        case .deviceBusy:
            return "Mouse busy — retrying"
        case .timeout:
            return "Mouse not responding"
        case .unsupportedCommand:
            return "Command not supported"
        case .transport:
            return "Connection error"
        case .invalidResponse:
            return "Unexpected mouse response"
        }
    }

    /// Low-battery hysteresis: enter at ≤15%, clear at ≥20%.
    public static func isLowBattery(percent: Int, wasLow: Bool) -> Bool {
        if wasLow {
            return percent < lowBatteryClearPercent
        }
        return percent <= lowBatteryEnterPercent
    }

    /// Connected-only detail: friendly command error, or non-default status line.
    public static func connectedDetailLine(
        connectionStatusLine: String,
        commandError: RazerCommandError?
    ) -> String? {
        if let commandError {
            return friendlyMessage(for: commandError)
        }
        if connectionStatusLine == plainConnectedStatus {
            return nil
        }
        return connectionStatusLine
    }

    /// On disconnect, only permission/conflict keep a warning; others clear stale banners.
    public static func disconnectWarningMessage(for error: RazerCommandError?) -> String? {
        guard let error else { return nil }
        if error.isPermissionIssue || error.isConflictIssue {
            return friendlyMessage(for: error)
        }
        return nil
    }

    /// Verified explicit apply clears latched device error/warning state for the menu.
    public static func deviceStatusAfterSuccessfulApply(
        profileName: String
    ) -> MenuDeviceStatusAfterApply {
        MenuDeviceStatusAfterApply(
            lastCommandError: nil,
            hardwareVerificationWarning: nil,
            warningMessage: nil,
            statusMessage: "Applied profile \(profileName)"
        )
    }

    /// Unverified apply: clear stale command errors so the menu detail shows verification state.
    public static func deviceStatusAfterUnverifiedApply(
        verificationWarning: String
    ) -> MenuDeviceStatusAfterApply {
        MenuDeviceStatusAfterApply(
            lastCommandError: nil,
            hardwareVerificationWarning: verificationWarning,
            warningMessage: verificationWarning,
            statusMessage: "Profile applied but not verified"
        )
    }

    /// Non-command / non-HardwareApplyError apply failure: clear latched error and unrelated banners.
    public static func deviceStatusAfterGenericApplyFailure() -> MenuDeviceStatusAfterApply {
        MenuDeviceStatusAfterApply(
            lastCommandError: nil,
            hardwareVerificationWarning: nil,
            warningMessage: nil,
            statusMessage: "Profile apply failed"
        )
    }

    public static func make(inputs: MenuStatusInputs) -> MenuStatusPresentation {
        let battery: MenuBatteryPresentation?
        let connectedDetail: String?
        if inputs.isConnected {
            battery = MenuBatteryPresentation(
                percent: inputs.batteryPercent,
                isCharging: inputs.isCharging,
                isLow: inputs.isLowBattery
            )
            connectedDetail = connectedDetailLine(
                connectionStatusLine: inputs.connectionStatusLine,
                commandError: inputs.commandError
            )
        } else {
            battery = nil
            connectedDetail = nil
        }

        let remapperTitle: String?
        let remapperDetail: String?
        let showPauseResume: Bool
        let recoveryAction: RemapperRecoveryAction?
        let recoveryButtonTitle: String?

        if inputs.showRemapperSection {
            remapperTitle = inputs.remapperStatus.title
            switch inputs.remapperStatus {
            case .circuitOpen:
                remapperDetail = inputs.remapperStatus.detail
                showPauseResume = false
                recoveryAction = inputs.remapperStatus.recoveryAction
                recoveryButtonTitle = recoveryAction?.buttonTitle
            case .paused, .active, .recovering:
                // Pause/Resume covers manual pause; do not also emit .resume recovery.
                remapperDetail = nil
                showPauseResume = true
                recoveryAction = nil
                recoveryButtonTitle = nil
            case .disabled:
                remapperDetail = nil
                showPauseResume = false
                recoveryAction = nil
                recoveryButtonTitle = nil
            case .awaitingConsent, .missingPermission, .failed:
                remapperDetail = nil
                showPauseResume = false
                recoveryAction = inputs.remapperStatus.recoveryAction
                recoveryButtonTitle = recoveryAction?.buttonTitle
            }
        } else {
            remapperTitle = nil
            remapperDetail = nil
            showPauseResume = false
            recoveryAction = nil
            recoveryButtonTitle = nil
        }

        var warningLines: [String] = []
        if let persistence = inputs.persistenceWarning, !persistence.isEmpty {
            warningLines.append(persistenceWarningLine(from: persistence))
        }
        if case .missingPermission = inputs.remapperStatus, inputs.showRemapperSection {
            warningLines.append("⚠︎ Permission needed — open Settings")
        } else if let error = inputs.commandError, error.isPermissionIssue {
            warningLines.append("⚠︎ Permission needed — open Settings")
        } else if let error = inputs.commandError, error.isConflictIssue {
            warningLines.append("⚠︎ Another app controls the mouse")
        }

        return MenuStatusPresentation(
            isConnected: inputs.isConnected,
            connectionLine: inputs.connectionStatusLine,
            connectedDetailLine: connectedDetail,
            battery: battery,
            remapperTitle: remapperTitle,
            remapperDetail: remapperDetail,
            showPauseResume: showPauseResume,
            recoveryAction: recoveryAction,
            recoveryButtonTitle: recoveryButtonTitle,
            warningLines: warningLines,
            transientLine: inputs.reconnectFeedback?.menuLine
        )
    }

    private static func persistenceWarningLine(from raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("corrupt") {
            return "⚠︎ Saved profiles are corrupt"
        }
        if lower.contains("blocked") || lower.contains("could not save") || lower.contains("write") {
            return "⚠︎ Profile saves are blocked"
        }
        return "⚠︎ Profile storage needs attention"
    }
}
