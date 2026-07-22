# Safety and Release Hardening Implementation Plan

> **Status (2026-07-22, rev 4): Tasks 1–9 documentation/automation work COMPLETE.** Code safety (Tasks 1–6): commits `f1cf780`/`3a02354`/`8213da2`/`fc0d660`/`d2f72df`/`3d734f9`. CI quarantine (Task 7): `48f97ff`. Credential-safe notarization (Task 8): `68ae22a`. Acceptance record + dependabot + SAF ledger (Task 9): `b913ded` — README now documents `NOTARY_KEYCHAIN_PROFILE` setup. Task 7/8 hardening sub-items (SHA-pinned actions, verified XcodeGen, test-build marker, `ci.yml` permissions/credentials, `spctl` assessment) complete at `fc76838`. Contracts verified green via `scripts/verify-release-contract.sh`.
> **Still OPEN:** physical-device rows (manual matrix below + 07-11/07-18 acceptance runs). SAF-001 stays **Mitigated pending Developer ID** — notarization/public release intentionally deferred (no Apple Developer Program membership yet).

> **For Claude:** Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` to implement this plan task-by-task.

**Goal:** Eliminate unintended persistent HID writes, require explicit session-wide remapper consent, validate privileged profile actions, keep event-tap work bounded, and prevent unnotarized builds from being presented as trusted public releases.

**Architecture:** Split saved profile state, session remapper arming, and hardware application into distinct flows. Move validation and scheduling policy into small testable `RazerCore` types, keep `AppModel` as the main-actor coordinator, and make failure paths disable or pause privileged behavior. Until Apple Developer membership exists, CI may build test artifacts with read-only permissions but must not publish them as recommended public releases.

**Tech Stack:** Swift 5.9, Swift Package Manager/XCTest, SwiftUI, AppKit, CoreGraphics, IOKit, Bash, GitHub Actions, and XcodeGen.

---

## Goal

Resolve SAF-001 through SAF-008 from `security_best_practices_report.md` without broad redesign or DriverKit expansion.

Success means:

- Software-only edits and profile-name typing perform zero HID writes.
- Explicit hardware applies are coalesced so stale queued snapshots never begin writing.
- New and legacy profiles default to remapping off.
- Remapping is never armed automatically after launch, upgrade, recovery, or permission restoration.
- Oversized, symlinked, structurally invalid, or semantically unsafe profile files fail closed.
- Open App/Open URL work runs after the event-tap callback returns.
- Repeated event-tap disables trip a circuit breaker and leave the remapper paused.
- Build jobs use read-only permissions, non-persisted credentials, immutable action pins, and verified XcodeGen bytes.
- Without Developer ID credentials, CI produces internal test artifacts only and creates no public release.
- Future notarization uses a Keychain profile or App Store Connect API key, never a password argument.

## Current codebase facts

- `AppModel.updateDraft` and `updateProfile` call `applySelectedProfile`, so names, buttons, and software-wheel edits enqueue full hardware writes.
- `DeviceSession.apply` writes DPI stages, active DPI, polling, and wheel settings unconditionally.
- `MouseProfile.remapperEnabled` defaults to `true`, including legacy decoding; `syncRemapper` starts when permissions become ready.
- Profiles are loaded with unbounded `Data(contentsOf:)`; load validation does not mirror save validation.
- `ButtonAction` includes executable shortcut, app, and URL actions loaded from JSON.
- `NSWorkspace` calls execute directly from the event callback.
- Tap-disable recovery re-enables immediately without rate limiting.
- The release workflow has workflow-wide `contents: write`, mutable action tags, and an unverified XcodeGen download.
- Public artifacts are ad-hoc signed and not notarized.
- The DriverKit target is a disabled passthrough spike and is out of scope.

## Decisions made

- Fix all eight findings in staged, reviewable commits.
- Do not wait for Apple Developer membership to improve safety.
- Until membership exists, stop publishing binaries as recommended public releases; retain short-lived CI test artifacts for maintainers.
- Keep keyboard shortcut, Open App, and Open URL actions, but validate them strictly.
- Default remapping off for new and legacy profiles.
- Require session-scoped arming after every app launch. TCC permission is necessary but is not consent.
- Preserve mappings during migration; only activation state changes.
- Apply hardware only for explicit Apply, profile selection, DPI/profile cycling, or reconnect auto-apply—not for ordinary editing.
- Coalesce queued applies before their first write; never interrupt a command set after writing begins.
- Keep local JSON. Defer Keychain/HMAC integrity until a stable Developer ID identity exists; compensate with session arming, strict validation, owner-only permissions, and regular-file checks.
- Do not add DriverKit scope.
- **Intentional deviation (Task 5):** dangling/invalid `selectedProfileID` is repaired to the first profile instead of quarantining an otherwise structurally valid file. Empty profile lists and other structural failures still fail closed/quarantine.

## Open questions

None blocking. When membership becomes available, create a follow-up for Team ID, certificate policy, protected release environment, and a clean-Mac notarization acceptance run.

## Implementation steps

### Task 1: Add testable hardware-change and latest-request policies

**Files:**

- Create: `Sources/RazerCore/HardwareApplyPolicy.swift`
- Create: `Tests/RazerCoreTests/HardwareApplyPolicyTests.swift`

Implement:

```swift
public struct HardwareProfileSettings: Equatable, Sendable {
    public let dpiStages: [Int]
    public let activeStage: Int
    public let pollingRateHz: Int
    public let wheel: HardwareWheelSettings

