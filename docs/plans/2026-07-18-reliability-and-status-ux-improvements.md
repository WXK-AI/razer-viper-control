# Reliability and Status UX Improvements Implementation Plan

> **Status (2026-07-23): FULLY COMPLETE.** All 19 tasks are implemented and verified in code (commits `8c13fa3`..`1cebd98`). Phase 5 Task 19 **physical acceptance run** is COMPLETE (2026-07-23, operator xk — R1/R2/R4/R5 Pass; R3/R6 Skip with reasons; signed off in `docs/testing/reliability-acceptance.md`).

> **For Claude/Cursor:** Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` to implement this plan task-by-task.

**Goal:** Make DPI/profile apply and reconnect provably reliable, close the highest-risk remapper edge cases, and make the menu bar tell the truth about device, remapper, and persistence state.

**Architecture:** Keep the existing layering (RazerCore logic, `AppModel` as main-actor coordinator, tap callback on the main run loop). Introduce an injectable HID transport seam so `RazerCommandClient` becomes unit-testable, move reconnect from poll-only to event-driven (IOHIDManager removal callbacks + sleep/wake observers), and add post-apply readback verification. Remapper fixes stay inside `InputRemapper`/`InputRemapperEngine`. UX fixes stay in `AppModel` + views with a small testable status-mapping type.

**Tech Stack:** Swift 5.9, SwiftPM/XCTest, SwiftUI, AppKit, IOKit.hid, CoreGraphics, XcodeGen.

---

## Baseline (verified 2026-07-18)

- `swift test` — **233/233 pass** in `~/Developer/razer-viper-control`.
- `xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build` — **BUILD SUCCEEDED**.
- Note: `~/Documents/razer project` is a stale v1 copy (9 tests, no remapper, no git history). All work happens in `~/Developer/razer-viper-control`.

## Guardrails

- **Non-goals:** DriverKit, notarization/signing/release work, Razer Synapse feature parity (RGB, macros, onboard memory), per-device (Razer-only) remapper filtering.
- **Stop-and-ask gate:** No task below changes the 90-byte report codec, transaction ID scheme, or command classes. If implementation reveals a need for multi-packet reassembly, transaction-ID rotation, or new command classes, **STOP and ask before writing that code**. Bounded transport-timing changes (Task 2) are explicitly allowed.
- Preserve existing behavior contracts: session-only remapper arming, fail-closed permission handling, coalesced hardware applies via `LatestHardwareApplyGate`.

## Current codebase facts

From the 2026-07-18 audit (file:line references are pre-plan):

**HID / reconnect**
- Commands run on a serial utility queue; each round trip is `IOHIDDeviceSetReport` → fixed 60 ms `usleep` → `IOHIDDeviceGetReport` with a 5× BUSY-only retry (`Sources/RazerCore/RazerCommandClient.swift:299–330`, `DeviceDescriptor.swift:12`).
- `DeviceSession` caches the `IOHIDDevice` indefinitely; reconnect detection is only the 5 s poll in `AppModel.startMonitoring` (`ProfileStore.swift:580–598`, `AppModel.swift:257–265`). No IOHIDManager removal callbacks, no sleep/wake observers.
- `RazerCommandError.shouldInvalidateSession` excludes `.deviceBusy`; a wedged device can loop forever without a session reset (`RazerCommandClient.swift:47–53`). Explicit apply failures never invalidate the session (`AppModel.swift:555–565`).
- `HIDDeviceDiscovery.findControlDevice` returns `candidates.first` from an unordered `Set` — nondeterministic when dongle + BT interfaces coexist (`HIDDeviceDiscovery.swift:71–78`).
- No post-apply readback: `HardwareProfileApplier.execute` counts writes but never re-reads device state; partial failures are undetected (`HardwareProfileApplier.swift:150–174`). The CLI's `HardwareStateTransaction.runIntegration` is the only verified-write path.
- `decodePollingRateHz() ?? 1000` masks unknown polling values, so the diff planner may skip a needed apply (`RazerCommandClient.swift:149`).
- Stage comparison drops the Y axis (`RazerCommandClient.swift:139–148`, `HardwareProfileApplier.swift:78`).
- `LatestHardwareApplyGate` is checked once before `execute`; a superseded apply still performs all remaining writes (`HardwareProfileApplier.swift:143–147`).
- `HardwareApplyReason` is accepted and ignored (`AppModel.swift:523–524`).
- Zero tests for `RazerCommandClient` transport, `DeviceSession`, `HIDDeviceDiscovery`, or `AppModel` reconnect flows. A `RazerReportTransport` protocol exists but is unused (`RazerResponseValidator.swift:4–6`).

**Remapper**
- Session-wide CGEvent tap; hold recovery, circuit breaker (3 disables/10 s), session arming, and deferred workspace actions are solid and well-tested (63 remapper-related tests).
- Scroll path only reads axis 1; axis-2-only (native horizontal) deltas bypass remap/scaling entirely (`InputRemapper.swift:589–594`).
- Scroll→button/one-shot actions fire per scroll tick — momentum scrolling produces click storms (`InputRemapper.swift:655–673`).
- TOCTOU: `paused`/`currentProfile` snapshotted then used without re-lock on the scroll path (`InputRemapper.swift:420–424, 477–481`); button-down path re-checks under lock (`459–463`).
- `isRunning` read outside lock in `start()` (`InputRemapper.swift:153`); `callbacks` is a `public var` mutated without synchronization (`AppModel.swift:833–883`); `InputCaptureSession` callback reads `eventTap` unlocked while `stop()` nils it (`InputCaptureSession.swift:164–173, 221–225`).
- `setRemapperPaused(false)` sets UI unpaused before `resume()`, which silently no-ops when the circuit is open (`AppModel.swift:669–676`, `InputRemapper.swift:128–134`).
- Recovery releases only synthetic **mouse** holds; keyboard shortcut posting has no stuck-modifier recovery (`InputRemapper.swift:370–372, 535–537`).
- No integration tests drive `handleEvent`/`handleScrollEvent` with real `CGEvent`s.

**Profiles**
- Hardened FD-based store with quarantine recovery and atomic writes — good. But: no `schemaVersion` field (`ProfileStore.swift:43–55`); successful quarantine silently replaces user data with defaults and there is no in-app restore (`ProfileStore.swift:492–506`); `load()` discards outcome metadata (`ProfileStore.swift:315–317`); `ProfileStore` has no concurrency guard (`ProfileStore.swift:172–564`).

**Menu-bar UX**
- Icon shows filled/outline mouse + battery %; no charging, low-battery, or error affordance (`RazerMenuBarApp.swift:24–29`).
- Circuit-breaker pause and manual pause share the title "Remapper paused" (`PermissionStatus.swift:57–58, 63–64`); menu shows title only, and Pause/Resume is disabled while circuit-open (`RazerMenuBarApp.swift:57–66`).
- Raw `RazerCommandError.localizedDescription` strings appear in the menu (`AppModel.swift:476–477, 557`; `RazerMenuBarApp.swift:54`).
- Persistence/corruption and permission warnings appear only in Settings, never in the menu (`SettingsView.swift:104–140`).
- `batteryPercent` is not reset on disconnect (`AppModel.swift:471–483`); no reconnect feedback beyond "Connected".

## Decisions made

- Rank by user-facing risk: silent hardware misconfiguration and stale-connection wedges (Phase 1) > input-corruption edge cases (Phase 2) > status honesty (Phase 3) > storage robustness (Phase 4) > deeper test/acceptance depth (Phase 5).
- Testability first: Phase 1 starts by wiring the existing (unused) `RazerReportTransport` protocol into `RazerCommandClient` so every later reliability change lands with unit tests. This is dependency injection, not a protocol rewrite.
- Event-driven reconnect supplements — does not replace — the 5 s poll. The poll remains the battery/status heartbeat.
- Readback verification reports and retries once; it does **not** attempt rollback (rollback re-writes hardware and can double the damage; report + reapply is safer).
- Remapper device filtering stays out of scope (documented non-goal since the 2026-07-11 plan); axis-2 scroll and momentum debounce are in scope because they corrupt input *today* for any user with a trackpad or free-spin wheel.
- Keep quarantine fail-closed semantics; add discoverability (reveal + guided restore attempt), not automatic merging.

## Open questions

None blocking. Two items require a human decision if they arise mid-implementation (see stop-and-ask gate): multi-packet response reassembly and transaction-ID changes. Physical-device acceptance (Phase 5, Task 19) needs the actual mouse present.

---

## Phase 1 — HID transport correctness and reconnect (P0)

### Task 1: Wire `RazerReportTransport` into `RazerCommandClient`

**Files:**
- Modify: `Sources/RazerCore/RazerCommandClient.swift`
- Modify: `Sources/RazerCore/RazerResponseValidator.swift` (protocol already declared here; move it beside the client if cleaner)
- Create: `Tests/RazerCoreTests/RazerCommandClientTransportTests.swift`

**Step 1: Write failing tests** for `send(_:)` against a fake transport:

```swift
final class FakeTransport: RazerReportTransport {
    var setResults: [IOReturn] = []
    var getResponses: [Result<[UInt8], RazerCommandError>] = []
    private(set) var setCount = 0
    private(set) var getCount = 0
    var sleeps: [UInt64] = []
    // record every call; pop scripted results
}

