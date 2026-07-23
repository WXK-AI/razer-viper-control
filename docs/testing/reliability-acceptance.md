# Reliability and Status UX — Physical Acceptance

**Overall status:** **PHYSICAL RUN COMPLETE — 2026-07-23 (operator xk): R1, R2, R4, R5 Pass; R3, R6 Skip (reasons recorded)**

**Plan:** `docs/plans/2026-07-18-reliability-and-status-ux-improvements.md` (Phase 5 Task 19 — documentation portion)

**Scope:** Physical verification of reconnect reliability, auto-reapply, interface selection, remapper edge fixes, and truthful menu status. This is **not** a full button/scroll matrix.

**Cross-reference:** For the larger CGEvent button/drag/scroll/pause/permission matrix, use [`cgevent-remapper-acceptance.md`](cgevent-remapper-acceptance.md). Keep results for reliability rows in this document only.

**Remapper scope (important):** Software remapping is **session-wide** for every mouse and trackpad in the login session — not Razer-only. The trackpad row must verify that documented behavior, not pretend device isolation.

---

## Baseline evidence (independently verified — not a physical pass)

| Item | Value |
|------|--------|
| Git SHA | `5829977` (`58299779583054b4f11ba6e215e030ccefaab4a4`) |
| Date of baseline record | 2026-07-20 |
| `swift test --disable-sandbox` | **402/402 pass** |
| Debug `RazerMenuBarApp` (`xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build`) | **BUILD SUCCEEDED** |
| Read-only system inspection | Connected **Razer Viper V3 HyperSpeed** USB device **`1532:00B8`** observed on **2026-07-20** |

**Device presence does not prove any interactive row.** Interactive Result columns were filled after the 2026-07-23 physical run (operator xk); see matrix and sign-off below.

---

## Prerequisites (required before any interactive row)

1. **Backup pointer** available at all times (built-in trackpad, second mouse, or known-good remote). Do not start mid-apply or circuit-breaker tests without a way to regain control if remapping misbehaves.
2. **Permissions:** Input Monitoring and Accessibility granted to `RazerMenuBarApp`.
3. **Known-good profile** selected: valid DPI/polling stages, remapper settings understood, auto-reapply enabled where the row requires it.
4. **Build:** Debug or Release app from the SHA under test (baseline SHA above unless re-baselined).
5. **Emergency pause:** **⌃⌥⌘R** known and tested once before the matrix.
6. **Environment notes to record up front:**
   - macOS version
   - Transport(s) in use (USB dongle / Bluetooth)
   - Whether **Razer Synapse**, **SteerMouse**, or other exclusive HID owners are installed/running
7. **Operator sign-off** at the end of this document is required; unsigned runs are incomplete.

### Conflict software

If another process owns the mouse (e.g. Razer Synapse / appengine, third-party drivers), HID feature reports may return **access conflict** / “another app controls the mouse”. Record that as the **Result** (Fail or Skip with reason). **Do not** silently kill other software or work around ownership without recording it.

### Status vocabulary

| Result | Meaning |
|--------|---------|
| **Pass** | Procedure completed; expected observables met; evidence recorded |
| **Fail** | Procedure completed or aborted; pass criteria not met |
| **Skip** | Not run; model/environment limitation or blocked by conflict — **must** include reason |
| **Pending** | Not yet run |

---

## Interactive matrix

### R1 — Dongle unplug / replug mid-apply

| Field | Content |
|-------|---------|
| **Setup** | Mouse on 2.4 GHz dongle. Known-good profile with auto-reapply on. App running, device Connected. Backup pointer ready. |
| **Action** | Start **Apply Profile** (or a DPI/hardware apply that takes a moment). While apply is in flight or immediately as it starts, **unplug the dongle**, wait ~2 s, **replug**. Optionally wait for menu status to settle, then Apply again if needed. |
| **Expected** | No hang or stuck remapper. Menu eventually shows **Disconnected** then **Connected** (or reconnect feedback). No crash. After reconnect, device usable; profile can be reapplied (auto or explicit) without manual app restart. |
| **Pass criteria** | App remains responsive; status honest (not stuck “Connected” while dead); apply either completes, reports friendly failure, or recovers on reconnect; pointer usable with backup during disconnect. |
| **Fail / abort** | Crash; frozen menu; stuck buttons; permanent “busy” without recovery; no path to reapply without force-quit. Abort if pointer lost and backup fails. |
| **Evidence to record** | Timestamp; whether apply was mid-flight; final menu status lines; whether auto-reapply ran; screenshot of menu if possible. |
| **Result** | Pass |
| **Evidence / notes** | No hang/crash; menu showed Disconnected then Connected; profile reapplied without app restart. |