    public init(profile: MouseProfile) {
        dpiStages = profile.dpiStages
        activeStage = profile.activeStage
        pollingRateHz = profile.pollingRateHz
        wheel = profile.wheelSettings.hardware
    }
}

public final class LatestHardwareApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func issue() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }
}
```

- [x] Write tests proving name, mappings, software wheel, auto-reapply, and remapper-toggle changes leave `HardwareProfileSettings` equal.
- [x] Write tests proving DPI stages, active stage, polling, and hardware wheel change it.
- [x] Write concurrency tests proving only the latest issued token is current.
- [x] Run `swift test --disable-sandbox --filter HardwareApplyPolicyTests`; expect RED.
- [x] Implement the two types without AppKit.
- [x] Run the targeted tests; expect GREEN.
- [x] Commit: `test(core): define hardware apply policy`.

### Task 2: Stop editing from applying hardware and discard stale queued applies

**Files:**

- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`
- Test: `Tests/RazerCoreTests/HardwareApplyPolicyTests.swift`

Implementation requirements:

1. Add `private let hardwareApplyGate = LatestHardwareApplyGate()`.
2. Remove `applySelectedProfile()` from `updateProfile` and `updateDraft`. These paths persist, refresh warnings/summary, and `syncRemapper` only.
3. Introduce `HardwareApplyReason` with `.explicitApply`, `.profileSelection`, `.dpiCycle`, and `.reconnect`.
4. When scheduling, issue a gate token. On `hidQueue`, check `isCurrent` before connecting and again immediately before `session.apply`. Once `session.apply` starts, let it finish.
5. Invoke hardware apply only from Apply Profile, `selectProfile`, `advanceDPIStage`, and reconnect auto-apply.
6. Track `HardwareProfileSettings` last applied successfully and show `Hardware changes pending` when the selected profile differs.
7. Button/software-wheel edits still update the live remapper immediately.

- [x] Add policy tests first and confirm RED.
- [x] Implement routing changes.
- [x] Run `rg -n "applySelectedProfile" RazerMenuBarApp` and account for every call.
- [x] Build the app.
- [ ] Manually type a name and drag software speed; verify no hardware apply status occurs. *(manual — physical)*
- [x] Commit: `fix(app): separate profile edits from hardware apply`.

### Task 3: Skip unchanged persistent hardware writes

**Files:**

- Create: `Sources/RazerCore/HardwareProfileApplier.swift`
- Create: `Tests/RazerCoreTests/HardwareProfileApplierTests.swift`
- Modify: `Sources/RazerCore/ProfileStore.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`

Create a pure planner:

```swift
public struct HardwareApplyPlan: Equatable, Sendable {
    public var setDPIStages = false
    public var setDPI = false
    public var setPolling = false
    public var setScrollMode = false
    public var setAcceleration = false
    public var setSmartReel = false
}
```

`HardwareProfileApplier.plan(current:target:wheelCurrent:capability:)` must set flags only for differing requested values. Unknown/not-supported wheel fields must never be mutated.

Refactor `DeviceSession.apply` to read current state once, read requested/supported wheel state, build the plan, and execute deterministic writes. If all fields match, make zero setter calls. Do not add rollback: this applies intended durable state, unlike temporary CLI diagnostics.

- [x] Write one failing test per flag and capability case.
- [x] Add a fake mutator test proving an equal profile performs zero writes.
- [x] Run `swift test --disable-sandbox --filter HardwareProfileApplierTests`; expect RED.
- [x] Implement planner and integration.
- [x] Run targeted tests and `HardwareStateTransactionTests`.
- [x] Commit: `fix(hid): skip unchanged persistent settings`.

