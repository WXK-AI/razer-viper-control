# Safety Hardening — Acceptance Record

**Status:** Tasks 1–8 implemented and verified (see `docs/plans/2026-07-12-safety-release-hardening.md` rev 2). Physical acceptance **passed** 2026-07-23 (operator xk). This document records the acceptance evidence for the complete hardening set and tracks residual items that remain open. **Release posture changed 2026-07-23 (`40a6ccd`): public unnotarized prereleases are now published on every `v*` tag — see § 6 and SAF-001.**

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

## 6. Public unnotarized prereleases

> **Reversed 2026-07-23 (`40a6ccd`).** This section previously recorded paused public releases. Publication is no longer paused.

**Behavior:** `release.yml` publishes a **public GitHub Release marked `prerelease: true`** on every `v*` tag push, and on `workflow_dispatch` for a tag that already exists at the workflow commit. The assets are the same ad-hoc signed, **not notarized** packages CI has always built, so they are now downloadable by anyone without a login instead of only by authenticated maintainers. The workflow still never creates or pushes a tag — it fails if the tag does not already exist at the workflow commit.

**Residual risk (accepted, not closed):** unnotarized, ad-hoc-signed binaries of a **session-wide `CGEvent` remapper** are publicly downloadable, and users are told how to bypass Gatekeeper to launch them. Nothing below authenticates the publisher; the compensating controls are labeling, scoping, and provenance only. SAF-001 stays open until a notarized artifact passes `spctl` on a clean Mac.

**Compensating controls that actually exist:**
- `prerelease: true` — GitHub never serves the release as `/releases/latest`.
- Release title `<tag> (unnotarized test build)` and a body stating the build is not Developer ID signed and not notarized.
- `UNNOTARIZED_TEST_BUILD.txt` marker inside the DMG staging tree and both zip archives, hashed in `SHA256SUMS.txt`, and attached as a standalone release asset.
- Publisher SHA-pinned: `softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65` # v2, `fail_on_unmatched_files: true`.
- `persist-credentials: false` on checkout; the `contents: write` token is passed only to the pinned publisher step and to a read-only pre-publish probe (below) via `secrets.GITHUB_TOKEN` — a contract-enforced token allowlist rejects any other token-bearing step that could mutate refs or releases.
- A `Guard against clobbering an existing release` step runs before the publisher: it refuses to publish when the tag already has a release (or draft) that is not this workflow's own unnotarized prerelease, so a re-run can never silently replace a manually published notarized release's assets. It fails closed — an API or auth error blocks publishing rather than being read as "no release exists".
- Publisher **shape** is contract-enforced (including the guard step's presence and ordering), so the pin, the prerelease flag, and the guard cannot be dropped silently.

**Implementation evidence:**
- `.github/workflows/release.yml` — top-level `permissions: contents: write` (release assets) and `actions: write` (short-retention artifact); `persist-credentials: false`; no `git push`; `Publish unnotarized GitHub prerelease` step with `prerelease: true`.
- Assets: `RazerMenuBarApp-macOS.dmg`, `RazerMenuBarApp-macOS.zip`, `RazerProbeCLI-macOS.zip`, `SHA256SUMS.txt`, `UNNOTARIZED_TEST_BUILD.txt`. The 7-day `UNNOTARIZED-TEST-BUILD` Actions artifact is still uploaded alongside the release.
- `scripts/verify-release-contract.sh` now **requires** the publisher shape (SHA-pinned `softprops/action-gh-release` + `prerelease: true`) and still rejects mutable `@vN` pins, shell `gh release` / `actions/upload-release-asset`, persisted checkout credentials, and `git push`.
- `.github/workflows/ci.yml` is unchanged: top-level `contents: read`, no publisher.

**Verification:**
- `bash scripts/verify-release-contract.sh` — passes; the workflow authority-surface contracts (exact-set permissions, publisher shape + clobber guard, action pinning, ref-mutation scan) are section 8 of the script, backed by the structural checkers `scripts/check-release-publisher.sh` and `scripts/check-workflow-permissions.sh` and their fixture suites.

---

## 7. Test-artifact limitations

**Behavior:** CI produces ad-hoc signed, non-notarized artifacts only — including the ones now attached to the public prerelease (§ 6). They are **not** a Gatekeeper-clean distribution and are **not** recommended for general installation.

**Closed sub-items (`fc76838`):**
- [x] `UNNOTARIZED_TEST_BUILD.txt` marker is included in DMG staging (`scripts/package-dmg.sh`), `build/Release`, both zip archives, and `SHA256SUMS.txt`.
- [x] Actions pinned to full commit SHAs (`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` # v7.0.1) in `ci.yml` and `release.yml`.
- [x] XcodeGen 2.45.4 download SHA-256-verified (`XCODEGEN_SHA256` + `shasum -a 256 -c`), job-local `mktemp` dir, no `sudo`.
- [x] `ci.yml` top-level `permissions: contents: read` and `persist-credentials: false` on both checkouts.

**Verification:**
- `bash scripts/verify-release-contract.sh` — enforces marker presence, SHA-pinned actions, XcodeGen digest verification, no sudo-install of xcodegen, and `ci.yml` permissions / `persist-credentials` (`fc76838`).

---

## SAF ledger

| SAF ID | Title | Status | Verification evidence |
|--------|-------|--------|----------------------|
| **SAF-001** | Ad-hoc public distribution meets session-wide CGEvent remapping | **Open — exposure accepted pending Developer ID** | Since `40a6ccd`, `release.yml` publishes ad-hoc signed, **unnotarized** builds of a session-wide `CGEvent` remapper as a **public** GitHub prerelease on every `v*` tag; the publication pause that previously mitigated this finding is gone. Compensating controls are labeling/scoping only, not publisher authentication: `prerelease: true` (never served as `/releases/latest`), release title `<tag> (unnotarized test build)`, an explicitly not-notarized release body, `UNNOTARIZED_TEST_BUILD.txt` inside every archive, and `SHA256SUMS.txt` (same-job provenance, so it does not close the publisher-trust gap). **Closure condition:** a notarized public artifact passes `spctl --assess --type execute --verbose=4` on a clean Mac. |
| **SAF-002** | Remaining release supply-chain gaps (deferred trusted publish) | **Mitigated** | Publisher is SHA-pinned `softprops/action-gh-release@3bb1273` # v2 with `prerelease: true` and `fail_on_unmatched_files: true`; `contents: write` is granted only in `release.yml` and the token reaches only the pinned publisher step and the read-only clobber-guard probe (token allowlist contract-enforced); a pre-publish guard refuses to overwrite an existing non-prerelease or draft release for the tag; `persist-credentials: false` on every checkout; no `git push`; no shell `gh release` / `upload-release-asset`; `ci.yml` stays `contents: read` with no publisher. Actions SHA-pinned; XcodeGen SHA-256-verified; marker in DMG/zips/`SHA256SUMS.txt` (`fc76838`). Publisher shape is contract-enforced by `scripts/verify-release-contract.sh` (`40a6ccd`). **Residual:** `contents: write` is workflow-scoped rather than split into a separate protected publish job; deferred trusted publish / Developer ID path; tag immutability still relies on external GitHub rulesets. |
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