### R2 — Sleep → wake → auto-reapply

| Field | Content |
|-------|---------|
| **Setup** | Dongle connected. Profile with **auto-reapply on** and a **distinct DPI** vs defaults so reapply is observable. App running and Connected. |
| **Action** | Note current active DPI in menu/Settings. Put Mac to **sleep** ≥10 s (lid or Apple menu). **Wake**. Wait up to ~10 s after wake (includes post-wake refresh delay). Check menu DPI/status. |
| **Expected** | Brief Disconnected during sleep is OK. After wake: Connected (or reconnect line); active DPI matches selected profile without requiring manual Apply (when auto-reapply enabled). |
| **Pass criteria** | Device returns; auto-reapply restores hardware profile (or clear “not applied” feedback if budget exhausted — note that); no crash. |
| **Fail / abort** | Never reconnects; wrong DPI with no warning; app hung after wake. |
| **Evidence to record** | DPI before sleep / after wake; auto-reapply setting; menu status after wake; time to reconnect. |
| **Result** | Pass |
| **Evidence / notes** | Device reconnected after wake; active DPI auto-restored to profile value (auto-reapply enabled). |

### R3 — Bluetooth + dongle simultaneously (deterministic interface pick)

| Field | Content |
|-------|---------|
| **Setup** | Mouse paired over **Bluetooth** *and* **2.4 GHz dongle** both available (both transports present to the OS). App running. Prefer a machine that lists both interfaces. |
| **Action** | Launch or **Refresh**. Note which transport path works for battery/DPI reads. Toggle power/unplug one transport if needed to force dual presence, then Refresh. Repeat 2–3 times cold-start or Refresh. |
| **Expected** | Control interface selection is **stable** across refreshes (deterministic preference: USB/dongle over Bluetooth when both candidates exist). No crash; consistent Connected/Disconnected behavior. |
| **Pass criteria** | Repeated Refresh yields the same successful path when both interfaces remain present; no nondeterministic flip-flop of working interface without hardware change. |
| **Fail / abort** | Alternating success/failure without hardware change; commands randomly hit the wrong interface; crash. |
| **Skip if** | Hardware/OS cannot present both transports at once — mark **Skip** with reason (not Pass). |
| **Evidence to record** | Whether both transports were truly present; which path appeared to win; number of Refresh cycles; any conflict message. |
| **Result** | Skip |
| **Evidence / notes** | Mouse connected via 2.4GHz dongle only; Bluetooth transport not present, so dual-interface selection could not be exercised. |

### R4 — Momentum scroll with wheel mapped to click (no click storm)

| Field | Content |
|-------|---------|
| **Setup** | Remapper **armed** and active. Map **wheel up and/or wheel down** to a **button or one-shot click** action. Use a long document or list that generates **momentum scroll**. Backup pointer ready. |
| **Action** | Flick the wheel hard to induce momentum. Observe click count vs scroll duration. Pause remapper (⌃⌥⌘R) if clicks flood. |
| **Expected** | Scroll-mapped actions are **throttled** under momentum: not one click per inertial tick. Usable scroll without click storm. |
| **Pass criteria** | No rapid continuous click storm during a single flick; throttle behavior clearly better than unthrottled tick-per-action. |
| **Fail / abort** | Click storm saturates UI; stuck button; need force-quit. |
| **Evidence to record** | Mapping used; qualitative click density; whether throttle felt present; app version/SHA. |
| **Result** | Pass |
| **Evidence / notes** | Wheel up/down mapped to left-click; hard flick produced only throttled clicks (ScrollActionThrottle); no click storm, no stuck inputs. Mapping consumes scroll by design (documented); operator reverted mapping to passthrough afterward. |

### R5 — Trackpad horizontal scroll while remapper is on