### Task 4: Make remapping default-off and session-armed

**Files:**

- Modify: `Sources/RazerCore/ProfileStore.swift`
- Modify: `Sources/RazerCore/PermissionStatus.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `RazerMenuBarApp/RazerMenuBarApp.swift`
- Modify: `Tests/RazerCoreTests/ProfileSchemaTests.swift`
- Modify: `Tests/RazerCoreTests/MouseProfileMigrationTests.swift`
- Modify: `Tests/RazerCoreTests/ControlModelsTests.swift`

Required behavior:

- Initializer, missing-field decoder, and reset default `remapperEnabled` to `false`.
- Add session-only `@Published var remapperArmed = false`; never persist it.
- `syncRemapper` requires profile preference, session arm, and permissions.
- Permission restoration never arms.
- Enabling shows: `Software remapping affects every mouse and trackpad in this login session.`
- Confirmation enables the profile preference and arms this process only.
- Add `.awaitingConsent` runtime status/recovery action.
- Relaunch resets arming while preserving mappings.
- Pause/resume cannot bypass arming.

- [x] Update schema/migration/status tests first; confirm RED.
- [x] Implement model and resolver changes.
- [x] Add SwiftUI confirmation and `Arm Remapper` action.
- [x] Verify first run, legacy missing field, relaunch, and permission restoration stay inactive.
- [x] Commit: `fix(remapper): require explicit session arming`.

### Task 5: Bound and semantically validate profile storage

**Files:**

- Create: `Sources/RazerCore/ProfileSafetyValidator.swift`
- Create: `Tests/RazerCoreTests/ProfileSafetyValidatorTests.swift`
- Modify: `Sources/RazerCore/ProfileStore.swift`
- Modify: `Tests/RazerCoreTests/ProfileStoreRecoveryTests.swift`
- Modify: `Tests/RazerCoreTests/ControlModelsTests.swift`

Use these limits:

```swift
public enum ProfileSafetyLimits {
    public static let maximumFileBytes = 1_048_576
    public static let maximumProfiles = 50
    public static let maximumProfileNameUTF8Bytes = 256
    public static let maximumURLUTF8Bytes = 2_048
    public static let maximumAppPathUTF8Bytes = 4_096
    public static let allowedShortcutModifierMask: UInt64 = 0x001E_0000
    public static let maximumVirtualKeyCode: UInt16 = 127
}
```

Validation rules:

- Before reading, require a regular non-symlink file owned by the current UID and at most 1 MiB.
- Create the support directory with POSIX `0700`; enforce `0600` after atomic save.
- Require 1...50 profiles, unique UUIDs, valid selection, bounded nonblank names, and valid hardware/wheel values.
- Shortcut modifiers must be within the mask and key codes 0...127.
- URL actions must pass existing HTTP(S)+host validation and size limits.
- App paths must be absolute, standardized, end in `.app`, be within size limits, and resolve to an application directory. Missing/moved apps become `.disabled` with a repair warning rather than quarantining an otherwise valid file.
- Structural, ownership, symlink, size, or hardware failure uses quarantine/default recovery with remapping off.
- Never follow a symlink during quarantine. If safe quarantine fails, preserve it, block writes, and use in-memory defaults with remapping off.
- Load and save must call the same semantic validator.

- [x] Add tests for every limit, duplicate IDs, invalid selection, shortcuts, URLs, app paths, symlinks, ownership, size, and POSIX modes.
- [x] Confirm RED.
- [x] Implement validator and store integration.
- [x] Run all profile schema/migration/recovery tests.
- [x] Commit: `fix(profiles): validate privileged configuration`.

### Task 6: Defer workspace actions and circuit-break repeated tap disables

**Files:**

- Create: `Sources/RazerCore/TapDisableCircuitBreaker.swift`
- Create: `Tests/RazerCoreTests/TapDisableCircuitBreakerTests.swift`
- Modify: `Sources/RazerCore/InputRemapper.swift`
- Modify: `Sources/RazerCore/PermissionStatus.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `Tests/RazerCoreTests/InputRemapperRecoveryTests.swift`

Circuit policy: the first two disables within 10 seconds may recover; the third opens the circuit, releases held outputs, disables the tap, pauses, and requires explicit re-arm. A quiet 10-second window resets the count. Use injected monotonic timestamps in the pure state type.

For Open App/Open URL, validate and copy the URL in the callback, then `DispatchQueue.main.async` the `NSWorkspace` call. The callback returns immediately. Keyboard and synthetic mouse output stays synchronous.

