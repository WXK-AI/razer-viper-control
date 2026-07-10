# Razer-Only Remapping And Full Hardening Implementation Plan

> **For Claude/Cursor:** Use the repository's plan-execution workflow and implement this document task-by-task. Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` when available.

**Goal:** Ship one release in which button and wheel remapping applies only to the Razer Viper V3 HyperSpeed, all confirmed review defects are fixed, and the app is Developer ID signed and notarized with its HID DriverKit extension.

**Architecture:** A HID DriverKit system extension is the sole owner of USB HID device `1532:00B8`. It reads physical reports, applies stateful mouse and scroll mappings, emits translated HID events, serializes 90-byte feature-report round trips, and exposes a narrow validated user-client API. The Swift menu-bar app remains responsible for profiles, UI, system-extension activation, OS-level one-shot actions, launch-at-login state, persistence, and release diagnostics. There is no system-wide remapping fallback.

**Tech Stack:** Swift 5.9+, SwiftUI, IOKit, SystemExtensions, DriverKit, HIDDriverKit, C++17, XCTest, Swift Package Manager, XcodeGen, GitHub Actions, codesign, notarytool.

---

## Goal

Deliver version 2 of the input architecture and fix all P1/P2 defects found in the repository-wide review. Hardware configuration must continue to support battery, charging, DPI stages, active DPI, polling rate, profiles, auto-reapply, and wheel capability probing. Remapping must never alter a trackpad, another mouse, or another Razer model.

## Current Codebase Facts

- Core HID/protocol/profile code is in `Sources/RazerCore/`.
- The menu-bar app is in `RazerMenuBarApp/` and is `@MainActor` through `AppModel`.
- CLI diagnostics are in `Sources/RazerProbeCLI/main.swift`.
- The generated Xcode project is controlled by `project.yml` and `scripts/xcode-build.sh`.
- The current `CGEvent` session tap in `Sources/RazerCore/InputRemapper.swift` is global and cannot identify the originating HID device.
- The current event state tracks only synthetic mouse-button targets. It does not snapshot passthrough/consumed down events, translate drag events, preserve source click metadata, or release all held outputs during every recovery path.
- `RazerReport.decodeDPIStages()` reads each stage one byte late.
- `RazerCommandClient` validates CRC/status but does not correlate successful responses with the request transaction, class, command, size, or packet count.
- `ProfileStore.load()` silently converts every read/decode error into a default bundle.
- UI edits immediately enter the canonical profile and every edit queues a full hardware apply.
- CLI mutation commands do not guarantee restoration.
- Release scripts can delete an arbitrary directory supplied as the DMG output, reuse stale app bundles, and publish a tag that disagrees with the app version.
- Unit tests currently cover pure Swift core logic only. There are no app-state, DriverKit transport, CLI rollback, real event-sequence, or release-contract tests.
- The current test `testProfileStoreLoadMigratesLegacyBundle` writes into real Application Support; repeated test runs have leaked files.
- Baseline verification on 2026-07-10: 53 Swift tests pass and the Debug app builds. A strict-concurrency app build emits Swift 6 isolation warnings in `AppModel`.

## Decisions Made

- Remapping must be Razer-only in this release, not a later phase.
- Use Apple-supported HID DriverKit and System Extensions APIs.
- Obtain Apple-approved DriverKit entitlements and use Developer ID signing/notarization as release gates.
- The driver extension is the single owner of both input and feature-report transport for `1532:00B8`.
- Do not fall back to the current global remapper when the extension is unavailable. Local profile editing remains available, while hardware read/apply and remapping are disabled with an actionable driver status.
- Keep profile persistence and product policy in Swift. Send a validated, versioned runtime mapping snapshot to the driver.
- Process mouse-target mappings, disabled controls, button hold/drag/up state, wheel scaling, and output release in the driver.
- Send one-shot action notifications from the driver to the app. The app executes keyboard shortcuts, DPI/profile cycling, URL opening, and app launching off the input callback path.
- Preserve the keyboard emergency shortcut with a listen-only keyboard tap in the app. Add a device-local emergency chord in the driver so recovery does not depend on app IPC.
- Recommended device-local emergency chord: hold Side Button 1 + Side Button 2 + Wheel Click for three seconds. It pauses remapping and releases all synthetic outputs.
- Keep the existing JSON profile schema where possible. Compile aliases and optional software wheel actions into a canonical driver snapshot rather than teaching the driver migration rules.
- Use typed subsystem state and errors. A successful HID refresh must not erase persistence, launch-at-login, driver-installation, or remapper errors.
- Use test-first changes and small commits. Do not combine the DriverKit architecture with unrelated visual redesign.

## External Release Gates

- Apple Developer Program membership and Developer ID Application certificate are available.
- Apple approves the required DriverKit entitlement group for the team.
- Provisioning profiles are created for the host app and driver extension.
- GitHub Actions receives signing certificate, keychain password, provisioning profiles, and notarization credentials as encrypted secrets.
- A physical Viper V3 HyperSpeed and at least one second pointing device or trackpad are available for acceptance testing.

