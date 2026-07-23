# Safety Hardening — Acceptance Record

**Status:** Tasks 1–8 implemented and verified (see `docs/plans/2026-07-12-safety-release-hardening.md` rev 2). Physical acceptance **passed** 2026-07-23 (operator xk). This document records the acceptance evidence for the complete hardening set and tracks residual items that remain open.

**Plan reference:** [`docs/plans/2026-07-12-safety-release-hardening.md`](../plans/2026-07-12-safety-release-hardening.md)
**Security report:** [`security_best_practices_report.md`](../../security_best_practices_report.md)

---

## 1. Default-off / session arming (`remapperArmed` / `confirmArmRemapper`)

**Behavior:** Software remapping is never active at launch, after upgrade, after recovery, or after permission restoration. A profile-level `remapperEnabled` preference is necessary but not sufficient; the user must also explicitly arm the remapper for the current login session via a confirmation dialog.

**Implementation evidence:**
- `Sources/RazerCore/ProfileStore.swift` — `remapperEnabled` defaults to `false` in initializer, missing-field decoder, and reset paths.
- `RazerMenuBarApp/AppModel.swift` — `@Published var remapperArmed = false` is session-only, never persisted, and resets every launch.
- `syncRemapper` requires **all three**: `remapperEnabled`, `remapperArmed`, and permissions ready.
- Permission restoration clears `remapperArmed`; it does **not** re-arm.
- `SettingsView` / `RazerMenuBarApp` present the session-wide warning and an explicit **Arm Remapper** action.

**Verification:**
- `swift test --disable-sandbox --filter ProfileSchemaTests` — schema default/migration/reset assertions.
- `swift test --disable-sandbox --filter MouseProfileMigrationTests` — legacy decode defaults.
- `swift test --disable-sandbox --filter ControlModelsTests` — runtime state transitions.

---

## 2. Permission versus consent

**Behavior:** TCC permission grants (Input Monitoring, Accessibility) are treated as **prerequisites**, not as **consent**. Granting or restoring permissions never starts the remapper. Consent is a separate, explicit, session-scoped user action.

**Implementation evidence:**
- `RazerMenuBarApp/AppModel.swift` — `syncRemapper` checks permissions independently of `remapperArmed`.
- `PermissionStatus.swift` — permission changes clear `remapperArmed` and pause the remapper; they never set it.
- The UI distinguishes `.awaitingConsent` (permissions ready, remapper not armed) from permission-missing states.

**Verification:**
- `swift test --disable-sandbox --filter InputRemapperRecoveryTests` — permission loss/recovery paths.
- Manual matrix row C3/C4 in `cgevent-remapper-acceptance.md` (physical verification still open).

---

## 3. Hardware mutation triggers (`HardwareApplyPolicy`, skip-unchanged)

**Behavior:** Ordinary profile edits (name, mappings, software wheel, remapper toggle) perform **zero** HID writes. Hardware is mutated only for explicit Apply, profile selection, DPI/profile cycling, or reconnect auto-apply. Queued applies are generation-gated so stale snapshots never begin writing. When an apply does run, unchanged fields are skipped entirely.

**Implementation evidence:**
- `Sources/RazerCore/HardwareApplyPolicy.swift` — `HardwareProfileSettings` isolates hardware-affecting fields; `LatestHardwareApplyGate` issues and validates generation tokens.
- `Sources/RazerCore/HardwareProfileApplier.swift` — pure planner computes a `HardwareApplyPlan`; equal profiles produce zero setter calls.
- `RazerMenuBarApp/AppModel.swift` — `updateProfile`/`updateDraft` no longer call `applySelectedProfile`; explicit applies issue gate tokens and recheck `isCurrent` before connect and before `session.apply`.
- `Sources/RazerCore/ProfileStore.swift` — `DeviceSession.apply` reads current state once, plans, and executes only differing writes.

