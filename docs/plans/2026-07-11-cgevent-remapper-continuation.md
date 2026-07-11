# CGEvent Remapper Continuation Implementation Plan

> **For Claude/Cursor:** Use the repository's plan-execution workflow and implement this document task-by-task. Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` when available.

**Goal:** Continue improving button, wheel, DPI, profile, diagnostics, and reliability features using the existing macOS `CGEvent` remapper without requiring paid DriverKit signing.

**Architecture:** Keep hardware feature-report commands in `RazerCore` and software remapping in the session-level `CGEvent` tap. Treat global event scope as an explicit platform limitation: the tap cannot reliably identify which mouse produced an event. Keep the disabled DriverKit scaffold isolated for future work tracked by GitHub issue #2.

**Tech Stack:** Swift 5.9+, SwiftUI, CoreGraphics event taps, IOKit HID feature reports, XCTest, Swift Package Manager, XcodeGen.

---

## Current Codebase Facts

- `Sources/RazerCore/InputRemapper.swift` owns the session event tap, synthetic-event marker, button translation, scroll scaling, shortcuts, and emergency pause.
- `Sources/RazerCore/InputRemapperEngine.swift` contains pure remapping decisions and is covered by `Tests/RazerCoreTests/InputRemapperEngineTests.swift`.
- Button mappings and software/hardware wheel settings live in `Sources/RazerCore/ControlModels.swift`.
- `RazerMenuBarApp/AppModel.swift` coordinates permissions, profiles, capture, hardware commands, and remapper callbacks.
- `RazerMenuBarApp/SettingsView.swift` exposes Buttons, Wheel, and Diagnostics controls.
- Fractional scroll accumulation, synthetic-loop prevention, middle/wheel aliases, one-shot-on-down behavior, profile recovery, transactional probing, and response validation already have tests.
- A `CGEvent` tap is system/session scoped and cannot guarantee Razer-only remapping. Trackpads and other mice may be affected while remapping is enabled.
- DriverKit code remains scaffold-only and disabled in normal builds. It is not part of this plan.

## Decisions Made

- Continue with `CGEvent`; no paid Apple Developer Program dependency is required for this phase.
- Do not claim that remapping is Razer-only.
- Preserve Accessibility and Input Monitoring permission checks and the emergency pause shortcut.
- Keep all event-tap work memory-only and bounded; no synchronous file I/O, JSON encoding, URL launching, app launching, or hardware I/O on the callback path.
- Keep one-shot actions dispatched through callbacks and fire them only on button/key down.
- Prefer focused correctness and recovery work over new mapping types until held-button and tap-disable behavior is fully tested.
- Keep DriverKit as the future enhancement in GitHub issue #2.

## Non-Goals

- Exclusive ownership of the Razer device.
- Identifying the source mouse for each `CGEvent`.
- DriverKit activation, signing, entitlement approval, or notarized driver distribution.
- Macros, scripting, RGB, cloud sync, or support for additional mouse models.

## Definition Of Done

- Button down/up and drag sequences remain balanced for passthrough, disabled, swapped, and one-shot mappings.
- Pausing, stopping, profile replacement, permission loss, tap timeout, and app termination cannot leave synthetic buttons held.
- Vertical and Shift-horizontal scrolling preserve sign, precision, and independent fractional state.
- Invalid profile drafts cannot enter the running remapper.
- UI clearly reports active remapping, missing permissions, emergency pause, and global-scope limitation.
- Diagnostics can verify physical event type, button number, wheel axis, remap disposition, and tap recovery without file logging.
- Targeted tests and the complete Swift/Xcode verification pass.

## Implementation Steps

### Task 1: Record The Architecture Transition

**Files:**

- Modify: `README.md`
- Modify: `docs/plans/2026-07-10-razer-only-remapping-and-hardening.md`
- Modify: `docs/testing/driverkit-spike.md`
- Create: `docs/plans/2026-07-11-cgevent-remapper-continuation.md`

**Steps:**

- [x] Mark the DriverKit plan and physical matrix as deferred, not deleted.
- [x] Link GitHub issue #2 as the future enhancement.
- [x] Update README capability wording so software remapping is described as session-wide, while hardware DPI/polling/wheel commands remain device-specific.
- [x] Document Accessibility and Input Monitoring requirements and the emergency-pause recovery path.
- [x] Run `git diff --check`.
- [x] Commit: `docs: continue with CGEvent and defer DriverKit`.

### Task 2: Specify Stateful Button And Drag Semantics

**Files:**

- Modify: `Sources/RazerCore/InputRemapperEngine.swift`
- Modify: `Sources/RazerCore/InputRemapper.swift`
- Modify: `Tests/RazerCoreTests/InputRemapperEngineTests.swift`
- Create: `Tests/RazerCoreTests/InputRemapperStateTests.swift`

**Steps:**

- [x] Add failing sequence tests for left/right swap down-drag-up, many-to-one targets, mapping changes while a button is held, disabled controls, and one-shot actions.
- [x] Define a held-button record containing source control, disposition chosen on down, and synthetic target when applicable.
- [x] Resolve each source mapping once on down; use the stored disposition for drag/up even if the active profile changes.
- [x] Preserve source location, timestamp-independent click state where CoreGraphics allows it, and modifier flags on translated events.
- [x] Consume unmatched ups only when the corresponding down was consumed; otherwise pass them through.
- [x] Run `swift test --disable-sandbox --filter InputRemapper`.
- [x] Commit: `fix: make button remapping stateful across drag and profile changes`.

### Task 3: Release Held Outputs On Every Recovery Path

**Files:**

