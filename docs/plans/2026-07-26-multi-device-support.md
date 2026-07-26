# Plan: Multi-Device Support (Other Razer Mice + Keychron M6)

## Goal

Evolve the app from single-device (Razer Viper V3 HyperSpeed, `1532:00B8`) to multi-device:

1. **Tier 1 — Known Razer mice:** curated registry of Razer models with correct per-device
   protocol parameters (transaction ID, DPI range, polling rates), full hardware control.
2. **Tier 2 — Unknown Razer mice:** any `1532:*` pointer device gets best-effort hardware
   control via runtime capability probing and readback verification.
3. **Tier 3 — Keychron M6 (VID `0x3434`):** software remapping immediately (already works —
   the CGEvent tap is session-wide); hardware control (DPI stages, polling, battery) after a
   dedicated protocol reverse-engineering phase, behind the existing `DeviceCommandClient`
   abstraction.

Non-goals (deferred): RGB lighting, Bluetooth-transport hardware control, DriverKit exclusive
ownership (issue #2), renaming the app/repo.

## Current Codebase Facts

- `Sources/RazerCore/DeviceDescriptor.swift` is the **single coupling point**: a static enum
  with VID/PID (`1532:00B8`), `featureReportLength = 90`, `transactionID = 0x1F`, DPI range
  100–30 000, max 5 stages, polling {125, 500, 1000}, and timing constants.
- Consumers of `DeviceDescriptor` statics (all must become instance-parameterized):
  - `RazerReport.swift` — report length, transaction ID in `makeCommand`, DPI clamps in
    `setDPI`/`decodeDPIStages`, polling validation, `ProfileValidator`.
  - `HIDDeviceDiscovery.swift` — IOHIDManager matching dict is VID+PID exact;
    `isTargetControlInterface` = usage 1:2 + feature size ≥ 90.
  - `DeviceSession.swift:250` — removal-monitor matching dict (VID/PID/usage).
  - `ProfileStore.swift:272` — **already parameterized** by `deviceKey: String` (defaulting to
    `DeviceDescriptor.deviceKey`); files are `profiles-<deviceKey>.json`. Multi-device profile
    storage is nearly free.
  - `ProfileDraft.swift`, `HardwareStateTransaction.swift:98` — DPI/polling validation clamps.
  - `RazerMenuBarApp.swift:64`, `SettingsView.swift:39,258–285` — hardcoded product name,
    stage-count and polling-rate pickers.
  - `RazerProbeCLI/main.swift` — status text only.
- `DeviceCommandClient` protocol (`DeviceSession.swift:10`) already abstracts the command
  client (`readState`, `probeWheelCapability`, `wheelProbeSummary`). `RazerCommandClient` is
  one conformer; a `KeychronCommandClient` can slot in.
- `RazerCommandClient` has an injectable `RazerReportTransport` seam — the whole test suite
  runs against fake transports. New devices can be tested the same way.
- `WheelCapabilityProbe` + `sendAllowingUnsupported` (`NOT_SUPPORTED` status 0x05 handling)
  is an existing runtime-capability-probe pattern; it generalizes to DPI-stages/battery/polling
  probing for unknown devices.
- `HardwareStateTransaction` already does write-then-readback verification — the safety
  mechanism Tier 2 and Tier 3 rely on.
- The input remapper (`InputRemapper*.swift`, `InputCaptureSession.swift`) is a session-wide
  CGEvent tap with **no per-device filtering** — it already remaps a Keychron M6 or any other
  mouse today. Only UI copy implies Razer-only.

## External Facts (verify during implementation)

- **Razer protocol** (OpenRazer `razermouse_driver.c` is the reference, as already noted in
  `RazerReport.swift`):
  - The 90-byte feature-report protocol is uniform across Razer mice; what varies per model is
    the **transaction ID** (`0x1F`, `0x3F`, `0x8F`, `0x9F` — OpenRazer switches on PID), the
    **DPI ceiling** (6 400 → 35 000 depending on sensor), stage count, and which command
    classes respond (battery only on wireless; scroll-mode class 0x02 only on HyperScroll
    wheels).
  - The same physical product has **different PIDs per link**: wired / 2.4 GHz dongle /
    Bluetooth. Bluetooth generally does not speak this feature-report protocol → hardware
    control stays USB/dongle-only (discovery already ranks BT last; make the exclusion
    explicit).
  - HyperPolling models (2K/4K/8K) use separate extended polling commands
    (OpenRazer `*_polling_rate2`); base commands cap at 1000 Hz.
- **Keychron M6** ([product page](https://www.keychron.com/products/keychron-m6-wireless-mouse)):
  - Configured only through the **Keychron Launcher web app** over WebHID (Chrome-family),
    wired or 2.4 GHz receiver — not Bluetooth
    ([Keychron docs](https://www.keychron.com/blogs/news/how-to-set-pointer-and-report-rate-on-launcher)).
  - **Target device is the M6 1K variant** (confirmed by maintainer, 2026-07-26): 100–26 000
    DPI, polling 125/500/1000 Hz. The 4K/8K variant (30 000 DPI, up to 8000 Hz via its special
    receiver) is out of scope; do not add a registry entry for it without hardware to verify.
  - Vendor ID `0x3434` (Keychron; M5 dongle observed as `3434:d048` in
    [libratbag#1815](https://github.com/libratbag/libratbag/issues/1815)). M6 PID must be
    enumerated locally with the probe CLI.
  - **No public protocol documentation and no open-source implementation exists** (libratbag
    request is open/unimplemented). Hardware control requires original reverse engineering.
    Keychron has open-sourced hardware CAD, not the mouse firmware protocol.

## Decisions

1. **Registry, not subclassing.** Replace the `DeviceDescriptor` static enum with a value type
   `MouseModel` (capabilities + protocol parameters) and a `DeviceRegistry` keyed by
   `(vendorID, productID)`. One Razer command client parameterized by model; per-vendor
   clients only where the wire protocol differs (Keychron).

   ```swift
   public struct MouseModel: Sendable, Equatable {
       public enum Family { case razer, keychron }
       public let family: Family
       public let vendorID: UInt16
       public let productID: UInt16
       public let name: String
       public let deviceKey: String            // "1532:00B8" — profile file key, unchanged
       public let transactionID: UInt8         // razer only
       public let dpiRange: ClosedRange<Int>
       public let maxDPIStages: Int
       public let pollingRates: [Int]
       public let hasBattery: Bool
       public let supportTier: SupportTier     // .verified, .community, .probed
   }
   ```

2. **Match by vendor, resolve by PID.** `HIDDeviceDiscovery` matches on VID ∈ {0x1532, 0x3434}
   (array-of-dicts IOHIDManager matching), then resolves each PID against the registry;
   unknown Razer PIDs produce a synthesized `.probed`-tier model with conservative defaults.
3. **Tier 2 safety = probe + readback.** For unknown Razer mice: probe capabilities with
   `sendAllowingUnsupported` (battery, DPI stages, polling, wheel); discover a working
   transaction ID by trying `0x1F → 0x3F → 0x9F → 0x8F` against a read-only command
   (get firmware/serial, class 0x00) and caching the first that returns SUCCESS; validate every
   write via existing readback-verify. DPI input clamp for probed devices: accept the range the
   device echoes back rather than trusting a static ceiling.
4. **Keychron RE method: WebHID interception, all on macOS.** Open Keychron Launcher in
   Chrome, and from DevTools wrap `HIDDevice.prototype.sendReport`,
   `sendFeatureReport`, and `inputreport` events with logging before connecting. Exercise each
   Launcher control (DPI level values, polling, LOD, battery view, button remap) and record
   request/response byte transcripts. No Windows/Wireshark needed. Store sanitized captures in
   `docs/testing/keychron-m6-captures/`.
5. **Keychron writes are replay-with-substitution only.** Until the protocol is well
   understood, `KeychronCommandClient` sends only byte sequences observed verbatim from
   Launcher captures, with value fields substituted, followed by readback where a read command
   exists. No speculative commands. Probe CLI gets a `--dry-run` printing what would be sent.
6. **Remapper stays session-wide.** CGEvent taps cannot reliably attribute events to a specific
   device; per-device remapping would require an IOHID-level tap (large scope). Update UI copy
   instead: remapping applies to all pointing devices.
7. **Profiles:** keep `profiles-<deviceKey>.json` scheme; each connected device gets its own
   store instance. Existing Viper profiles keep their key — no migration needed.
8. **UI:** menu bar shows a device picker when >1 supported device is connected; status section,
   DPI-stage editor, and polling picker read limits from the active device's `MouseModel`
   instead of `DeviceDescriptor`.

## Open Questions

- Which additional Razer models does the maintainer physically own? Only those can be
  `.verified`; others enter as `.community` (parameters transcribed from OpenRazer, untested).
- Should unknown-Razer (Tier 2) hardware writes be gated behind an explicit "experimental
  device" toggle in Settings? (Recommended: yes.)

## Implementation Steps

### Phase 0 — Decouple the descriptor (no behavior change) — **DONE 2026-07-26**

- [x] Add `MouseModel`, `SupportTier`, and `DeviceRegistry` in `Sources/RazerCore/`; seed with
      exactly one entry: Viper V3 HyperSpeed with today's constants.
- [x] Thread `MouseModel` through `RazerReport` (make `makeCommand`/builders take the model or
      move builders onto a `RazerCommandEncoder` struct holding the model), `ProfileValidator`,
      `ProfileDraft`, `HardwareStateTransaction`, `RazerCommandClient`.
- [x] Parameterize `HIDDeviceDiscovery` and `DeviceSession` matching dicts; return the resolved
      `MouseModel` on `DiscoveredHIDInterface`.
- [x] Replace UI references (`RazerMenuBarApp.swift:64`, `SettingsView.swift`) with
      model-driven values.
- [x] Keep `DeviceDescriptor` as a deprecated alias for one release to limit test churn, or
      mechanically update tests; all existing tests must pass unchanged in behavior.
      **Took the mechanical path** — only four test files ever referenced it.

#### How Phase 0 actually landed

- `RazerCommandEncoder` (a struct holding a `MouseModel`) replaced the 15 static builders on
  `RazerReport`; `RazerReport` is now a pure packet container plus decoders. `RazerReport.length`
  is pinned to a literal `90` — it is a family-wide frame constant, not a device parameter, since
  seven byte offsets encode it independently and `calculateCRC` silently returns 0 on a length
  mismatch. `MouseModel.minimumFeatureReportSize` is the separate discovery threshold (`>=`).
- `ProfileLimits` (dpiRange / maxDPIStages / pollingRates) is the protocol-agnostic slice used by
  `ProfileStore`, `ProfileDraft`, and `ProfileSafetyValidator`, so those types cannot reach
  `transactionID`. Phase 4's Keychron client reuses it unchanged.
- `RazerValidationError` payloads widened (`invalidDPI(_, allowed:)`,
  `unsupportedPollingRate(_, supported:)`, `tooManyDPIStages(_, maximum:)`) so messages are a pure
  function of the error rather than reading a shared constant. Done as an isolated first change
  while the old statics still fed the payloads, which is what makes the frozen strings a real proof.
- The model rides on the client (`DeviceCommandClient.model`, `RazerHardwareMutating.model`), so
  `HardwareStateTransaction`'s entry points keep their exact signatures and a client/model mismatch
  is structurally impossible.
- `IOHIDManagerSetDeviceMatching` still executes as a single-dictionary call while the registry has
  one entry; the multi-dictionary path exists but is dormant until Phase 2.
- **Semver-relevant breaks in the `RazerCore` library:** `DeviceDescriptor` deleted,
  `ProfileValidator` reduced to `validateWheelSpeedMultiplier`, `RazerValidationError` payloads
  widened, `RazerReport.init`'s `transactionID` default removed, `ProfileStore`/`ProfileDraft`/
  `validateAndRepair` gained required `limits:`, `HIDDeviceDiscovery`/`DeviceSession` gained
  required `registry:`, and `findControlDevice()` now returns `ResolvedControlDevice?`.
- **Deliberate gap:** `MouseProfile.activeDPI`'s empty-stage fallback became
  `MouseProfile.emptyStagesFallbackDPI = 100` rather than a model lookup. `MouseProfile` is the
  on-disk `Codable` shape and must stay model-free; the branch is unreachable through the store
  because `validateStages` rejects empty stage lists.
- **Phase 1 debt recorded, not fixed:** the polling-rate set still has three sources of truth
  (`MouseModel.pollingRates`, the `setPollingRate` encode switch, the `decodePollingRateHz` decode
  switch); `dataSize: 0x26` is an unexpressed `3 + maxDPIStages * 7` (pinned by a test);
  `ProfileStore.defaultBundle()` and `ProfileDraft.pollingError`'s literal string are still
  hardcoded; and `RazerHIDDriver/Info.plist` carries a second copy of the device identity
  (VendorID 5426 / ProductID 184) that no Swift registry can govern.

#### Phase 0 verification results

- `swift test --disable-sandbox`: 423 tests, 0 failures (debug and `-c release --arch arm64`),
  10 consecutive full-suite runs green.
- `xcodebuild -scheme RazerMenuBarApp -configuration Debug`: BUILD SUCCEEDED.
- `bash scripts/verify-release-contract.sh`: all checks passed.
- `Tests/RazerCoreTests/RazerReportGoldenBytesTests.swift` (new): 26 full 90-byte command
  encodings and 9 user-facing error strings captured from the pre-refactor build and verified
  byte-identical after every step. This is the acceptance oracle for the phase.
- **Pre-existing test crash, found and fixed here** (it predates this work — reproduced on a
  pristine worktree of `d2305c0`): `InputRemapperScrollTests`
  `testMappedDualAxisThrottledTickStillReturnsScaledAxis2Remainder` SIGSEGV'd the whole test
  process. Root cause from the lldb backtrace: `XCTAssertNotNil` stringifies its value, which
  reflects the `Unmanaged<CGEvent>` via `Mirror`, and reflection retains the raw pointer
  (`ObjCRetainableBox::initializeWithCopy` → `objc_retain`). At that call site the source
  `CGEvent` was an inline temporary already released, so it retained freed memory. Sibling
  assertions survived only because their events were held in locals. **The production ownership
  contract is correct** — `processScrollWheelEvent` returns `Unmanaged.passUnretained` of the
  caller's own event, which is exactly right for a `CGEventTap` callback, where the event is
  guaranteed live for the callback's duration. The fix is test-only: a `processScroll` helper in
  each of the three remapper test files converts to a managed reference under
  `withExtendedLifetime` before any assertion sees it, removing the whole class of hazard.
  Verified with 10 consecutive full-suite runs (no `--skip`), all green.
- **Not verified — needs hardware:** `swift run RazerProbeCLI list` / `battery` / `dpi` / `stages`
  / `polling` / `integration` against a real Viper V3 HyperSpeed. Discovery and the removal
  monitor have no IOHIDManager fake, so the registry-matching change is uncovered by CI.

### Phase 1 — Known Razer models (Tier 1)

- [ ] Transcribe registry entries from OpenRazer for an initial set (suggest: Viper V3 Pro,
      Viper V2 Pro, DeathAdder V3/V3 Pro, Basilisk V3, Orochi V2 — final list per Open
      Questions), one entry per PID (wired and dongle PIDs are separate entries pointing at the
      same display name).
- [ ] Per-entry fixture tests: fake transport asserting exact command bytes (transaction ID,
      DPI clamp boundaries, polling encode/decode) per model.
- [ ] Wired-model handling: skip battery/charging reads when `hasBattery == false`
      (`readState` must not fail the whole refresh).
- [ ] README support matrix with tier labels.

### Phase 2 — Unknown Razer fallback (Tier 2)

- [ ] Transaction-ID discovery probe + capability probe (battery / DPI stages / polling /
      wheel) run once at connect, cached per registry-entry-ID; surface results in Diagnostics.
- [ ] Synthesized `.probed` model with conservative DPI range and readback-adjusted clamps.
- [ ] Settings toggle gating hardware writes on `.probed` devices; warning copy.
- [ ] `RazerProbeCLI` `support-report` subcommand: dumps interfaces, probe results, and
      readbacks as a redacted markdown block users can paste into a GitHub issue → pipeline for
      promoting devices to `.community`.

### Phase 3 — Multi-device sessions and UI

- [ ] `AppModel`/`DeviceRefreshCoordinator`: one `DeviceSession` + `ProfileStore` +
      auto-apply coordinator per connected supported device (identity = registry entry ID, as
      today).
- [ ] Menu bar device picker; per-device status lines; per-device settings tabs.
- [ ] Auto-apply on reconnect per device (existing `AutoApplyCoordinator`, scoped).
- [ ] Update remapper UI copy: session-wide, all pointing devices.

### Phase 4 — Keychron M6

- [ ] **4a (immediate):** add VID `0x3434` to discovery as display/diagnostics-only; UI shows
      the M6 with "software remapping only" badge. Confirm remapper + scroll tuning work (they
      should, unchanged).
- [ ] **4b (capture):** enumerate M6 PIDs (dongle + wired) with the probe CLI; run the WebHID
      interception protocol (Decision 4) covering DPI levels, active level, polling, LOD,
      battery, button remap; commit sanitized transcripts + a findings doc
      (`docs/testing/keychron-m6-protocol.md`).
- [ ] **4c (implement):** `KeychronReportTransport` (likely output/input reports on a vendor
      HID interface rather than feature reports — captures will tell), `KeychronCommandClient`
      conforming to `DeviceCommandClient`, replay-with-substitution encoders, fixture tests
      from the captured transcripts.
- [ ] **4d (integrate):** registry entries for the M6 1K (dongle + wired PIDs); wire DPI
      stages / polling / battery
      into the existing UI; probe CLI `--dry-run`; acceptance doc in `docs/testing/` following
      the existing acceptance-doc pattern.

### Phase 5 — Optional follow-ups

- [ ] Extended polling (2K/4K/8K) for HyperPolling Razer devices and M6 8K.
- [ ] Lighting (Razer class 0x03/0x0F) — separate plan.
- [ ] App display-name generalization ("Mouse Control"?) — cosmetic, separate decision.

## Files Expected To Change

- `Sources/RazerCore/DeviceDescriptor.swift` → replaced by `MouseModel.swift`,
  `DeviceRegistry.swift` (new)
- `Sources/RazerCore/RazerReport.swift`, `RazerCommandClient.swift`,
  `HIDDeviceDiscovery.swift`, `DeviceSession.swift`, `ProfileStore.swift`,
  `ProfileDraft.swift`, `HardwareStateTransaction.swift`, `RazerResponseValidator.swift`
- `Sources/RazerCore/KeychronCommandClient.swift`, `KeychronReport.swift` (new, Phase 4)
- `RazerMenuBarApp/RazerMenuBarApp.swift`, `SettingsView.swift`, `AppModel.swift`
- `Sources/RazerProbeCLI/main.swift`, `Sources/RazerCore/ProbeArgumentParser.swift`
- `Tests/RazerCoreTests/*` (mechanical model-injection updates + new per-model fixtures)
- `README.md` (support matrix), `docs/testing/keychron-m6-protocol.md` (new)

## Risks

- **Wrong transaction ID** on a Razer device → command timeouts, no writes land (benign; probe
  handles it).
- **Untested `.community` parameters** → DPI clamp mismatch; mitigated by readback verification
  already in `HardwareStateTransaction`.
- **Keychron unknowns**: an unrecognized write could flip onboard profile state or worse;
  mitigated by replay-only writes, readback, dry-run, and keeping M6 hardware control opt-in
  until validated. Firmware updates may change the protocol between M6 revisions.
- **Bluetooth**: neither vendor's config protocol is assumed to work over BT; hardware control
  is explicitly USB/dongle-only, status copy must say so.
- **CI cannot exercise hardware**: coverage stays at fake-transport fixtures + manual
  acceptance docs, consistent with the existing `docs/testing/` practice.

## Tests And Verification

```bash
swift test
xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build
# Hardware acceptance (per device, manual):
swift run RazerProbeCLI list
swift run RazerProbeCLI support-report        # Phase 2+
```

## Cursor Handoff Prompt

```text
Implement this plan: docs/plans/2026-07-26-multi-device-support.md

Follow the checklist in order, phase by phase; stop for review at the end of each phase. Keep
the plan updated as you complete items. Do not expand scope without asking. Preserve unrelated
user changes. Run the verification commands listed in the plan and report the results.
```