Do not mark the release complete while any gate above remains unresolved. Code can be developed with DriverKit developer mode, but an ad-hoc build is not a distributable substitute.

## Open Questions

No product or architecture questions remain. Entitlement approval, verified interface matching, and physical-device report behavior are external gates to resolve through Tasks 1 and 8, not reasons to silently change the selected architecture.

## Non-Goals

- Supporting additional Razer product IDs.
- RGB control, onboard profile storage, macros, or cloud profile sync.
- A Mac App Store release.
- Retaining the current global mouse/scroll remapper as a compatibility mode.
- Reworking the visual design beyond states needed for driver installation, recovery, validation, and diagnostics.

## Definition Of Done

- Trackpad and second-mouse input is byte-for-byte behaviorally unaffected while Razer remapping is active.
- Every physical Razer button down has exactly one recorded disposition and matching drag/up behavior.
- Pause, extension loss, app/client loss, profile replacement, transport interruption, sleep, dongle removal, and emergency recovery release all held outputs.
- DPI-stage decoding matches OpenRazer fixtures and HID responses are request-correlated.
- Corrupt profiles are quarantined and reported; invalid drafts cannot poison persistence.
- CLI mutation commands restore exact original state on success, thrown errors, interruption, and failed verification.
- Release scripts cannot recursively delete a directory, reuse stale output, or publish mismatched version/tag artifacts.
- The app and driver are Developer ID signed, notarized, stapled, and pass Gatekeeper assessment.
- Automated tests, strict-concurrency build, release checks, and the physical acceptance matrix all pass.

## Implementation Steps

### Task 1: Secure Entitlements And Establish The Release Gate

**Files:**

- Create: `docs/driverkit-entitlements.md`
- Modify: `README.md`

**Steps:**

- [ ] Request an entitlement group containing at minimum `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.hid`, `com.apple.developer.driverkit.family.hid.eventservice`, and the virtual-HID entitlement required by the final event-service design. *(operator: submit in Apple Developer account; tracked in `docs/driverkit-entitlements.md`)*
- [ ] Enable `com.apple.developer.system-extension.install` and restricted driver user-client access for the host app identifier. *(operator)*
- [ ] Create explicit App IDs and development/distribution profiles for `com.razermenubar.RazerMenuBarApp` and `com.razermenubar.RazerViperHIDDriver`. *(operator)*
- [x] Document identifiers, requested capabilities, approval status, profile names, and renewal dates without committing certificates, credentials, or profile files.
- [x] Add a README release prerequisite explaining that Razer-only remapping requires the approved extension and that ad-hoc releases cannot activate it.
- [ ] Commit: `docs: record DriverKit entitlement and signing gates`.

**Verification:** Confirm the entitlement request is visible in the Apple developer account and both local development profiles can be selected by Xcode.

### Task 2: Add Failing Protocol And Report-Safety Tests

**Files:**

- Modify: `Tests/RazerCoreTests/RazerReportTests.swift`
- Create: `Tests/RazerCoreTests/RazerResponseValidatorTests.swift`

**Steps:**

- [x] Add an OpenRazer-compatible DPI-stage response fixture with active stage 2 and stages 400, 800, and 1600.
- [x] Assert `decodeDPIStages()` returns exactly those values. Run the test and confirm it fails with shifted values.
- [x] Add fixtures for oversized `dataSize`, stage count greater than five, truncated stage payload, and active stage outside `1...count`.
- [x] Add response-correlation tests for wrong transaction ID, remaining packets, protocol type, command class, command ID, and incompatible data size.
- [x] Add a serialization test proving a report with fewer or more than 80 argument bytes cannot crash `bytes`.
- [x] Run: `swift test --disable-sandbox --filter RazerReportTests`.
- [x] Expected before implementation: the offset and malformed-response tests fail.
- [ ] Commit tests separately: `test: cover Razer response layout and correlation`.

### Task 3: Harden Report Encoding, Decoding, And Response Correlation

**Files:**

- Modify: `Sources/RazerCore/RazerReport.swift`
- Modify: `Sources/RazerCore/RazerCommandClient.swift`
- Create: `Sources/RazerCore/RazerResponseValidator.swift`
- Modify: `Tests/RazerCoreTests/RazerReportTests.swift`
- Modify: `Tests/RazerCoreTests/RazerResponseValidatorTests.swift`

**Required implementation shape:**

```swift
public protocol RazerReportTransport: Sendable {
    func roundTrip(_ request: [UInt8]) throws -> [UInt8]
}

public enum RazerResponseValidator {
    public static func validate(
        response: RazerReport,
        for request: RazerReport,
        allowingUnsupported: Bool
    ) throws -> CommandSendResult
}
```

**Steps:**