| Field | Content |
|-------|---------|
| **Setup** | Remapper **on and armed** (session-wide). Built-in or external trackpad available. Open an app that supports **horizontal** trackpad scroll (e.g. wide spreadsheet, horizontal browser history, or Settings list). |
| **Action** | Perform **two-finger horizontal** trackpad scroll. Also verify vertical trackpad scroll. Confirm Razer mouse still remaps as configured. |
| **Expected** | Horizontal trackpad scroll **works** (axis-2 deltas scaled/passed through). Remapping remains **session-wide**: trackpad buttons/scroll may still be affected by remapper rules per product scope — **document what you observe**; do not claim Razer-only isolation. |
| **Pass criteria** | Horizontal trackpad scroll is usable (not dropped entirely). Operator records session-wide effects honestly. |
| **Fail / abort** | Horizontal scroll completely dead with remapper on; stuck inputs. |
| **Evidence to record** | App used for horizontal scroll; remapper mappings; whether trackpad buttons were also remapped (scope confirmation). |
| **Result** | Pass |
| **Evidence / notes** | Horizontal trackpad scroll works with remapper armed; session-wide behavior as documented. |

### R6 — Circuit-breaker trip visible as safety status

| Field | Content |
|-------|---------|
| **Setup** | Remapper armed and active. Menu bar extra visible. Settings open optional. Backup pointer ready. |
| **Action** | Induce **repeated event-tap timeouts / disables** until the circuit breaker opens (lab method: if no reliable repro, use the recovery path the app documents or force conditions that previously tripped “repeated event-tap timeouts”). Observe **menu bar** status (and Settings remapper row if open). Attempt Pause/Resume vs Re-arm affordance. |
| **Expected** | Menu shows **distinct safety pause**: title includes **“Remapper paused (safety)”** (not identical to manual pause). Detail about repeated timeouts. **Re-arm…** (or equivalent) shown; Pause/Resume not the sole recovery path while circuit-open. |
| **Pass criteria** | Safety status is **visibly distinct** from manual “Remapper paused”; recovery affordance matches safety path. |
| **Fail / abort** | Circuit open with only generic “paused” and no safety label; no recovery path; remapper stuck without message. |
| **Skip if** | Cannot trip breaker safely on this OS — **Skip** with reason (not Pass). |
| **Evidence to record** | Exact menu title string; whether Re-arm appeared; how trip was induced; recovery success/fail. |
| **Result** | Skip |
| **Evidence / notes** | Repeated event-tap timeouts could not be reliably induced on this system; safety-status UI verified in code/tests only (TapDisableCircuitBreakerTests, InputRemapperRecoveryTests). |

---

## Operator capture log

| # | Started (local time) | Ended | Result (Pass/Fail/Skip/Pending) | Evidence summary |
|---|----------------------|-------|----------------------------------|------------------|
| R1 | 2026-07-23 (session) | — | Pass | reconnect + reapply OK |
| R2 | 2026-07-23 (session) | — | Pass | DPI restored after wake |
| R3 | 2026-07-23 (session) | — | Skip | no BT transport |
| R4 | 2026-07-23 (session) | — | Pass | throttle OK, no storm |
| R5 | 2026-07-23 (session) | — | Pass | horizontal scroll OK |
| R6 | 2026-07-23 (session) | — | Skip | not inducible |

### Environment capture (fill at start)

| Field | Value |
|-------|--------|
| Operator name | xk |
| Date | 2026-07-23 |
| macOS version | macOS (Apple Silicon); exact version not recorded |
| App build (Debug/Release) + git SHA | Debug, re-baselined to ccf612b (2026-07-23 build session) |
| Transports present | Dongle (2.4GHz) |
| Other mouse software running? | none reported |
| Backup pointer type | built-in trackpad |

### Sign-off

| Role | Name | Date | Signature / OK |
|------|------|------|----------------|
| Operator | xk | 2026-07-23 | OK |
| Reviewer (optional) | | | |

**I confirm:** backup pointer was available; permissions were granted; a known-good profile was used; results above are accurate; Skips include reasons; conflicts with other control software were recorded rather than silently worked around.

---

## Related docs

- [`cgevent-remapper-acceptance.md`](cgevent-remapper-acceptance.md) — full remapper button/scroll/pause matrix  
- [`driverkit-spike.md`](driverkit-spike.md) — DriverKit ownership spike (out of scope for this matrix)  
- Plan: `docs/plans/2026-07-18-reliability-and-status-ux-improvements.md`