- [x] Write deterministic breaker tests.
- [x] Add recovery coverage proving the third rapid disable releases holds and does not re-enable.
- [x] Add a test seam proving workspace execution is deferred.
- [x] Implement under the existing remapper lock.
- [x] Add status: `Remapper paused after repeated event-tap timeouts.`
- [x] Run engine/state/recovery tests.
- [x] Commit: `fix(remapper): bound event tap recovery`.

### Task 7: Replace public ad-hoc releases with read-only test artifacts

**Files:**

- Modify: `.github/workflows/ci.yml`
- Replace or rename: `.github/workflows/release.yml`
- Modify: `scripts/verify-release-contract.sh`
- Modify: `README.md`
- Create: `.github/dependabot.yml`

No-membership policy:

1. Remove tag-triggered public GitHub Release publication.
2. Keep a manual test-package workflow with `permissions: contents: read`.
3. Checkout with `persist-credentials: false`.
4. Upload short-retention artifacts named `UNNOTARIZED-TEST-BUILD`; never push tags or create releases.
5. Include `UNNOTARIZED_TEST_BUILD.txt` in archives/DMG.
6. Pin every action to a reviewed full commit SHA with a version comment.
7. Add weekly Dependabot updates for `github-actions`.
8. Pin XcodeGen URL and SHA-256, verify before unzip, and execute from a job-local directory without `sudo`.
9. Reserve `contents: write` for a future separate, environment-protected publisher job.

Extend release contracts to reject mutable action tags, write permission in build jobs, persisted checkout credentials, unverified XcodeGen extraction, and any no-membership `action-gh-release`, `git push`, or `contents: write`.

Resolve exact official action SHAs and XcodeGen digest during implementation; commit reviewed exact values, never placeholders.

- [x] Add failing temporary-fixture shell contract cases. *(5 quarantine contracts in `verify-release-contract.sh`)*
- [x] Confirm `bash scripts/verify-release-contract.sh` is RED.
- [x] Harden workflows and tool installation. *(done at `fc76838`: SHA-pinned actions, XcodeGen SHA-256 verification, `UNNOTARIZED_TEST_BUILD.txt` marker; permissions/credentials/publisher already done)*
- [x] Run contract checks and ShellCheck.
- [x] Audit with `rg -n "permissions:|contents:|persist-credentials|uses:" .github/workflows`. *(note: `ci.yml` now hardened — top-level `permissions: contents: read` + `persist-credentials: false` on checkouts at `fc76838`)*
- [x] Commit: `ci: quarantine unnotarized test artifacts`. *(`48f97ff`)*

### Task 8: Make future notarization credential-safe

**Files:**

- Modify: `scripts/sign-release.sh`
- Modify: `scripts/verify-release-contract.sh`
- Modify: `README.md`

- Replace `APPLE_ID`/`APPLE_APP_PASSWORD` use with local `NOTARY_KEYCHAIN_PROFILE`, or later protected App Store Connect API-key secrets.
- Any command called an official release must require notarization. Signed-but-not-notarized output is a test artifact only.
- After stapling run:

```bash
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
```

- Add contracts rejecting `notarytool ... --password` and requiring `spctl`/stapler verification.
- Without credentials, exit before mutating release artifacts and print setup guidance.

- [x] Write failing contract assertions. *(4 credential/spctl contracts in `verify-release-contract.sh`; spctl/stapler-verification contract added at `fc76838`)*
- [x] Implement Keychain-profile/API-key handling. *(`NOTARY_KEYCHAIN_PROFILE` + `--keychain-profile`; `spctl --assess` post-staple step at `fc76838`; README credential docs done)*
- [x] Run Bash syntax and ShellCheck.
- [x] Verify safe early exit without credentials.
- [x] Commit: `build: secure future notarization credentials`. *(`68ae22a`)*

### Task 9: Document and verify the complete hardening

**Files:**

- Modify: `README.md`
- Modify: `docs/testing/cgevent-remapper-acceptance.md`
- Modify: `security_best_practices_report.md`
- Create: `docs/testing/safety-hardening-acceptance.md`

Document default-off/session arming, permission-versus-consent, hardware mutation triggers, repeated-timeout pause, invalid-profile behavior, paused public binary releases, and test-artifact limitations.

Mark each SAF item `Resolved`, `Mitigated pending Developer ID`, or `Deferred`, with verification evidence. SAF-001 stays `Mitigated pending Developer ID` until a notarized public artifact passes `spctl` on a clean Mac.