- [x] Change DPI-stage decoding to read X from `[offset, offset + 1]` and Y from `[offset + 2, offset + 3]`, then advance by seven.
- [x] Validate `dataSize <= 80` while decoding raw reports.
- [x] Validate DPI stage count, declared payload length, active stage, and decoded DPI ranges before returning stage data.
- [x] Make `RazerReport.arguments` fixed-length by construction. Reject or normalize external arrays at initialization and prevent callers from replacing them with a differently sized array.
- [x] Extract response validation from the IOHID implementation so it can be tested without hardware and reused after DriverKit migration.
- [x] Require matching transaction ID, zero remaining packets, protocol type, command class, and command ID before accepting status.
- [x] Decide data-size compatibility per command: exact match for fixed responses; explicitly documented minimum only where the device returns a larger known payload.
- [x] Treat correlation mismatch as `invalidResponse`; allow the caller to invalidate/reopen the session.
- [x] Avoid sleeping after the final BUSY attempt.
- [x] Run: `swift test --disable-sandbox --filter RazerReportTests` and `swift test --disable-sandbox --filter RazerResponseValidatorTests`.
- [ ] Commit: `fix: validate and correlate Razer feature reports`.

### Task 4: Make Profile Loading Recoverable And Tests Hermetic

**Files:**

- Modify: `Sources/RazerCore/ProfileStore.swift`
- Modify: `Tests/RazerCoreTests/MouseProfileMigrationTests.swift`
- Create: `Tests/RazerCoreTests/ProfileStoreRecoveryTests.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`

**Required model:**

```swift
public enum ProfileLoadOutcome: Equatable, Sendable {
    case loaded(ProfileBundle)
    case firstRun(ProfileBundle)
    case recovered(ProfileBundle, quarantinedURL: URL, reason: String)
}
```

**Steps:**

- [ ] Add an injectable application-support directory URL. Tests must use a unique temporary directory, not `FileManager.default` production storage.
- [ ] Distinguish file-not-found from read failure and decode failure.
- [ ] On corruption, atomically move the source to `profiles-<device>-corrupt-<timestamp>.json` before returning defaults.
- [ ] Preserve the corruption warning until the user dismisses it; successful HID refresh must not clear it.
- [ ] Repair nil/dangling `selectedProfileID` to the actual fallback profile ID during load and save the repaired bundle.
- [ ] Return validation errors without replacing the last valid persisted bundle.
- [ ] Update migration tests to remove their temporary directory in teardown.
- [ ] Add tests for first run, malformed JSON, unreadable file, dangling selection, failed quarantine, failed save, and legacy alias migration.
- [ ] Run: `swift test --disable-sandbox --filter ProfileStore`.
- [ ] Remove existing leaked `profiles-migration-test-*.json` files manually only after confirming they are test artifacts.
- [ ] Commit: `fix: preserve and recover malformed profile storage`.

### Task 5: Separate Valid UI Drafts From Canonical Profiles

**Files:**

- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Create: `RazerMenuBarApp/ProfileDraft.swift`
- Create: `Tests/RazerCoreTests/ProfileDraftValidationTests.swift` or an app-target XCTest equivalent

**Steps:**

- [ ] Represent editable DPI fields as strings or validated draft values; do not mutate `bundle` until every stage is parseable and within `100...30000`.
- [ ] Validate active stage and polling rate at the same boundary.
- [ ] Show field-level errors and disable Apply while the draft is invalid.
- [ ] Track persistence as `.clean`, `.dirty`, or `.failed(message)` instead of storing save failures in the generic HID warning.
- [ ] Make `flushPendingSave()` return success/failure.
- [ ] Prevent termination after a failed required flush unless the user explicitly chooses to discard unsaved changes.
- [ ] Add tests for intermediate empty text, nonnumeric text, out-of-range values, valid correction, and quit with save failure.
- [ ] Commit: `fix: validate profile drafts before persistence`.

### Task 6: Make CLI Parsing And Hardware Mutation Transactional

**Files:**

- Create: `Sources/RazerCore/HardwareStateTransaction.swift`
- Refactor: `Sources/RazerProbeCLI/main.swift`
- Create: `Tests/RazerCoreTests/HardwareStateTransactionTests.swift`
- Create: `Tests/RazerProbeCLITests/ProbeArgumentParserTests.swift`
- Modify: `Package.swift`

**Steps:**

- [ ] Extract a throwing argument parser. Reject unknown commands, missing/extra parameters, invalid integers, and nonpositive capture durations with exit code 64.
- [ ] Introduce an injectable command client so CLI behavior can be tested without a mouse.
- [ ] Capture exact original X/Y DPI, polling, and every wheel value before the first mutation.
- [ ] Do not mutate a feature whose original value is unknown.
- [ ] Install guaranteed restoration before mutation. Preserve the primary error and report restoration failure separately.
- [ ] Verify temporary and restored readback values; return nonzero on mismatch or `.unknown` probe state.
- [ ] Do not collapse asymmetric X/Y DPI during restoration. Add `setDPI(x:y:)` if required.
- [ ] Add failure-injection tests after each mutation/readback step and assert exact restoration attempts.
- [ ] Run: `swift test --disable-sandbox --filter HardwareStateTransactionTests` and CLI parser tests.
- [ ] Commit: `fix: make CLI probes transactional and strict`.

