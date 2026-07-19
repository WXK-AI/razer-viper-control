import XCTest
@testable import RazerCore

final class MenuStatusModelTests: XCTestCase {

    // MARK: - Friendly command errors (Task 13)

    func testFriendlyCommandErrorStringsNeverUseRawLocalizedDescription() {
        let cases: [(RazerCommandError, String)] = [
            (.deviceNotOpen, "Mouse not found"),
            (.permissionDenied("denied"), "Permission needed — open Settings"),
            (.blockedDeviceAccess("busy"), "Another app controls the mouse"),
            (.deviceBusy, "Mouse busy — retrying"),
            (.timeout, "Mouse not responding"),
            (.unsupportedCommand, "Command not supported"),
            (.transport("io"), "Connection error"),
            (.invalidResponse("crc"), "Unexpected mouse response"),
        ]

        for (error, expected) in cases {
            let friendly = MenuStatusModel.friendlyMessage(for: error)
            XCTAssertEqual(friendly, expected, "Unexpected mapping for \(error)")
            XCTAssertNotEqual(
                friendly,
                error.localizedDescription,
                "Menu string must not dump localizedDescription for \(error)"
            )
            XCTAssertFalse(
                friendly.contains("HID"),
                "Menu string should stay user-facing for \(error)"
            )
        }
    }

    // MARK: - Circuit-open vs manual pause (Task 13)

    func testCircuitOpenTitleIsDistinctFromManualPause() {
        XCTAssertEqual(RemapperRuntimeStatus.circuitOpen.title, "Remapper paused (safety)")
        XCTAssertEqual(RemapperRuntimeStatus.paused.title, "Remapper paused")
        XCTAssertNotEqual(
            RemapperRuntimeStatus.circuitOpen.title,
            RemapperRuntimeStatus.paused.title
        )
    }