func testBusyResponsesRetryThenSucceed() { /* 2× busy status then success → 3 set calls, returns report */ }
func testBusyExhaustionThrowsDeviceBusy() { /* 5× busy → throws .deviceBusy, exactly maxCommandRetries sets */ }
func testTransportSetFailureDoesNotRetry() { /* kIOReturnNotPermitted on set → .permissionDenied, 1 set call */ }
func testCRCMismatchThrowsInvalidResponse() { }
func testSleepDurationUsesDescriptorDefault() { /* recorded sleep == responseWaitMilliseconds */ }
```

**Step 2: Run** `swift test --filter RazerCommandClientTransportTests` — expect FAIL (client has no transport init).

**Step 3: Implement.** Add `init(transport: RazerReportTransport)` alongside the existing `init(device:)` (which constructs the default IOHID-backed transport). Move the `IOHIDDeviceSetReport`/`usleep`/`IOHIDDeviceGetReport` body into a `IOHIDReportTransport` struct conforming to the protocol. `performRoundTrip` calls only the protocol. No behavior change for production callers.

**Step 4: Run** the filter, then full `swift test` — expect all pass (233 + new).

**Step 5: Commit** `refactor(hid): inject report transport into command client`.

### Task 2: Replace fixed 60 ms sleep with a bounded response poll

**Files:**
- Modify: `Sources/RazerCore/RazerCommandClient.swift`, `Sources/RazerCore/DeviceDescriptor.swift`
- Test: `Tests/RazerCoreTests/RazerCommandClientTransportTests.swift`

**Step 1: Failing tests:** fake transport returns status `newCommand` (0x00, device not ready) for the first 2 GETs then `successful`; assert client polls GET again (short interval) instead of throwing, and that total wait never exceeds a deadline (`responseDeadlineMilliseconds = 200`, initial wait 15 ms, poll every 15 ms). Assert existing "blocked access" detection still triggers when the deadline expires with echoed status 0x00.

**Step 2: Run — FAIL. Step 3: Implement** the poll loop inside the round trip (this is timing only; report bytes are untouched). Keep `responseWaitMilliseconds` as the initial wait; add `responsePollIntervalMilliseconds` and `responseDeadlineMilliseconds` to `DeviceDescriptor`.

**Step 4: Full `swift test`. Step 5: Commit** `fix(hid): poll for command response instead of fixed sleep`.

### Task 3: BUSY exhaustion and explicit-apply failures invalidate the session

**Files:**
- Modify: `Sources/RazerCore/RazerCommandClient.swift` (`shouldInvalidateSession`), `RazerMenuBarApp/AppModel.swift` (`applySelectedProfile` catch path)
- Test: `Tests/RazerCoreTests/RazerResponseValidatorTests.swift` (extend), new assertions in `HardwareApplyPolicyTests.swift`

**Step 1: Failing tests:** `.deviceBusy.shouldInvalidateSession == true`; apply-failure path calls `session.disconnect()` (test via a seam: extract the decision into a pure `HardwareApplyFailurePolicy.shouldInvalidate(error:)` in `HardwareApplyPolicy.swift` and unit-test that — `AppModel` just calls it).

**Step 2–4: Red → implement → green** (`swift test`). **Step 5: Commit** `fix(hid): invalidate session on busy exhaustion and apply failure`.

### Task 4: Deterministic control-interface selection

**Files:**
- Modify: `Sources/RazerCore/HIDDeviceDiscovery.swift`
- Create: `Tests/RazerCoreTests/HIDInterfaceSelectionTests.swift`

**Step 1: Failing test** against a pure selection function: given `[DiscoveredHIDInterface]`, prefer (a) USB/dongle transport over Bluetooth, (b) then lowest `locationID`, so repeat discovery is stable. Extract `selectControlInterface(from:) -> DiscoveredHIDInterface?` so it is testable without IOKit.

**Step 2–4: Red → implement → green. Step 5: Commit** `fix(hid): deterministic control interface selection`.

### Task 5: Event-driven disconnect detection (removal callbacks + sleep/wake)

**Files:**
- Modify: `Sources/RazerCore/ProfileStore.swift` (`DeviceSession`) or extract `DeviceSession` to its own file `Sources/RazerCore/DeviceSession.swift`
- Modify: `RazerMenuBarApp/AppModel.swift`
- Create: `Tests/RazerCoreTests/DeviceSessionTests.swift`

**Step 1: Failing tests** for the logic seam: `DeviceSession` gains an `onDeviceRemoved: (() -> Void)?` hook and an `invalidate()` that drops the cached client. Tests: cached client is reused; `invalidate()` forces re-discovery on next `connect()`; removal hook fires `invalidate()`. (IOHIDManager wiring itself is thin and covered by manual acceptance.)

**Step 2–4: Red → implement → green.** Implementation: keep a long-lived `IOHIDManager` in `DeviceSession` with matching + `IOHIDManagerRegisterDeviceRemovalCallback` scheduled on the main run loop; on removal of the cached device, call `invalidate()` and notify. In `AppModel.init`, subscribe to `NSWorkspace.shared.notificationCenter` `willSleepNotification`/`didWakeNotification`: on sleep `session.invalidate()`, on wake trigger `refreshDeviceState()` after a 2 s delay. Menu status flips to "Disconnected" immediately on removal instead of waiting ≤5 s.

**Step 5: Commit** `fix(hid): event-driven device removal and sleep/wake reconnect`.

### Task 6: Post-apply readback verification + fail-closed polling decode

**Files:**
- Modify: `Sources/RazerCore/HardwareProfileApplier.swift`, `Sources/RazerCore/RazerCommandClient.swift`
- Test: `Tests/RazerCoreTests/HardwareProfileApplierTests.swift`

**Step 1: Failing tests:**
- `decodePollingRateHz` unknown byte → planner treats polling as "unknown" and always applies (never silently equal to 1000). Change `DeviceState.pollingRateHz` to `Int?` at the read site or add `pollingKnown` flag — pick the smaller diff.
- After `execute`, applier re-reads state via the injected reader and returns `HardwareApplyResult` with `verified: Bool` and `mismatches: [String]`; a mismatch triggers exactly one automatic reapply of the mismatched fields, then reports.
- Stage comparison covers X and Y (`stages.map { ($0.x, $0.y) }`).

**Step 2–4: Red → implement → green.** `AppModel` surfaces `verified == false` as a warning ("Profile applied but device readback differs — reapplied/check device").

**Step 5: Commit** `fix(hid): verify applies with readback and fail-closed polling decode`.

### Task 7: Re-check apply gate between write steps

**Files:**
- Modify: `Sources/RazerCore/HardwareProfileApplier.swift` (+ `HardwareApplyPolicy.swift` if the gate needs an `isCurrent(_:)` accessor)
- Test: `Tests/RazerCoreTests/HardwareProfileApplierTests.swift`

**Step 1: Failing test:** supersede the gate after the first mutator call; assert remaining mutators are skipped and result reports `superseded`. Never abort mid-command — only between commands (preserves the 2026-07-12 plan's invariant).

**Step 2–4: Red → implement → green. Step 5: Commit** `fix(hid): abort superseded applies between writes`.

---

## Phase 2 — Remapper edge cases

### Task 8: Handle axis-2 scroll deltas

**Files:**
- Modify: `Sources/RazerCore/InputRemapper.swift` (`handleScrollEvent`)
- Create: `Tests/RazerCoreTests/InputRemapperScrollTests.swift` (drive `handleScrollEvent` with constructed `CGEvent`s — these can be created headlessly with `CGEvent(scrollWheelEvent2Source:...)`; if CI lacks a window server, guard with the same opportunistic pattern used in `InputRemapperRecoveryTests.swift:277–306`)

**Step 1: Failing tests:** axis-2-only event passes through the horizontal scaler (multiplier applied); dual-axis event scales both axes; axis-1 behavior unchanged; wheelUp/wheelDown action resolution still keys off axis 1 only.

**Step 2–4: Red → implement → green. Step 5: Commit** `fix(remapper): scale and pass through axis-2 scroll deltas`.

### Task 9: Debounce scroll-triggered button/one-shot actions

**Files:**
- Modify: `Sources/RazerCore/InputRemapperEngine.swift` (add pure `ScrollActionThrottle`: min-interval, default 60 ms, monotonic-clock injected), `Sources/RazerCore/InputRemapper.swift` (use it in `executeScrollAction`)
- Test: `Tests/RazerCoreTests/InputRemapperEngineTests.swift`

**Step 1: Failing tests:** 10 ticks in 20 ms fire the action once; ticks ≥60 ms apart each fire; direction change resets the window; passthrough scroll is unaffected.

**Step 2–4: Red → implement → green. Step 5: Commit** `fix(remapper): throttle scroll-mapped actions under momentum`.

### Task 10: Close locking races in remapper and capture session

**Files:**
- Modify: `Sources/RazerCore/InputRemapper.swift`, `Sources/RazerCore/InputCaptureSession.swift`, `RazerMenuBarApp/AppModel.swift`
- Test: extend `Tests/RazerCoreTests/InputRemapperRecoveryTests.swift`, `InputCaptureSessionTests.swift`

**Changes (each red → green → commit separately if practical):**
1. Scroll path re-checks `isPaused` under lock before consuming/posting (mirror the button-down pattern at `InputRemapper.swift:459–463`).
2. `start()` checks `isRunning` under lock.
3. `callbacks` becomes set-once: `private(set) var` + `func setCallbacks(_:)` that asserts not running, or move into `init`. Update `AppModel.configureRemapperCallbacks`.
4. `InputCaptureSession`: guard `eventTap`/`isRunning` with its lock in the callback and `stop()`.

**Commit** `fix(remapper): close pause/start/callback locking races`.

### Task 11: Resume vs circuit-open consistency

**Files:**
- Modify: `RazerMenuBarApp/AppModel.swift` (`setRemapperPaused`), `Sources/RazerCore/InputRemapper.swift` (`resume()` returns `Bool`)
- Test: `Tests/RazerCoreTests/InputRemapperRecoveryTests.swift`, `ControlModelsTests.swift`

**Step 1: Failing test:** `resume()` returns `false` while circuit open; UI paused flag must remain `true` in that case (test via extracted pure decision or by asserting on the remapper's `isPaused` after the call sequence).

**Step 2–4: Red → implement → green. Step 5: Commit** `fix(remapper): keep UI paused when resume is blocked by open circuit`.

### Task 12: Keyboard shortcut posting safety

**Files:**
- Modify: `Sources/RazerCore/InputRemapper.swift` (`postKeyboardShortcut`)
- Test: `Tests/RazerCoreTests/InputRemapperScrollTests.swift` or new `InputRemapperShortcutTests.swift`

Shortcuts are already instantaneous down+up (`InputRemapper.swift:535–537`); the residual risk is ordering and flags. **Step 1: Failing tests** via an injected event-posting seam (same pattern as recovery tests): key-down posts before key-up; both carry the same flags; flags are cleared on the up event; posting is skipped entirely while paused. **Step 2–4: Red → implement → green. Step 5: Commit** `fix(remapper): harden shortcut event ordering and flags`.

---

## Phase 3 — Menu-bar status UX

### Task 13: Truthful, friendly status model

**Files:**
- Create: `Sources/RazerCore/MenuStatusModel.swift` (pure mapping: `DeviceMenuStatus(connection:, error:, remapper:, persistence:) -> lines/badges`)
- Modify: `RazerMenuBarApp/AppModel.swift`, `RazerMenuBarApp/RazerMenuBarApp.swift`, `Sources/RazerCore/PermissionStatus.swift`
- Create: `Tests/RazerCoreTests/MenuStatusModelTests.swift`

**Step 1: Failing tests** for the pure mapper:
- `RazerCommandError` → short menu strings ("Mouse not found", "Permission needed — open Settings", "Another app controls the mouse", "Mouse busy — retrying"), never raw `localizedDescription` dumps.
- `.circuitOpen` title becomes **"Remapper paused (safety)"**, distinct from manual "Remapper paused"; menu also shows its one-line detail and a "Re-arm…" affordance while Pause/Resume is hidden.
- Persistence warnings (`corruptPreserved`, blocked writes) and permission warnings produce a `⚠︎` menu line.
- Reconnect produces a transient "Reconnected — profile reapplied"/"…not applied" line; disconnect resets battery display (no stale % flash).

**Step 2–4: Red → implement → green** (views render the model's lines; keep SwiftUI thin). **Step 5: Commit** `feat(ux): truthful menu status model`.

### Task 14: Battery affordances in the status item

**Files:**
- Modify: `RazerMenuBarApp/RazerMenuBarApp.swift`, `RazerMenuBarApp/AppModel.swift`, `Sources/RazerCore/MenuStatusModel.swift`
- Test: `Tests/RazerCoreTests/MenuStatusModelTests.swift`

**Step 1: Failing tests:** mapper flags `lowBattery` at ≤15% (hysteresis: clears at ≥20%), `charging` state renders a bolt indicator, battery text hidden when disconnected. **Step 2–4: Red → implement → green. Step 5: Commit** `feat(ux): low-battery and charging indicators`.

---

## Phase 4 — Profile store robustness

### Task 15: Explicit schema version

**Files:**
- Modify: `Sources/RazerCore/ProfileStore.swift` (`ProfileBundle` gains `schemaVersion: Int`, current = 2; decode-missing → 1 and run existing implicit migrations; future-version files fail closed to quarantine)
- Test: `Tests/RazerCoreTests/ProfileSchemaTests.swift`, `MouseProfileMigrationTests.swift`

Red → green → **commit** `feat(profiles): explicit schema version with fail-closed future versions`.

### Task 16: Quarantine discoverability and guided restore

**Files:**
- Modify: `Sources/RazerCore/ProfileStore.swift` (list quarantine files; `attemptRestore(from:)` = re-run full validation pipeline on the quarantined bytes, swap in only if valid), `RazerMenuBarApp/SettingsView.swift` (Diagnostics: list + "Restore"/"Reveal in Finder"), `RazerMenuBarApp/AppModel.swift`
- Test: `Tests/RazerCoreTests/ProfileStoreRecoveryTests.swift`

**Failing tests:** restore of a valid quarantined file replaces the bundle and re-quarantines nothing; restore of a still-invalid file fails closed with the original bundle untouched. Red → green → **commit** `feat(profiles): guided restore from quarantine`.

### Task 17: `ProfileStore` concurrency guard and outcome-preserving API

**Files:**
- Modify: `Sources/RazerCore/ProfileStore.swift` (serialize `save`/`loadOutcome` behind one lock or serial queue; mark outcome-less `load()` deprecated, migrate internal callers)
- Test: `Tests/RazerCoreTests/ProfileStoreRecoveryTests.swift` (concurrent save/load stress test, `concurrentPerform` pattern already used in `InputCaptureDiagnosticSinkTests`)

Red → green → **commit** `fix(profiles): serialize store access`.

---

## Phase 5 — Integration depth and acceptance

### Task 18: `AppModel` refresh/reconnect tests behind a session protocol

**Files:**
- Modify: `Sources/RazerCore/DeviceSession.swift` (extract `DeviceSessionProtocol`), `RazerMenuBarApp/AppModel.swift` (inject)
- Create: `Tests/RazerCoreTests/AppModelRefreshFlowTests.swift` (move the flow logic into a `RazerCore` coordinator type if `RazerMenuBarApp` sources stay outside the test target)

Cover: stale handle → invalidate → reconnect → auto-apply with gate supersession; auto-apply budget decrement; `becameConnected` wheel reprobe (and reprobe on auto-apply retry — currently skipped, `AppModel.swift:409–444`); apply-failure session invalidation (Task 3 integration). Red → green → **commit** `test(app): refresh and reconnect flow coverage`.

### Task 19: Manual acceptance matrix update

**Files:**
- Modify: `docs/testing/cgevent-remapper-acceptance.md` (or create `docs/testing/reliability-acceptance.md`)

Add checklist rows: unplug/replug dongle mid-apply; sleep → wake → auto-reapply; BT + dongle simultaneously (deterministic interface pick); momentum scroll with wheel mapped to click (no click storm); trackpad horizontal scroll with remapper on; circuit-breaker trip visible in menu as "(safety)". Run with the physical mouse; record results in the doc. **Commit** `docs: reliability acceptance matrix`.

---

## Files expected to change

- `Sources/RazerCore/RazerCommandClient.swift`, `RazerResponseValidator.swift`, `DeviceDescriptor.swift`, `HIDDeviceDiscovery.swift`, `HardwareProfileApplier.swift`, `HardwareApplyPolicy.swift`, `ProfileStore.swift` (+ new `DeviceSession.swift`, `MenuStatusModel.swift`), `InputRemapper.swift`, `InputRemapperEngine.swift`, `InputCaptureSession.swift`, `PermissionStatus.swift`
- `RazerMenuBarApp/AppModel.swift`, `RazerMenuBarApp.swift`, `SettingsView.swift`
- `Tests/RazerCoreTests/` — new: `RazerCommandClientTransportTests.swift`, `HIDInterfaceSelectionTests.swift`, `DeviceSessionTests.swift`, `InputRemapperScrollTests.swift`, `MenuStatusModelTests.swift`, `AppModelRefreshFlowTests.swift`; extended: applier/recovery/schema/store tests
- `docs/testing/` acceptance matrix

## Tests and verification

```bash
swift test
xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build
```

Run both after every task. Baseline before this plan: 233 tests passing, Debug build succeeding.

## Cursor handoff prompt

```text
Implement this plan: docs/plans/2026-07-18-reliability-and-status-ux-improvements.md