### Task 7: Make Packaging And Release Scripts Non-Destructive

**Files:**

- Modify: `scripts/ci-release-build.sh`
- Modify: `scripts/package-dmg.sh`
- Modify: `scripts/sign-release.sh`
- Create: `scripts/verify-release-contract.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`

**Steps:**

- [ ] Reject a DMG output argument that exists as a directory or does not end in `.dmg`.
- [ ] Replace recursive removal of the output DMG with `rm -f -- "$DMG"`; keep recursive deletion limited to script-owned staging paths beneath `build/Release` after canonical-path validation.
- [ ] Build into a fresh release directory and remove any prior destination app before copying.
- [ ] Make `sign-release.sh` rebuild by default. Require an explicit `--reuse-existing-build` flag for a deliberate reuse path and verify source revision metadata when used.
- [ ] Centralize XcodeGen generation; pin a compatible XcodeGen version instead of editing `project.pbxproj` object versions with `sed`.
- [ ] Make release tag and `CFBundleShortVersionString` equality mandatory.
- [ ] Make architecture explicit for both app and CLI and verify each artifact with `lipo -info`.
- [ ] Correct README wording to “ad-hoc signed” where appropriate; the new official release path must be Developer ID signed and notarized.
- [ ] Add shell-level tests or a dry-run mode proving directory DMG paths are rejected and stale output is removed.
- [ ] Run `bash -n scripts/*.sh`; run `shellcheck scripts/*.sh` in CI.
- [ ] Commit: `fix: make release packaging reproducible and non-destructive`.

### Task 8: Prove The DriverKit Architecture On The Physical Device

This is a hard implementation checkpoint. Do not proceed to the complete remapper until all acceptance conditions pass.

**Files:**

- Modify: `project.yml`
- Create: `RazerHIDDriver/Info.plist`
- Create: `RazerHIDDriver/RazerHIDDriver.entitlements`
- Create: `RazerHIDDriver/RazerHIDDriver.iig`
- Create: `RazerHIDDriver/RazerHIDDriver.hpp`
- Create: `RazerHIDDriver/RazerHIDDriver.cpp`
- Modify: `RazerMenuBarApp/RazerMenuBarApp.entitlements`
- Create: `RazerMenuBarApp/SystemExtensionManager.swift`
- Create: `docs/testing/driverkit-spike.md`

**Steps:**

- [ ] Add a DriverKit extension target with raw product type `com.apple.product-type.driver-extension` if required by XcodeGen, plus host-app embedding under `Contents/Library/SystemExtensions`.
- [ ] Match only vendor `0x1532`, product `0x00B8`, and the verified mouse/control interface criteria. Do not match all Razer devices.
- [ ] Add host activation/deactivation using `OSSystemExtensionRequest` and publish activation states.
- [ ] Start with passthrough report handling: motion, left/right/middle, side buttons, DPI button if emitted, vertical wheel, and horizontal wheel.
- [ ] Prove the extension is the only event producer for the target interface; no duplicate pointer/button/scroll events are acceptable.
- [ ] Prove a trackpad and second mouse remain handled by their normal drivers.
- [ ] Prove a 90-byte feature-report set/get round trip works while the extension owns the device.
- [ ] Test dongle unplug/replug and sleep/wake without rebooting or reinstalling the extension.
- [ ] Record actual input report descriptors, button numbers, wheel axes, interface matching keys, and feature-report behavior in `docs/testing/driverkit-spike.md`.
- [ ] If any proof fails, stop and revise the architecture before continuing. Do not restore the global remapper as a shortcut.
- [ ] Commit: `feat: prove Viper HID DriverKit ownership`.

### Task 9: Define A Versioned Driver User-Client Protocol

**Files:**

- Create: `RazerDriverShared/include/RazerDriverProtocol.h`
- Create: `Sources/RazerCore/DriverWireModels.swift`
- Create: `Tests/RazerCoreTests/DriverWireModelsTests.swift`
- Modify: `RazerHIDDriver/RazerHIDDriver.iig`

**Required protocol characteristics:**

```c
enum { RZ_DRIVER_PROTOCOL_VERSION = 1, RZ_REPORT_LENGTH = 90 };

typedef enum : uint32_t {
    RZMethodGetHealth = 0,
    RZMethodRoundTripFeatureReport = 1,
    RZMethodInstallRuntimeProfile = 2,
    RZMethodSetPaused = 3,
    RZMethodReleaseAllOutputs = 4,
    RZMethodRegisterEventQueue = 5
} RZExternalMethod;
```

**Steps:**