**Verification:**
- `swift test --disable-sandbox --filter HardwareApplyPolicyTests` — policy equality and gate concurrency.
- `swift test --disable-sandbox --filter HardwareProfileApplierTests` — per-flag planning and zero-write fake-mutator case.
- `swift test --disable-sandbox --filter HardwareStateTransactionTests` — diagnostic restore independence.

---

## 4. Repeated-timeout circuit breaker pause

**Behavior:** The first two event-tap disables within 10 seconds may recover. The third opens the circuit: held synthetic outputs are released, the tap is disabled, the remapper pauses, and explicit re-arm is required. A quiet 10-second window resets the count.

**Implementation evidence:**
- `Sources/RazerCore/TapDisableCircuitBreaker.swift` — pure state machine with injected monotonic timestamps.
- `Sources/RazerCore/InputRemapper.swift` — tap-disable recovery routes through the breaker; `.pausedAfterRepeatedTimeouts` status surfaced.
- `RazerMenuBarApp/AppModel.swift` — status mapped to user-visible pause message.

**Verification:**
- `swift test --disable-sandbox --filter TapDisableCircuitBreakerTests` — deterministic breaker transitions.
- `swift test --disable-sandbox --filter InputRemapperRecoveryTests` — third rapid disable releases holds and does not re-enable.

---

## 5. Invalid-profile behavior (`ProfileSafetyValidator`, guided quarantine restore)

**Behavior:** Profile files are validated before reading (regular file, non-symlink, owner-only, ≤ 1 MiB) and after decoding (count, names, hardware ranges, shortcut masks, URLs, app paths). Structural, ownership, symlink, size, or semantic failures quarantine the source and load safe in-memory defaults with remapping off. If safe quarantine fails, writes are blocked and the source is preserved.

**Implementation evidence:**
- `Sources/RazerCore/ProfileSafetyValidator.swift` — `ProfileSafetyLimits`, source checks (`O_NOFOLLOW`, regular-file/owner/size), semantic validation, and repair rules.
- `Sources/RazerCore/ProfileStore.swift` — load and save both call the same validator; quarantine/recovery paths preserve mappings and keep remapping off.
- Intentional deviation: dangling/invalid `selectedProfileID` is repaired to the first profile rather than quarantining an otherwise valid file.

**Verification:**
- `swift test --disable-sandbox --filter ProfileSafetyValidatorTests` — every limit, duplicate IDs, invalid selection, shortcuts, URLs, app paths, symlinks, ownership, size, and POSIX modes.
- `swift test --disable-sandbox --filter ProfileStoreRecoveryTests` — quarantine, write blocking, and default recovery.

---

## 6. Paused public binary releases

**Behavior:** Public GitHub Release publication is **disabled**. The `release.yml` workflow is a read-only test-package artifact producer: it validates tags and builds unsigned/unnotarized packages, but never pushes tags, never creates releases, and never exposes artifacts to end users.

**Implementation evidence:**
- `.github/workflows/release.yml` — top-level `permissions: contents: read`, `persist-credentials: false`, no tag push step, no GitHub Release publisher step.
- The workflow still runs on `push: tags: "v*"` and `workflow_dispatch` to validate release packaging, but all outputs remain runner-local.
- `scripts/verify-release-contract.sh` enforces the no-publisher, read-only contract.

**Verification:**
- `bash scripts/verify-release-contract.sh` — passes with 5 release-quarantine contracts.

---

## 7. Test-artifact limitations

**Behavior:** CI produces ad-hoc signed, non-notarized test artifacts only. These are **not** recommended for public installation.

