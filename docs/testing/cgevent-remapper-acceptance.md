# CGEvent Remapper — Manual Acceptance

**Status:** automated regression verified in-repo; physical matrix **not yet run** — operator fill-in and sign-off still required before closing the continuation plan.

**Scope:** session-wide software remapping via `CGEvent` (not Razer-only).

**Not in scope:** DriverKit exclusive ownership — see [`driverkit-spike.md`](driverkit-spike.md) and [GitHub issue #2](https://github.com/WXK-AI/razer-viper-control/issues/2).

Use this checklist before treating a remapper change as release-ready. Automated tests cover engine state, recovery, scroll precision, and diagnostics coalescing; they do **not** replace physical pointer verification.

## Prerequisites

1. macOS 13+ on Apple Silicon, Debug or Release `RazerMenuBarApp`.
2. Razer Viper V3 HyperSpeed (`1532:00B8`) connected.
3. Built-in or external **trackpad** and a **second mouse** available for the scope check.
4. **Input Monitoring** and **Accessibility** granted to `RazerMenuBarApp`.
5. Settings → Profile: remapper enabled on the active profile after permissions are ready.
6. Know the emergency pause shortcut: **⌃⌥⌘R**.

## Automated regression (required)

```bash
swift test --disable-sandbox
# Optional app build:
make xcode   # if project.yml changed since last generate
xcodebuild -scheme RazerMenuBarApp -configuration Debug \
  -derivedDataPath build/ReviewDerivedData build
git diff --check
git status --short
```

Record (automated portion, 2026-07-12; re-run `git diff --check` after any doc edit):

| Check | Result | Notes |
|-------|--------|-------|
| `swift test --disable-sandbox` | Pass | 158/158 |
| `xcodebuild` Debug `RazerMenuBarApp` | Pass | `-derivedDataPath build/ReviewDerivedData`; also `make xcode` Debug build |
| `git diff --check` | Pass | Must stay clean on the committed tree (no trailing whitespace) |
| Worktree clean of unrelated/generated noise | Pass | Acceptance docs only; `*.xcodeproj` / `build/` ignored |

## Manual matrix

Fill **Pass / Fail / Skip** and a short note. Failures that leave a button held, break scroll sign, or omit the session-wide disclosure are release blockers.

### A. Buttons and drag

| # | Case | Setup | Expected | Result | Notes |
|---|------|-------|----------|--------|-------|
| A1 | Normal left/right click | Default left→left, right→right | Clicks work in Finder/TextEdit | | |
| A2 | Hold left | Hold ≥1s then release | Down held for duration; up on release; no stuck button | | |
| A3 | Left drag | Click-drag a window or selection | Drag follows remapped target; up ends drag | | |
| A4 | Swap L/R | Left→right, right→left | Primary/secondary roles swapped; drag uses down-time mapping | | |
| A5 | Many-to-one | Side1 and Side2 both→left | Either side depresses left; both ups required before left releases (refcount) | | |
| A6 | Side buttons | Side1 / Side2 → mouse or shortcut | Action fires on down for one-shot; mouse targets balance up | | |
| A7 | Wheel click | Wheel click → middle or remap | Middle/alias behavior matches mapping; no duplicate click storm | | |
| A8 | Disabled control | Map a button to disabled/consume | No OS click; no stuck synthetic output | | |
| A9 | One-shot on down | Button → shortcut / next DPI / next profile | Fires once on down; not on up; no held synthetic key/button | | |
| A10 | Profile change while held | Hold remapped mouse button, switch profile (mappings change) | Remapper releases held synthetic outputs immediately (`.profileReplacement`); no orphan held button; later presses use the new profile | | |

### B. Wheel

| # | Case | Setup | Expected | Result | Notes |
|---|------|-------|----------|--------|-------|
| B1 | Vertical scroll | Multiplier 1.0, natural direction | Smooth scroll in a long document; sign matches hardware | | |
| B2 | Slow multiplier | Multiplier ~0.25–0.5 | Slower than 1.0; residual does not invert sign spuriously | | |
| B3 | Fast multiplier | Multiplier ~2.0–3.0 | Faster scroll; still usable | | |
| B4 | Direction reverse | Invert vertical | Opposite sign vs B1; reversing mid-gesture clears residual (no jump the wrong way) | | |
| B5 | Shift-horizontal | Hold Shift + vertical wheel | Horizontal pan; vertical and horizontal accumulators stay independent | | |
| B6 | Scroll → button/one-shot | Wheel up/down mapped to action | Mapping applies; disable path consumes without posting wrong axis | | |

### C. Pause, permissions, tap recovery

| # | Case | Setup | Expected | Result | Notes |
|---|------|-------|----------|--------|-------|
| C1 | Emergency pause | Enable remapper, press **⌃⌥⌘R** | Remapping stops; Settings shows paused; held synthetics released | | |
| C2 | Resume after pause | Resume from Settings / status | Remapping works again without reboot | | |
| C3 | Permission loss | Revoke Accessibility or Input Monitoring while running | Remapper stops; held outputs released; UI explains missing permission | | |
| C4 | Re-grant permissions | Restore both permissions, re-enable | Remapper starts; status returns to running | | |
| C5 | Tap disable recovery | Force tap disable if reproducible (timeout / user input) | Held outputs released; recovering/running status updates; remapping continues or recovers without stuck buttons | | |
| C6 | Disable remapper in profile | Turn off software remapper | Tap inactive; trackpad/second mouse unaffected by remaps | | |

### D. Session-wide scope (known limitation)

These rows document **expected** global behavior. Passing them means the limitation is observed and disclosed — not that remapping is device-local.

| # | Case | Setup | Expected | Result | Notes |
|---|------|-------|----------|--------|-------|
| D1 | Trackpad while remapper on | Swap L/R or aggressive scroll map | Trackpad clicks/scrolls follow the same software maps | | |
| D2 | Second mouse while remapper on | Use non-Razer mouse | Second mouse is remapped the same way | | |
| D3 | UI disclosure | Settings remapper section | Session-wide / not Razer-only limitation is visible before or while enabling | | |
| D4 | Remapper off | Disable remapper | Trackpad and second mouse return to normal OS behavior | | |

**Do not** treat D1–D2 failures of “Razer-only remapping” as DriverKit acceptance criteria. Device-local remapping remains deferred to issue #2.

### E. Diagnostics (memory-only)

| # | Case | Setup | Expected | Result | Notes |
|---|------|-------|----------|--------|-------|
| E1 | Enable capture | Diagnostics → enable input capture | Entries appear for physical mouse/scroll; capped list | | |
| E2 | Remap dispositions | With remaps active | Entries show remapped/consumed/passthrough; remapped ≠ synthetic | | |
| E3 | Fast scroll burst | Scroll quickly with capture on | UI stays responsive; log does not grow without bound | | |
| E4 | Clear | Clear capture | List empties and stays empty until new input | | |
| E5 | Disable capture | Turn capture off | No further growth; no disk log files created by capture | | |

### F. Hardware vs software labeling

| # | Case | Expected | Result | Notes |
|---|------|----------|--------|-------|
| F1 | DPI / polling apply | Affects only `1532:00B8` | | |
| F2 | Software remaps | Affect session pointers while enabled | | |
| F3 | Status row | Distinguishes missing perms / paused / running / recovering as applicable | | |

## Capture log (operator)

```
Date:
macOS:
App build / git SHA:
Devices: Viper / trackpad / second mouse:
Automated suite:
Manual blockers (if any):
```

## Sign-off

| Role | Name | Date | Verdict |
|------|------|------|---------|
| Operator | | | Accept / Accept with notes / Reject |

Reject if any of A2–A5, A10, B4–B5, C1, C3, or E4 fail, or if session-wide scope is undocumented in the UI (D3).

The continuation plan stays **pending** until this sign-off row is filled after a physical run.