- [ ] Use fixed-width integer fields, explicit sizes, schema version, and `static_assert` for every shared structure.
- [ ] Define methods for health, serialized feature round trip, runtime profile installation, pause/resume, release-all, and event callback registration.
- [ ] Define callback events for connection changes, physical diagnostics, one-shot actions, emergency pause, protocol errors, and transport reset.
- [ ] Bound all counts and strings. Do not send file paths or URLs to the driver; send opaque action tokens resolved by the app.
- [ ] Validate method selector, structure size, schema version, enum range, mapping count, finite scroll multiplier, and action token before use.
- [ ] Reject unknown newer schema versions cleanly so app/driver mismatch is visible.
- [ ] Add Swift layout/round-trip tests against constants exported by the C header.
- [ ] Commit: `feat: define validated app-driver protocol`.

### Task 10: Move Feature-Report Transport Behind The Driver

**Files:**

- Create: `Sources/RazerCore/RazerReportTransport.swift`
- Create: `Sources/RazerCore/DriverReportTransport.swift`
- Modify: `Sources/RazerCore/RazerCommandClient.swift`
- Refactor or remove from production path: `Sources/RazerCore/HIDDeviceDiscovery.swift`
- Refactor or remove from production path: `Sources/RazerCore/ProfileStore.swift` (`DeviceSession` section)
- Modify: `Sources/RazerProbeCLI/main.swift`
- Modify: `RazerHIDDriver/RazerHIDDriver.cpp`
- Create: `Tests/RazerCoreTests/RazerCommandClientTransportTests.swift`

**Steps:**

- [ ] Inject `RazerReportTransport` into `RazerCommandClient`; remove direct `IOHIDDevice` ownership from the command client.
- [ ] Implement the production transport through the restricted DriverKit user client.
- [ ] Serialize set/wait/get in the driver on one dispatch queue so callers cannot interleave feature-report transactions.
- [ ] Return typed transport statuses for disconnected, permission denied, timeout, busy, unsupported, malformed response, and app/driver protocol mismatch.
- [ ] Make connection reset explicit; do not turn transport errors into diagnostic strings before the caller can react.
- [ ] Route both app and CLI through the driver transport. Do not let the CLI race the extension with direct IOHID opens.
- [ ] Add fake transport tests for busy retries, final retry timing, timeout, malformed length, stale response, disconnect, and reconnect.
- [ ] Commit: `refactor: route Razer commands through DriverKit`.

### Task 11: Compile Profiles Into Canonical Driver Runtime Configuration

**Files:**

- Create: `Sources/RazerCore/RuntimeProfileCompiler.swift`
- Modify: `Sources/RazerCore/ControlModels.swift`
- Modify: `Sources/RazerCore/InputRemapperEngine.swift`
- Create: `Tests/RazerCoreTests/RuntimeProfileCompilerTests.swift`

**Steps:**

- [ ] Compile only real assignable physical controls; resolve and remove the legacy middle/wheel alias before validation.
- [ ] Encode each control as passthrough, disabled, mouse target, or one-shot action token.
- [ ] Compile wheel direction, bounded finite vertical multiplier, native horizontal behavior, Shift conversion, wheel-up action, and wheel-down action.
- [ ] Validate that actual reachable bindings provide left and right click. Do not count both middle/wheel alias keys as separate physical buttons.
- [ ] Reject duplicate or missing action tokens and profiles too large for the fixed wire structure.
- [ ] Add tests for default profile, left/right swap, side-button replacement clicks, alias conflicts, primary-click warnings, invalid multipliers, and one-shot token resolution.
- [ ] Commit: `feat: compile profiles for the HID driver`.

### Task 12: Implement The Driver-Side Stateful Remapper

**Files:**

- Create: `RazerHIDDriver/RemapStateMachine.hpp`
- Create: `RazerHIDDriver/RemapStateMachine.cpp`
- Modify: `RazerHIDDriver/RazerHIDDriver.cpp`
- Create: `RazerHIDDriverTests/RemapStateMachineTests.mm`
- Modify: `project.yml`

**Required state model:**

```cpp
enum class DownDisposition : uint8_t {
    passthrough,
    consumed,
    remappedMouseButton,
    oneShotConsumed
};
```

Store a disposition for every physical down, including passthrough and consumed events. The matching drag/up must use that stored disposition even when a new profile arrives.

**Steps:**

- [ ] Parse the verified Viper input report into motion, control transitions, button mask, and both wheel axes.
- [ ] Snapshot down disposition and target button for every transition.
- [ ] Translate drag/motion while a remapped target is held; do not emit an original-button drag after a remapped down.
- [ ] Ignore profile changes for already-held controls until their matching up/release is complete.
- [ ] Preserve simultaneous controls independently and prevent duplicate downs/ups.
- [ ] Preserve native horizontal scroll and scale axes independently. Shift conversion must merge intentionally, not zero unrelated native movement.
- [ ] Classify wheel direction using line-equivalent/native report delta with a nonzero fallback; never classify positive fixed movement as down.
- [ ] Accumulate sub-unity scaling separately per axis and reset accumulators on profile replacement, pause, disconnect, and direction change.
- [ ] Emit one-shot callbacks only on physical down/notch boundaries, never on matching up.
- [ ] Implement `releaseAllOutputs()` and call it on pause, client loss, driver stop, profile invalidation, transport reset, sleep, unplug, and emergency chord.
- [ ] Make the three-second device-local emergency chord pause remapping and emit a reason callback.
- [ ] Add sequence tests for down/profile-change/up, down/pause/up, start while held, simultaneous buttons, drag, timeout, disconnect, two-axis scroll, fractional scroll, and emergency recovery.
- [ ] Commit: `feat: add stateful device-scoped remapping`.