- Modify: `Sources/RazerCore/InputRemapper.swift`
- Modify: `Sources/RazerCore/InputRemapperEngine.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `Tests/RazerCoreTests/InputRemapperStateTests.swift`

**Steps:**

- [x] Add failing tests proving held synthetic targets are released on pause, stop, tap timeout/user-input disable, profile replacement, and permission loss.
- [x] Add one idempotent `releaseAllHeldOutputs()` path that snapshots and clears state before posting synthetic ups.
- [x] Invoke it before disabling/removing the tap and before replacing runtime mappings.
- [x] Re-enable timeout-disabled taps only after state cleanup and expose recovery state to `AppModel`.
- [x] Ensure repeated cleanup cannot post duplicate ups.
- [x] Run targeted remapper tests, then `swift test --disable-sandbox`.
- [x] Commit: `fix: release remapped inputs during every recovery path`.

### Task 4: Complete Wheel Precision And Action Semantics

**Files:**

- Modify: `Sources/RazerCore/InputRemapperEngine.swift`
- Modify: `Sources/RazerCore/InputRemapper.swift`
- Modify: `Sources/RazerCore/ControlModels.swift`
- Modify: `Tests/RazerCoreTests/InputRemapperEngineTests.swift`

**Steps:**

- [x] Add failing tests for positive/negative fractional accumulation, direction reversal, zero deltas, multiplier bounds, vertical events, and Shift-horizontal events.
- [x] Reset only the active axis accumulator when settings/profile identity changes; never transfer residual vertical motion to horizontal output.
- [x] Define whether one wheel gesture may fire one-shot actions repeatedly per event; retain the current per-event behavior unless tests expose duplicate callback dispatch.
- [x] Preserve all available line, point, and fixed-point axis fields consistently when passing scaled scroll events.
- [x] Validate finite speed multipliers at profile decoding, draft validation, and remapper update boundaries.
- [x] Run `swift test --disable-sandbox --filter InputRemapperEngineTests`.
- [x] Commit: `fix: harden wheel precision and axis isolation`.

### Task 5: Make Runtime Status And Limitations Explicit

**Files:**

- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `Sources/RazerCore/InputPermissions.swift`
- Test: `Tests/RazerCoreTests/ControlModelsTests.swift`

**Steps:**

- [x] Model remapper status as disabled, missing permission, active, paused, recovering, or failed.
- [x] Show one compact status row with the recovery action appropriate to that state.
- [x] State plainly near the enable control that software button/wheel mappings affect session mouse events, not only the connected Razer mouse.
- [x] Keep hardware-only DPI, polling, and supported wheel settings labeled separately from software remapping.
- [x] Keep the emergency shortcut visible and prevent enabling remapping while required permissions are absent.
- [x] Add focused model/validation tests for status transitions and permission combinations.
- [x] Run `swift test --disable-sandbox` and build the app.
- [x] Commit: `feat: expose remapper scope permissions and recovery state`.

### Task 6: Expand Memory-Only Diagnostics

**Files:**

- Modify: `Sources/RazerCore/InputCaptureSession.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Modify: `RazerMenuBarApp/SettingsView.swift`
- Modify: `Tests/RazerCoreTests/InputCaptureSessionTests.swift`

**Steps:**

- [x] Add bounded diagnostic entries for event type, button number, wheel axes, detected control, synthetic marker, and remap disposition.
- [x] Keep capture opt-in, memory-only, and capped; clearing capture must release retained entries immediately.
- [x] Exclude keyboard contents beyond key code/modifier data needed for explicit shortcut capture.
- [x] Add tests for cap eviction, clear callbacks, main-thread publication, and synthetic-event labeling.
- [x] Coalesce observer publication (dirty-flag + one outstanding main block; remapped ≠ synthetic; clear re-snapshots).
- [x] Verify capture remains responsive during fast scrolling and cannot write to disk.
- [x] Commit: `feat: improve bounded input diagnostics`.
- [x] Follow-up: `fix: coalesce diagnostics publication and clear races`.
- [x] Follow-up: `fix: publish diagnostics with one outstanding main block`.
- [x] Follow-up: remove per-event MainActor `Task` bridge for remapper diagnostics.
- [x] Follow-up: serialize sink record/clear/disable so in-flight records cannot survive clear.

### Task 7: Full Regression And Manual Acceptance

**Files:**

- Modify: `docs/testing/cgevent-remapper-acceptance.md`
- Modify as needed: `README.md`

**Steps:**

- [x] Create a manual matrix for normal click, hold, drag, swapped buttons, side buttons, wheel click, vertical scroll, Shift-horizontal scroll, slow multipliers, one-shot actions, pause, permission loss, and tap recovery.
- [x] Explicitly test with a trackpad and second mouse and record that session-wide remapping affects them; this is a known limitation, not a failed DriverKit criterion.
- [x] Run `swift test --disable-sandbox`.
- [x] Run `make xcode` if `project.yml` changed.
- [x] Run `xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build`.
- [x] Run `git diff --check` and inspect `git status --short` for generated or unrelated changes.
- [x] Commit: `test: document CGEvent remapper acceptance`.

## Cursor Handoff Prompt

```text
Implement docs/plans/2026-07-11-cgevent-remapper-continuation.md in dependency order using test-first changes and small commits.

DriverKit is deferred to GitHub issue #2 and must remain disabled in normal builds. Continue with the existing CGEvent event tap, acknowledge that it is session-wide, and do not claim Razer-only software remapping. Never perform file I/O, JSON work, hardware I/O, URL/app launching, or other blocking work on the event-tap callback. Preserve unrelated user changes. Run targeted tests after each task and full Swift/Xcode verification before completion.
```