- [x] Run the full automated commands below. *(`verify-release-contract.sh` + `test-*.sh` green at `b913ded`)*
- [ ] Run the manual matrix with a backup input device. *(manual — physical)*
- [x] Verify no public release/tag is created. *(`release.yml` has no publisher — contract-enforced)*
- [x] Commit: `docs: record safety hardening acceptance`. *(`b913ded`)*

## Files expected to change

```text
.github/dependabot.yml
.github/workflows/ci.yml
.github/workflows/release.yml
README.md
RazerMenuBarApp/AppModel.swift
RazerMenuBarApp/RazerMenuBarApp.swift
RazerMenuBarApp/SettingsView.swift
Sources/RazerCore/HardwareApplyPolicy.swift
Sources/RazerCore/HardwareProfileApplier.swift
Sources/RazerCore/InputRemapper.swift
Sources/RazerCore/PermissionStatus.swift
Sources/RazerCore/ProfileSafetyValidator.swift
Sources/RazerCore/ProfileStore.swift
Sources/RazerCore/TapDisableCircuitBreaker.swift
Tests/RazerCoreTests/ControlModelsTests.swift
Tests/RazerCoreTests/HardwareApplyPolicyTests.swift
Tests/RazerCoreTests/HardwareProfileApplierTests.swift
Tests/RazerCoreTests/InputRemapperRecoveryTests.swift
Tests/RazerCoreTests/MouseProfileMigrationTests.swift
Tests/RazerCoreTests/ProfileSafetyValidatorTests.swift
Tests/RazerCoreTests/ProfileSchemaTests.swift
Tests/RazerCoreTests/ProfileStoreRecoveryTests.swift
Tests/RazerCoreTests/TapDisableCircuitBreakerTests.swift
docs/testing/cgevent-remapper-acceptance.md
docs/testing/safety-hardening-acceptance.md
scripts/sign-release.sh
scripts/verify-release-contract.sh
security_best_practices_report.md
```

`project.yml` should not need changes because new files are under existing source/test directories. If an app XCTest target becomes necessary, update `project.yml`, run `make xcode`, and document why pure-core tests were insufficient.

## Tests and verification commands

```bash
swift test --disable-sandbox --filter HardwareApplyPolicyTests
swift test --disable-sandbox --filter HardwareProfileApplierTests
swift test --disable-sandbox --filter ProfileSafetyValidatorTests
swift test --disable-sandbox --filter ProfileStoreRecoveryTests
swift test --disable-sandbox --filter TapDisableCircuitBreakerTests
swift test --disable-sandbox --filter InputRemapperRecoveryTests
swift test --disable-sandbox
bash -n scripts/*.sh
bash scripts/verify-release-contract.sh
shellcheck -x scripts/*.sh
xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build
```

Manual acceptance:

```text
1. Launch with permissions granted: remapper remains unarmed.
2. Confirm the session-wide warning: remapper becomes active.
3. Relaunch: remapper is unarmed and mappings remain stored.
4. Type a profile name and drag software speed: no HID apply occurs.
5. Apply Profile: only changed hardware fields are written.
6. Queue applies rapidly: only the newest not-yet-started snapshot executes.
7. Simulate three tap disables in ten seconds: held outputs release and remapper pauses.
8. Load oversized/symlink/invalid-action profiles: remapping stays off and source is preserved/quarantined.
9. Run test packaging: no tag or GitHub Release is created.
```

## Safety and rollback notes

- Use a backup pointing device for physical remapper/hardware tests.
- Coalesce before the first HID write only; never interrupt a partially applied command set.
- Preserve mappings and quarantine artifacts during migration.
- If session arming regresses, fail closed and keep the remapper inactive.
- If profile permissions cannot be repaired, preserve the file, block writes, load safe in-memory defaults, and keep remapping off.
- Do not restore public binary publication to work around missing Developer ID credentials.

## Cursor handoff prompt

```text
Implement docs/plans/2026-07-12-safety-release-hardening.md task-by-task using strict TDD.

Read AGENTS.md and security_best_practices_report.md first. Preserve unrelated changes and the existing corrupt-profile quarantine guarantees. Start with Task 1 and stop after each task for review. Run each targeted RED/GREEN test, then the broader task verification. Keep event-tap callbacks free of synchronous file and LaunchServices work. Never test destructive hardware behavior without a backup input device. Do not publish, tag, push, or create a GitHub Release: the user has no Apple Developer membership, so public binary releases remain disabled. Do not expand DriverKit scope.

Resolve current official immutable action SHAs and the XcodeGen checksum during implementation; review and commit exact values, never placeholders. After each task, summarize changed behavior, tests, and deviations before continuing.
```