### Task 13: Replace Global Capture And Remapping In The App

**Files:**

- Delete after migration: `Sources/RazerCore/InputRemapper.swift`
- Refactor: `Sources/RazerCore/InputCaptureSession.swift`
- Create: `RazerMenuBarApp/DriverEventCoordinator.swift`
- Create: `RazerMenuBarApp/EmergencyPauseMonitor.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `RazerMenuBarApp/RazerMenuBarApp.swift`

**Steps:**

- [ ] Remove the global mouse/scroll event tap completely.
- [ ] Keep only a listen-only keyboard event monitor for `Control+Option+Command+R`; it must enqueue pause to the driver and never perform file/URL/HID work inside the callback.
- [ ] Re-enable or recreate the keyboard monitor if macOS disables it; monitor failure must be visible but must not change driver remapping state.
- [ ] Execute one-shot callbacks on an ordered app queue or `MainActor`, outside the driver input callback.
- [ ] Validate URL/app targets again at execution time and report failures without blocking input.
- [ ] Replace global diagnostics capture with opt-in physical-event records supplied by the driver, including origin, down/up, raw report fields, resolved control, and action disposition.
- [ ] Stop diagnostics capture when the settings window closes, or show a persistent menu-bar capture indicator if product requirements later choose background capture.
- [ ] Remove synthetic-marker logic once no global mouse event tap can observe generated output.
- [ ] Add integration tests with a fake driver event stream.
- [ ] Commit: `refactor: replace global event taps with driver events`.

### Task 14: Redesign App State Around Driver And Subsystem Status

**Files:**

- Refactor: `RazerMenuBarApp/AppModel.swift`
- Create: `RazerMenuBarApp/AppServices.swift`
- Create: `RazerMenuBarApp/AppStatus.swift`
- Create: `RazerMenuBarAppTests/AppModelTests.swift`
- Modify: `project.yml`

**Required status separation:**

```swift
enum DriverStatus { case notInstalled, awaitingApproval, activating, ready, disconnected, failed(String) }
enum PersistenceStatus { case clean, dirty, failed(String) }
enum RemapperStatus { case unavailable, active, paused, failed(String) }
```

**Steps:**

- [ ] Inject driver connection, profile store, launch-at-login service, permission provider, workspace opener, and scheduler through protocols.
- [ ] Remove `nonisolated` access to MainActor-owned `session`; replace GCD ownership with an actor or a dedicated Sendable driver client.
- [ ] Make strict-concurrency warnings zero in the app target.
- [ ] Centralize profile activation so picker selection, add, delete, keyboard cycling, and recovery all update summary, mapping warning, driver runtime profile, hardware apply, and persistence consistently.
- [ ] Recompute mapping warnings from selected profile instead of manually maintaining stale copies.
- [ ] Separate software-only changes from hardware changes. Profile name, URL, button action, and software scroll edits must not write DPI/polling/wheel firmware.
- [ ] Coalesce hardware applies by generation and discard stale completions.
- [ ] After manual apply, update a complete device snapshot so connection icon and status cannot disagree.
- [ ] Make permission refresh immediately update keyboard emergency-monitor availability.
- [ ] Disable Pause unless the remapper is actually active; a failed/unavailable remapper cannot be pre-paused accidentally.
- [ ] Add state-transition tests for driver approval, reconnect, stale completion, profile add/delete/select, save failure, auto-apply failure, and permission changes.
- [ ] Commit: `refactor: model driver and app state explicitly`.

### Task 15: Finish Recovery UI And Lifecycle Behavior

**Files:**

- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `RazerMenuBarApp/RazerMenuBarApp.swift`
- Create: `RazerMenuBarApp/AppDelegate.swift`
- Modify: `Sources/RazerCore/LaunchAtLoginManager.swift`

**Steps:**

- [ ] Add a compact Driver status section with Install/Approve/Open System Settings/Retry actions as appropriate.
- [ ] State explicitly when hardware is available but remapping is unavailable; never silently activate global behavior.
- [ ] Show persistence, driver, hardware, launch-at-login, and mapping warnings independently.
- [ ] Publish the full `SMAppService.Status`, including `requiresApproval` and `notFound`, and refresh it on app activation.
- [ ] Flush valid dirty profiles through an application termination delegate, not only the custom Quit button.
- [ ] On failed termination save, offer Retry, Reveal Quarantined/Storage File, or Discard And Quit.
- [ ] Keep settings window activation behavior for the LSUIElement app.
- [ ] Remove dead `showSettings` state.
- [ ] Commit: `feat: add driver installation and recovery UI`.

### Task 16: Configure Signed DriverKit Builds And Notarized Releases

**Files:**

- Modify: `project.yml`
- Modify: `RazerMenuBarApp/RazerMenuBarApp.entitlements`
- Modify: `RazerHIDDriver/RazerHIDDriver.entitlements`
- Modify: `scripts/ci-release-build.sh`
- Modify: `scripts/sign-release.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `scripts/verify-release-contract.sh`