**Closed sub-items (`fc76838`):**
- [x] `UNNOTARIZED_TEST_BUILD.txt` marker is included in DMG staging (`scripts/package-dmg.sh`), `build/Release`, both zip archives, and `SHA256SUMS.txt`.
- [x] Actions pinned to full commit SHAs (`actions/checkout@11d5960a326750d5838078e36cf38b85af677262` # v4) in `ci.yml` and `release.yml`.
- [x] XcodeGen 2.45.4 download SHA-256-verified (`XCODEGEN_SHA256` + `shasum -a 256 -c`), job-local `mktemp` dir, no `sudo`.
- [x] `ci.yml` top-level `permissions: contents: read` and `persist-credentials: false` on both checkouts.

**Verification:**
- `bash scripts/verify-release-contract.sh` — enforces marker presence, SHA-pinned actions, XcodeGen digest verification, no sudo-install of xcodegen, and `ci.yml` permissions / `persist-credentials` (`fc76838`).

---

## SAF ledger

| SAF ID | Title | Status | Verification evidence |
|--------|-------|--------|----------------------|
| **SAF-001** | Ad-hoc public distribution meets session-wide CGEvent remapping | **Mitigated pending Developer ID** | Public release publication paused (`release.yml` read-only, no publisher). Test artifacts remain ad-hoc signed. **Closure condition:** a notarized public artifact passes `spctl --assess --type execute --verbose=4` on a clean Mac. |
| **SAF-002** | Remaining release supply-chain gaps (deferred trusted publish) | **Mitigated** | Top-level `contents: read`, `persist-credentials: false`, no tag push, no release publisher. Actions SHA-pinned; XcodeGen SHA-256-verified; marker in DMG/zips/`SHA256SUMS.txt` (`fc76838`). **Residual:** deferred trusted publish / Developer ID path. |
| **SAF-003** | HID write flood / no coalescing | **Resolved** | `HardwareApplyPolicy` + `LatestHardwareApplyGate` generation-gated applies; `HardwareProfileApplier` skip-unchanged planner. Tests: `HardwareApplyPolicyTests`, `HardwareProfileApplierTests`. |
| **SAF-004** | Remapper auto-activation | **Resolved** | `remapperEnabled` defaults `false`; session-only `remapperArmed`; permission restoration never re-arms. Tests: `ProfileSchemaTests`, `MouseProfileMigrationTests`, `ControlModelsTests`. |
| **SAF-005** | Same-user profile integrity residual | **Mitigated** | Strict source/semantic validation, owner-only writes, quarantine, session arming. **Residual:** no external-change detection or mapping summary on the explicit arm path; Keychain/HMAC sealing deferred until stable Developer ID identity exists. |
| **SAF-006** | Synchronous LaunchServices on event tap / no timeout circuit breaker | **Resolved** | `DeferredWorkspaceAction` queues `NSWorkspace` calls on main; `TapDisableCircuitBreaker` bounds recovery. Tests: `InputRemapperRecoveryTests`, `TapDisableCircuitBreakerTests`. |
| **SAF-007** | Unbounded profile input | **Resolved** | 1 MiB source cap, regular-file/owner/size checks, post-decode semantic limits. Tests: `ProfileSafetyValidatorTests`, `ProfileStoreRecoveryTests`. |
| **SAF-008** | Notarization password on `notarytool` argument list | **Resolved** | `scripts/sign-release.sh` uses `NOTARY_KEYCHAIN_PROFILE` + `--keychain-profile` only; safe early exit without credentials. Contracts in `verify-release-contract.sh` reject `--password`. |

---

## Automated verification commands

```bash
swift test --disable-sandbox
bash -n scripts/*.sh
bash scripts/verify-release-contract.sh
shellcheck -x scripts/*.sh
```

## Manual acceptance (physical device)

Physical matrix run **2026-07-23** — **PASSED** (all sections A–F). Full results, capture log, and operator sign-off are recorded in [`cgevent-remapper-acceptance.md`](cgevent-remapper-acceptance.md).

## Sign-off

| Role | Name | Date | Verdict |
|------|------|------|---------|
| Implementer | | | Accept / Accept with notes / Reject |
| Operator (physical) | xk | 2026-07-23 | Accept |
