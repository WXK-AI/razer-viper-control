import XCTest
@testable import RazerCore

final class ControlModelsTests: XCTestCase {
    func testShortcutDisplayNamesUseMacOSModifierFlags() {
        let commandA = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0010_0000)
        XCTAssertEqual(commandA.displayName, "⌘A")

        let shiftA = KeyboardShortcut(keyCode: 0, modifierFlags: 0x0002_0000)
        XCTAssertEqual(shiftA.displayName, "⇧A")

        let complex = KeyboardShortcut(keyCode: 15, modifierFlags: 0x0004_0000 | 0x0008_0000 | 0x0010_0000)
        XCTAssertEqual(complex.displayName, "⌃⌥⌘R")
    }

    func testOpenURLValidation() {
        XCTAssertNil(ButtonActionValidator.validateOpenURL("https://example.com"))
        XCTAssertEqual(ButtonActionValidator.normalizedOpenURL("  https://example.com/path  "), "https://example.com/path")

        XCTAssertEqual(ButtonActionValidator.validateOpenURL(""), .empty)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("   "), .empty)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("ftp://example.com"), .invalidScheme)
        XCTAssertEqual(ButtonActionValidator.validateOpenURL("https://"), .missingHost)
        XCTAssertNil(ButtonActionValidator.normalizedOpenURL("not-a-url"))
    }

    func testRemapperStatusDisabledWhenProfileRemappingOff() {
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: false,
            remapperArmed: true,
            permissions: .init(inputMonitoringGranted: true, accessibilityGranted: true),
            isRunning: true,
            isPaused: false,
            isRecovering: false,
            lastError: nil
        )
        XCTAssertEqual(status, .disabled)
        XCTAssertNil(status.recoveryAction)
    }

    func testRemapperStatusAwaitingConsentWhenEnabledButUnarmed() {
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: false,
            permissions: .init(inputMonitoringGranted: true, accessibilityGranted: true),
            isRunning: false,
            isPaused: false,
            isRecovering: false,
            lastError: nil
        )
        XCTAssertEqual(status, .awaitingConsent)
        XCTAssertEqual(status.recoveryAction, .armRemapper)
    }

    func testRemapperStatusAwaitingConsentOutranksPermissionsAndRunningState() {
        let permissions = PermissionStatus(inputMonitoringGranted: false, accessibilityGranted: true)
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: false,
            permissions: permissions,
            isRunning: true,
            isPaused: false,
            isRecovering: true,
            lastError: nil
        )
        XCTAssertEqual(status, .awaitingConsent)
        XCTAssertEqual(status.recoveryAction, .armRemapper)
    }

    func testRemapperStatusMissingPermissionOutranksRunningState() {
        let permissions = PermissionStatus(inputMonitoringGranted: false, accessibilityGranted: true)
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: true,
            permissions: permissions,
            isRunning: true,
            isPaused: false,
            isRecovering: true,
            lastError: nil
        )
        XCTAssertEqual(status, .missingPermission(permissions))
        XCTAssertEqual(status.recoveryAction, .openInputMonitoring)
    }

    func testRemapperStatusPermissionRecoveryActions() {
        XCTAssertEqual(
            RemapperRuntimeStatus.missingPermission(
                .init(inputMonitoringGranted: false, accessibilityGranted: false)
            ).recoveryAction,
            .openPrivacySettings
        )
        XCTAssertEqual(
            RemapperRuntimeStatus.missingPermission(
                .init(inputMonitoringGranted: true, accessibilityGranted: false)
            ).recoveryAction,
            .openAccessibility
        )
    }

    func testRemapperStatusFailedWhenEnabledButNotRunning() {
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: true,
            permissions: .init(inputMonitoringGranted: true, accessibilityGranted: true),
            isRunning: false,
            isPaused: false,
            isRecovering: false,
            lastError: "tap creation failed"
        )
        XCTAssertEqual(status, .failed("tap creation failed"))
        XCTAssertEqual(status.recoveryAction, .retryStart)
    }

    func testRemapperStatusRecoveringPausedAndActive() {
        let ready = PermissionStatus(inputMonitoringGranted: true, accessibilityGranted: true)
        XCTAssertEqual(
            RemapperRuntimeStatusResolver.resolve(
                remapperEnabled: true,
                remapperArmed: true,
                permissions: ready,
                isRunning: true,
                isPaused: true,
                isRecovering: true,
                lastError: nil
            ),
            .recovering
        )
        XCTAssertEqual(
            RemapperRuntimeStatusResolver.resolve(
                remapperEnabled: true,
                remapperArmed: true,
                permissions: ready,
                isRunning: true,
                isPaused: true,
                isRecovering: false,
                lastError: nil
            ),
            .paused
        )
        XCTAssertEqual(
            RemapperRuntimeStatusResolver.resolve(
                remapperEnabled: true,
                remapperArmed: true,
                permissions: ready,
                isRunning: true,
                isPaused: false,
                isRecovering: false,
                lastError: nil
            ),
            .active
        )
    }

    func testPauseDoesNotBypassAwaitingConsent() {
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: false,
            permissions: .init(inputMonitoringGranted: true, accessibilityGranted: true),
            isRunning: false,
            isPaused: false,
            isRecovering: false,
            lastError: nil
        )
        XCTAssertEqual(status, .awaitingConsent)
        XCTAssertNotEqual(status.recoveryAction, .resume)
    }

    func testCircuitOpenShowsRearmStatusEvenAfterSessionDisarm() {
        let status = RemapperRuntimeStatusResolver.resolve(
            remapperEnabled: true,
            remapperArmed: false,
            permissions: .init(inputMonitoringGranted: true, accessibilityGranted: true),
            isRunning: false,
            isPaused: true,
            isRecovering: false,
            lastError: nil,
            circuitOpen: true
        )

        XCTAssertEqual(status, .circuitOpen)
        XCTAssertEqual(status.title, "Remapper paused (safety)")
        XCTAssertEqual(status.detail, "Remapper paused after repeated event-tap timeouts.")
        XCTAssertEqual(status.recoveryAction, .rearmRemapper)
        XCTAssertEqual(status.recoveryAction?.buttonTitle, "Re-arm…")
    }

    func testUIPausedFlagStaysTrueWhenResumeFails() {
        XCTAssertTrue(RemapperPausePolicy.uiPaused(afterResumeSucceeded: false))
        XCTAssertFalse(RemapperPausePolicy.uiPaused(afterResumeSucceeded: true))
    }
}