**Steps:**

- [ ] Embed the driver extension in the host app at the required system-extension path.
- [ ] Sign nested code explicitly from the inside out; do not use `codesign --deep` as the signing algorithm.
- [ ] Verify designated requirements, Team ID consistency, entitlements, hardened runtime, and provisioning profiles for app and extension.
- [ ] Make official release CI fail when Developer ID or notarization credentials are absent. Keep unsigned compile/test CI as a separate non-release workflow.
- [ ] Submit the final DMG to `notarytool`, wait, staple, and validate.
- [ ] Run `codesign --verify --strict --verbose=4`, `spctl --assess --type execute`, `stapler validate`, version/tag verification, architecture verification, and SHA-256 generation.
- [ ] Upload only artifacts produced in the current workflow run and attach source revision/version metadata.
- [ ] Commit: `build: sign and notarize the DriverKit release`.

### Task 17: Add Continuous Integration And Complete Test Coverage

**Files:**

- Create: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `Package.swift`
- Modify: `project.yml`
- Add tests under: `Tests/RazerCoreTests/`, `Tests/RazerProbeCLITests/`, `RazerMenuBarAppTests/`, `RazerHIDDriverTests/`

**Steps:**

- [ ] Run Swift core and CLI tests on every pull request and main-branch push.
- [ ] Build the host app and driver extension without distribution signing in CI.
- [ ] Run strict concurrency as warnings-as-errors for Swift targets.
- [ ] Run C++ warnings as errors for driver and state-machine targets.
- [ ] Run shell syntax, shellcheck, plist validation, generated-project drift, architecture, and version-contract checks.
- [ ] Add event-sequence regression tests for every P1 input finding.
- [ ] Add transport fault-injection tests for every feature-report phase and reconnect path.
- [ ] Add app-state tests for persistence, driver activation, profile activation, launch-at-login, diagnostics lifecycle, and termination.
- [ ] Add release-script tests using temporary directories; never point tests at real Application Support or release output.
- [ ] Commit: `ci: test app driver CLI and release contracts`.

### Task 18: Run Physical Acceptance And Release Qualification

**Files:**

- Create: `docs/testing/razer-viper-v3-acceptance.md`
- Modify: `README.md`

**Acceptance matrix:**

- [ ] Fresh install: extension approval flow succeeds without disabling SIP or enabling developer mode.
- [ ] Default profile: movement, left/right click, wheel, middle click, side buttons, and DPI behavior match an unmanaged mouse.
- [ ] Device isolation: trackpad and second mouse remain unchanged under left/right swap, disabled controls, wheel inversion, and speed scaling.
- [ ] Stateful input: remapped click-and-hold drag works in Finder and a drawing app; profile changes while held do not stick either source or target button.
- [ ] Click fidelity: Shift-click, Command-click, double-click, and multi-display click placement work.
- [ ] Wheel: slow multiplier, fast multiplier, inversion, native horizontal, Shift horizontal, diagonal input, wheel actions, and rapid notches work without loss or action storms.
- [ ] Recovery: menu pause, keyboard emergency shortcut, device-local emergency chord, app force-quit, driver restart, app/driver callback interruption, sleep/wake, dongle removal, and reconnect release all outputs.
- [ ] Hardware: battery, charging, DPI read/write, stage read/write, polling, auto-reapply, and supported/unsupported wheel commands report correctly.
- [ ] Persistence: invalid draft, disk-full/save failure, corrupt JSON, dangling selected ID, migration, and restart preserve or recover data correctly.
- [ ] CLI: invalid arguments return 64; every injected/physical failure restores exact original state or reports restoration failure.
- [ ] Distribution: install the notarized DMG on a clean non-development Mac account; Gatekeeper accepts it and extension activation succeeds.
- [ ] Soak: run for 24 hours with repeated sleep/wake and profile changes; no duplicated input, stuck buttons, stale battery, or growing HID queue.
- [ ] Record macOS version, hardware/firmware identifiers, app/driver version, and result for every row.
- [ ] Update README permissions, installation, DriverKit approval, emergency recovery, and removal instructions.
- [ ] Commit: `docs: record Viper v2 acceptance results`.

## Files Expected To Change

### Existing