Follow the checklist in phase order (Phase 1 first). TDD every task: write the failing test, watch it fail, implement minimally, watch it pass, commit. Keep the plan updated as you complete items. Do not expand scope without asking. HARD GATE: if any task requires changing the 90-byte report codec, transaction IDs, multi-packet handling, or command classes, stop and ask before coding. DriverKit, notarization, and Synapse parity are out of scope. Run swift test and the Debug xcodebuild after each task and report results.
```

## Implementation checklist

- [x] Task 1: Inject `RazerReportTransport` into `RazerCommandClient` + transport tests
- [x] Task 2: Bounded response poll replaces fixed 60 ms sleep
- [x] Task 3: BUSY exhaustion + explicit-apply failure invalidate session
- [x] Task 4: Deterministic control-interface selection
- [x] Task 5: Removal callbacks + sleep/wake reconnect
- [x] Task 6: Post-apply readback verification + fail-closed polling decode
- [x] Task 7: Gate re-check between apply writes
- [x] Task 8: Axis-2 scroll handling
- [x] Task 9: Scroll-action momentum throttle
- [x] Task 10: Locking race fixes (remapper + capture session)
- [x] Task 11: Resume vs circuit-open UI consistency
- [x] Task 12: Shortcut posting safety
- [x] Task 13: Truthful menu status model
- [x] Task 14: Low-battery and charging indicators
- [x] Task 15: Profile schema version
- [x] Task 16: Quarantine restore UX
- [x] Task 17: ProfileStore concurrency guard
- [x] Task 18: AppModel refresh-flow tests
- [x] Task 19: Manual acceptance matrix (physical run completed and signed off 2026-07-23; R3/R6 skipped with recorded reasons)