    func testCircuitOpenMenuShowsDetailRearmAndHidesPauseResume() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                remapperStatus: .circuitOpen,
                showRemapperSection: true
            )
        )

        XCTAssertEqual(presentation.remapperTitle, "Remapper paused (safety)")
        XCTAssertEqual(
            presentation.remapperDetail,
            "Remapper paused after repeated event-tap timeouts."
        )
        XCTAssertFalse(presentation.showPauseResume)
        XCTAssertEqual(presentation.recoveryAction, .rearmRemapper)
        XCTAssertEqual(presentation.recoveryButtonTitle, "Re-arm…")
    }

    func testManualPauseShowsPauseResumeWithoutSafetyLabel() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                remapperStatus: .paused,
                showRemapperSection: true
            )
        )

        XCTAssertEqual(presentation.remapperTitle, "Remapper paused")
        XCTAssertNil(presentation.remapperDetail)
        XCTAssertTrue(presentation.showPauseResume)
        // Menu uses the Pause/Resume control only — no duplicate recovery button.
        XCTAssertNil(presentation.recoveryAction)
        XCTAssertNil(presentation.recoveryButtonTitle)
    }

    func testActiveRemapperShowsPauseResumeWithoutRecovery() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                remapperStatus: .active,
                showRemapperSection: true
            )
        )

        XCTAssertEqual(presentation.remapperTitle, "Remapper active")
        XCTAssertTrue(presentation.showPauseResume)
        XCTAssertNil(presentation.recoveryAction)
        XCTAssertNil(presentation.recoveryButtonTitle)
    }

    // MARK: - Warnings (Task 13)

    func testPersistenceWarningProducesWarningMenuLine() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                persistenceWarning: "Saved profiles are corrupt and could not be quarantined."
            )
        )

        XCTAssertTrue(
            presentation.warningLines.contains(where: { $0.hasPrefix("⚠︎") }),
            "Expected ⚠︎ persistence line, got \(presentation.warningLines)"
        )
        XCTAssertTrue(
            presentation.warningLines.contains(where: {
                $0.localizedCaseInsensitiveContains("profile")
            })
        )
    }

    func testPermissionWarningProducesWarningMenuLine() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: false,
                commandError: .permissionDenied("Input Monitoring"),
                connectionStatusLine: MenuStatusModel.friendlyMessage(
                    for: .permissionDenied("Input Monitoring")
                ),
                remapperStatus: .missingPermission(
                    .init(inputMonitoringGranted: false, accessibilityGranted: true)
                ),
                showRemapperSection: true
            )
        )

        XCTAssertTrue(
            presentation.warningLines.contains(where: { $0.hasPrefix("⚠︎") }),
            "Expected ⚠︎ permission line, got \(presentation.warningLines)"
        )
        XCTAssertEqual(
            presentation.connectionLine,
            "Permission needed — open Settings"
        )
    }

    func testMissingPermissionRemapperStatusProducesWarningLine() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                remapperStatus: .missingPermission(
                    .init(inputMonitoringGranted: false, accessibilityGranted: false)
                ),
                showRemapperSection: true
            )
        )

        XCTAssertTrue(presentation.warningLines.contains(where: { $0.hasPrefix("⚠︎") }))
        XCTAssertEqual(presentation.remapperTitle, "Remapper needs permissions")
        XCTAssertEqual(presentation.recoveryAction, .openPrivacySettings)
    }

    // MARK: - Reconnect feedback + no stale battery (Task 13)

    func testReconnectFeedbackLines() {
        let reapplied = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                reconnectFeedback: .profileReapplied
            )
        )
        XCTAssertEqual(reapplied.transientLine, "Reconnected — profile reapplied")

        let notApplied = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                reconnectFeedback: .profileNotApplied
            )
        )
        XCTAssertEqual(notApplied.transientLine, "Reconnected — profile not applied")
    }

    func testDisconnectedHidesBatteryAndClearsStalePercentFromStatusItem() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: false,
                batteryPercent: 87,
                isCharging: true,
                isLowBattery: true,
                connectionStatusLine: "Disconnected"
            )
        )

        XCTAssertNil(presentation.battery)
        XCTAssertNil(presentation.statusItemBatteryText)
        XCTAssertFalse(presentation.statusItemShowsCharging)
        XCTAssertFalse(presentation.statusItemIsLowBattery)
        XCTAssertEqual(presentation.connectionLine, "Disconnected")
        XCTAssertFalse(presentation.isConnected)
    }

    // MARK: - Battery hysteresis / charging (Task 14)

    func testLowBatteryHysteresisEnterAt15ClearAt20() {
        XCTAssertFalse(MenuStatusModel.isLowBattery(percent: 16, wasLow: false))
        XCTAssertTrue(MenuStatusModel.isLowBattery(percent: 15, wasLow: false))
        XCTAssertTrue(MenuStatusModel.isLowBattery(percent: 10, wasLow: false))

        // Once latched low, stays low until >= 20
        XCTAssertTrue(MenuStatusModel.isLowBattery(percent: 16, wasLow: true))
        XCTAssertTrue(MenuStatusModel.isLowBattery(percent: 19, wasLow: true))
        XCTAssertFalse(MenuStatusModel.isLowBattery(percent: 20, wasLow: true))
        XCTAssertFalse(MenuStatusModel.isLowBattery(percent: 50, wasLow: true))
    }

    func testConnectedBatteryPresentationFlagsChargingAndLow() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                batteryPercent: 12,
                isCharging: true,
                isLowBattery: true
            )
        )

        XCTAssertEqual(presentation.battery?.percent, 12)
        XCTAssertEqual(presentation.battery?.isCharging, true)
        XCTAssertEqual(presentation.battery?.isLow, true)
        XCTAssertEqual(presentation.statusItemBatteryText, "12%")
        XCTAssertTrue(presentation.statusItemShowsCharging)
        XCTAssertTrue(presentation.statusItemIsLowBattery)
        XCTAssertTrue(presentation.batteryMenuLine?.contains("charging") == true)
    }

    func testConnectedNormalBatteryWithoutChargingOrLow() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                batteryPercent: 64,
                isCharging: false,
                isLowBattery: false
            )
        )

        XCTAssertEqual(presentation.statusItemBatteryText, "64%")
        XCTAssertFalse(presentation.statusItemShowsCharging)
        XCTAssertFalse(presentation.statusItemIsLowBattery)
        XCTAssertEqual(presentation.batteryMenuLine, "Battery: 64%")
    }

    func testDisconnectedConnectionUsesFriendlyErrorWhenPresent() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: false,
                commandError: .deviceBusy,
                connectionStatusLine: MenuStatusModel.friendlyMessage(for: .deviceBusy)
            )
        )

        XCTAssertEqual(presentation.connectionLine, "Mouse busy — retrying")
        XCTAssertNil(presentation.connectedDetailLine)
        XCTAssertNil(presentation.battery)
    }

    func testAwaitingConsentUsesArmNotRearm() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                remapperStatus: .awaitingConsent,
                showRemapperSection: true
            )
        )

        XCTAssertEqual(presentation.recoveryAction, .armRemapper)
        XCTAssertEqual(presentation.recoveryButtonTitle, "Arm Remapper")
        XCTAssertFalse(presentation.showPauseResume)
    }

    // MARK: - Connected status visibility (review gaps)

    func testConnectedPlainStatusHidesDetailLine() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                connectionStatusLine: "Connected"
            )
        )

        XCTAssertEqual(presentation.connectionLine, "Connected")
        XCTAssertNil(presentation.connectedDetailLine)
    }

    func testConnectedVerificationAndDegradedStatusesAppearAsDetail() {
        let notVerified = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                connectionStatusLine: "Connected (profile not verified)"
            )
        )
        XCTAssertEqual(
            notVerified.connectedDetailLine,
            "Connected (profile not verified)"
        )

        let degraded = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                connectionStatusLine: "Connected (5-second disconnect polling)"
            )
        )
        XCTAssertEqual(
            degraded.connectedDetailLine,
            "Connected (5-second disconnect polling)"
        )

        let applied = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                connectionStatusLine: "Applied profile Default"
            )
        )
        XCTAssertEqual(applied.connectedDetailLine, "Applied profile Default")
    }

    func testConnectedCommandErrorPrefersFriendlyDetailOverStatusLine() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                commandError: .blockedDeviceAccess("synapse"),
                connectionStatusLine: "Connected"
            )
        )

        XCTAssertEqual(
            presentation.connectedDetailLine,
            "Another app controls the mouse"
        )
        XCTAssertNotEqual(
            presentation.connectedDetailLine,
            RazerCommandError.blockedDeviceAccess("synapse").localizedDescription
        )

        let busy = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                commandError: .deviceBusy,
                connectionStatusLine: "Connected (profile not verified)"
            )
        )
        XCTAssertEqual(busy.connectedDetailLine, "Mouse busy — retrying")
    }

    func testConnectedApplyFailureDetailIsFriendly() {
        let presentation = MenuStatusModel.make(
            inputs: .fixture(
                isConnected: true,
                connectionStatusLine: "Profile apply failed"
            )
        )
        XCTAssertEqual(presentation.connectedDetailLine, "Profile apply failed")
    }

    // MARK: - Reconnect publish policy (review gaps)

    func testReconnectFeedbackNotPublishedOnFirstConnection() {
        XCTAssertFalse(
            MenuReconnectFeedbackPolicy.shouldPublish(
                becameConnected: true,
                hadPriorSuccessfulConnection: false
            )
        )
        XCTAssertNil(
            MenuReconnectFeedbackPolicy.feedback(
                becameConnected: true,
                hadPriorSuccessfulConnection: false,
                profileApplied: true
            )
        )
    }

    func testReconnectFeedbackPublishedOnlyAfterPriorConnection() {
        XCTAssertTrue(
            MenuReconnectFeedbackPolicy.shouldPublish(
                becameConnected: true,
                hadPriorSuccessfulConnection: true
            )
        )
        XCTAssertEqual(
            MenuReconnectFeedbackPolicy.feedback(
                becameConnected: true,
                hadPriorSuccessfulConnection: true,
                profileApplied: true
            ),
            .profileReapplied
        )
        XCTAssertEqual(
            MenuReconnectFeedbackPolicy.feedback(
                becameConnected: true,
                hadPriorSuccessfulConnection: true,
                profileApplied: false
            ),
            .profileNotApplied
        )
        XCTAssertNil(
            MenuReconnectFeedbackPolicy.feedback(
                becameConnected: false,
                hadPriorSuccessfulConnection: true,
                profileApplied: true
            )
        )
    }

    // MARK: - Disconnect / apply status clearance (review gaps)

    func testDisconnectWarningClearsUnrelatedStaleWarnings() {
        XCTAssertNil(MenuStatusModel.disconnectWarningMessage(for: nil))
        XCTAssertNil(MenuStatusModel.disconnectWarningMessage(for: .deviceBusy))
        XCTAssertNil(MenuStatusModel.disconnectWarningMessage(for: .timeout))
        XCTAssertEqual(
            MenuStatusModel.disconnectWarningMessage(for: .permissionDenied("x")),
            "Permission needed — open Settings"
        )
        XCTAssertEqual(
            MenuStatusModel.disconnectWarningMessage(for: .blockedDeviceAccess("y")),
            "Another app controls the mouse"
        )
    }

    func testSuccessfulApplyClearsLatchedDeviceErrorState() {
        let cleared = MenuStatusModel.deviceStatusAfterSuccessfulApply(profileName: "Work")
        XCTAssertNil(cleared.lastCommandError)
        XCTAssertNil(cleared.hardwareVerificationWarning)
        XCTAssertNil(cleared.warningMessage)
        XCTAssertEqual(cleared.statusMessage, "Applied profile Work")
    }

    func testUnverifiedApplyClearsStaleCommandErrorSoDetailShowsVerification() {
        let status = MenuStatusModel.deviceStatusAfterUnverifiedApply(
            verificationWarning: "DPI stage mismatch after reapply"
        )
        XCTAssertNil(status.lastCommandError)
        XCTAssertEqual(status.statusMessage, "Profile applied but not verified")
        XCTAssertEqual(status.hardwareVerificationWarning, "DPI stage mismatch after reapply")
        XCTAssertEqual(status.warningMessage, "DPI stage mismatch after reapply")

        // Precedence: without clearing lastCommandError, detail would stay on the old error.
        let withStaleError = MenuStatusModel.connectedDetailLine(
            connectionStatusLine: status.statusMessage,
            commandError: .deviceBusy
        )
        XCTAssertEqual(withStaleError, "Mouse busy — retrying")

        let afterClear = MenuStatusModel.connectedDetailLine(
            connectionStatusLine: status.statusMessage,
            commandError: status.lastCommandError
        )
        XCTAssertEqual(afterClear, "Profile applied but not verified")
    }

    func testGenericApplyFailureClearsStaleWarningAndCommandError() {
        let status = MenuStatusModel.deviceStatusAfterGenericApplyFailure()
        XCTAssertNil(status.lastCommandError)
        XCTAssertNil(status.hardwareVerificationWarning)
        XCTAssertNil(status.warningMessage)
        XCTAssertEqual(status.statusMessage, "Profile apply failed")
        XCTAssertEqual(
            MenuStatusModel.connectedDetailLine(
                connectionStatusLine: status.statusMessage,
                commandError: status.lastCommandError
            ),
            "Profile apply failed"
        )
    }
}

// MARK: - Fixtures

private extension MenuStatusInputs {
    static func fixture(
        isConnected: Bool = false,
        batteryPercent: Int = 0,
        isCharging: Bool = false,
        isLowBattery: Bool = false,
        commandError: RazerCommandError? = nil,
        connectionStatusLine: String = "Waiting for mouse…",
        remapperStatus: RemapperRuntimeStatus = .disabled,
        showRemapperSection: Bool = false,
        persistenceWarning: String? = nil,
        reconnectFeedback: MenuReconnectFeedback? = nil
    ) -> MenuStatusInputs {
        MenuStatusInputs(
            isConnected: isConnected,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isLowBattery: isLowBattery,
            commandError: commandError,
            connectionStatusLine: connectionStatusLine,
            remapperStatus: remapperStatus,
            showRemapperSection: showRemapperSection,
            persistenceWarning: persistenceWarning,
            reconnectFeedback: reconnectFeedback
        )
    }
}