- `Package.swift`
- `project.yml`
- `.github/workflows/release.yml`
- `README.md`
- `Makefile`
- `Sources/RazerCore/ControlModels.swift`
- `Sources/RazerCore/HIDDeviceDiscovery.swift`
- `Sources/RazerCore/InputCaptureSession.swift`
- `Sources/RazerCore/InputRemapper.swift` (delete after migration)
- `Sources/RazerCore/InputRemapperEngine.swift`
- `Sources/RazerCore/LaunchAtLoginManager.swift`
- `Sources/RazerCore/ProfileStore.swift`
- `Sources/RazerCore/RazerCommandClient.swift`
- `Sources/RazerCore/RazerReport.swift`
- `Sources/RazerCore/WheelCapabilityProbe.swift`
- `Sources/RazerProbeCLI/main.swift`
- `RazerMenuBarApp/AppModel.swift`
- `RazerMenuBarApp/RazerMenuBarApp.swift`
- `RazerMenuBarApp/SettingsView.swift`
- `RazerMenuBarApp/RazerMenuBarApp.entitlements`
- `scripts/ci-release-build.sh`
- `scripts/package-dmg.sh`
- `scripts/sign-release.sh`
- `scripts/xcode-build.sh`
- Existing tests under `Tests/RazerCoreTests/`

### New

- `RazerHIDDriver/`
- `RazerHIDDriverTests/`
- `RazerDriverShared/include/RazerDriverProtocol.h`
- `RazerMenuBarAppTests/`
- `Tests/RazerProbeCLITests/`
- `Sources/RazerCore/RazerResponseValidator.swift`
- `Sources/RazerCore/RazerReportTransport.swift`
- `Sources/RazerCore/DriverReportTransport.swift`
- `Sources/RazerCore/DriverWireModels.swift`
- `Sources/RazerCore/RuntimeProfileCompiler.swift`
- `Sources/RazerCore/HardwareStateTransaction.swift`
- `RazerMenuBarApp/SystemExtensionManager.swift`
- `RazerMenuBarApp/DriverEventCoordinator.swift`
- `RazerMenuBarApp/EmergencyPauseMonitor.swift`
- `RazerMenuBarApp/ProfileDraft.swift`
- `RazerMenuBarApp/AppServices.swift`
- `RazerMenuBarApp/AppStatus.swift`
- `RazerMenuBarApp/AppDelegate.swift`
- `scripts/verify-release-contract.sh`
- `.github/workflows/ci.yml`
- `docs/driverkit-entitlements.md`
- `docs/testing/driverkit-spike.md`
- `docs/testing/razer-viper-v3-acceptance.md`

## Tests And Verification Commands

Run targeted tests after each task, then run the complete matrix before release:

```bash
swift test --disable-sandbox

xcodegen generate
xcodebuild \
  -scheme RazerMenuBarApp \
  -configuration Debug \
  -derivedDataPath build/ReviewDerivedData \
  OTHER_SWIFT_FLAGS='-strict-concurrency=complete -warn-concurrency -warnings-as-errors' \
  build

xcodebuild \
  -scheme RazerHIDDriverTests \
  -configuration Debug \
  -derivedDataPath build/DriverTestsDerivedData \
  test

bash -n scripts/*.sh
shellcheck scripts/*.sh
plutil -lint RazerMenuBarApp/RazerMenuBarApp.entitlements
plutil -lint RazerHIDDriver/Info.plist
plutil -lint RazerHIDDriver/RazerHIDDriver.entitlements
bash scripts/verify-release-contract.sh

make xcode
bash scripts/ci-release-build.sh
bash scripts/sign-release.sh

codesign --verify --deep --strict --verbose=4 build/Release/RazerMenuBarApp.app
spctl --assess --type execute --verbose=4 build/Release/RazerMenuBarApp.app
xcrun stapler validate build/Release/RazerMenuBarApp-macOS.dmg
shasum -a 256 build/Release/RazerMenuBarApp-macOS.dmg
```

Expected final results:

- All Swift, app-state, CLI, transport, and C++ driver tests pass.
- Strict-concurrency and C++ warnings-as-errors builds produce zero warnings.
- Generated project is reproducible from `project.yml`.
- Release contract confirms tag, app version, driver version, Team ID, architectures, signatures, entitlements, and source revision.
- Gatekeeper and stapler validation pass.
- Every physical acceptance row is recorded as pass on a clean installation.

## Cursor Handoff Prompt

```text
Implement docs/plans/2026-07-10-razer-only-remapping-and-hardening.md.

Follow the checklist in dependency order and update the plan as items are completed. Start with entitlement tracking and the independent protocol/persistence/CLI/release safety fixes. Treat Task 8, the physical DriverKit ownership spike, as a hard gate: do not implement the full remapper until the extension exclusively handles 1532:00B8 input, leaves a trackpad/second mouse unaffected, supports feature reports, and survives sleep/reconnect.

Use test-first changes and small commits. Preserve unrelated user work. Do not restore the global CGEvent mouse/scroll remapper as a fallback. Keep secrets, certificates, provisioning profiles, captured HID reports containing private data, and local machine paths out of Git. Run each task's targeted tests, then the complete verification and physical acceptance matrix. Report blockers immediately, especially entitlement, signing, DriverKit matching, duplicated input, or inability to release held outputs.
```
