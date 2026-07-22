# Safety and Security Review

## Executive summary

The project has strong defensive work around malformed HID responses, stuck synthetic mouse buttons, corrupt profile recovery, generation-gated hardware applies, session-only remapper arming, bounded event-tap recovery, and validated profile I/O. I did not find an obvious remote-code-execution path, active direct workflow `run:`-block shell injection, or cross-device HID write in the current tree.

Active high-severity issues are on the **distribution and remaining release-supply-chain** boundary: public ad-hoc / non-notarized binaries that ask for Input Monitoring and Accessibility (and then perform session-wide `CGEvent` synthesis), plus mutable GitHub Action major tags and an XcodeGen download/install path without checksum verification. Five earlier runtime findings are withdrawn with current-code evidence below. A previously identified release-workflow tag-injection path is remediated in the current uncommitted workspace; residual risk is external (immutable/protected tag rulesets and hosted-runner verification), not an open in-repo `run:` interpolation bug.

Recommended order: Developer ID signing/notarization and release supply-chain hardening first (including SAF-008 credential transport), then optional SAF-005 mapping-summary on the existing explicit arm path. Defer Keychain/HMAC profile sealing until a stable Developer ID signing identity exists.

## Scope and method

Reviewed (live tree, including current uncommitted release scripts/workflow):

- `Sources/RazerCore/` HID protocol, response validation, profiles, remapper, capture, permissions, and recovery
- `RazerMenuBarApp/` lifecycle, UI, persistence triggers, privileged actions
- `Sources/RazerProbeCLI/`, `RazerHIDDriver/`
- `.github/workflows/release.yml`, `scripts/` release/signing/validation helpers, tests, and safety documentation

### Verification (distinguish pre-fix vs current shell evidence)

**Already rerun before the shell-only release-workflow fix (Swift/app):**

- `swift test --disable-sandbox`: **243/243** passed, 0 failures
- `xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build`: succeeded

**Current shell verification (after the shell-only fix, this report pass):**

- Bash 3.2 syntax: **13/13** `bash -n scripts/*.sh` passed
- Three standalone shell suites passed: `scripts/test-release-tag-validator.sh`, `scripts/test-exact-ls-remote-ref.sh`, `scripts/test-workflow-run-interpolation-checker.sh`
- Valid release contract: `bash scripts/verify-release-contract.sh` passed (artifact checks and ShellCheck skipped locally)
- Malicious sentinel contract: `RELEASE_TAG='v1.0.0$(touch …)' bash scripts/verify-release-contract.sh` failed safely; **no sentinel file created**
- Workflow YAML: `.github/workflows/release.yml` parses (Ruby `YAML.load_file`)
- `git diff --check`: clean

**Not available / not run locally:**

- ShellCheck and actionlint unavailable in this environment
- Hosted GitHub Actions release job was not executed

The available security-review reference pack has no Swift/macOS-specific guidance, so severity is based on privilege and failure boundaries in this repository.

Finding IDs stay stable: **SAF-001, SAF-002, SAF-005, SAF-008** are active. **SAF-003, SAF-004, SAF-006, SAF-007** are withdrawn/remediated history (see below). Old SAF-005 “no validation” claims are withdrawn; the ID is reused for the narrower residual.

## SAF status ledger (2026-07-22)

| SAF ID | Status | Notes |
|--------|--------|-------|
| SAF-001 | **Mitigated pending Developer ID** | Public release publication paused; test artifacts remain ad-hoc signed. Closure requires a notarized public artifact passing `spctl` on a clean Mac. |
| SAF-002 | **Mitigated** | Top-level `contents: read`, `persist-credentials: false`, no tag push, no publisher. Open sub-items: actions not SHA-pinned, XcodeGen lacks SHA-256 verification. |
| SAF-003 | **Resolved** | Generation-gated applies + skip-unchanged planner. |
| SAF-004 | **Resolved** | Default-off `remapperEnabled`; session-only `remapperArmed`. |
| SAF-005 | **Mitigated** | Strict validation, owner-only writes, quarantine, session arming. Residual: no external-change mapping summary; Keychain/HMAC deferred. |
| SAF-006 | **Resolved** | Deferred workspace actions + tap-disable circuit breaker. |
| SAF-007 | **Resolved** | 1 MiB source cap + semantic limits. |
| SAF-008 | **Resolved** | `NOTARY_KEYCHAIN_PROFILE` + `--keychain-profile` only; password removed from argument list. |

## High severity

### SAF-001 — Ad-hoc public distribution meets session-wide CGEvent remapping

Public installs still ship **ad-hoc signed, non-notarized** binaries and document Gatekeeper bypass before granting Input Monitoring and Accessibility (`README.md:50-67`, `.github/workflows/release.yml:291-296`).

Once armed, the remapper installs a session event tap and posts synthetic HID-level mouse and keyboard events globally—not only Razer hardware:

- Tap creation over mouse/scroll/key-down masks: `Sources/RazerCore/InputRemapper.swift:146-183`
- Synthetic mouse button/drag posts via `CGEvent` + `cgEvent.post(tap: .cghidEventTap)`: `Sources/RazerCore/InputRemapper.swift:711-753`
- Synthetic keyboard shortcut posts: `Sources/RazerCore/InputRemapper.swift:776-787`

Impact: users cannot authenticate the publisher through Developer ID/notarization at the point they are trained to bypass Gatekeeper for a binary that can observe and inject session-wide input.

The published `SHA256SUMS.txt` does not close the publisher-trust gap because it is produced and attached by the same release job (`.github/workflows/release.yml:125-132`, `.github/workflows/release.yml:272-283`).

Recommendation:

1. Make Developer ID signing, hardened runtime, notarization, stapling, and `spctl` verification mandatory for the official end-user asset.
2. If ad-hoc builds remain, label them as developer/test-only and stop instructing general users to bypass Gatekeeper.
3. Publish provenance/attestations in addition to checksums.

### SAF-002 — Remaining release supply-chain gaps (mutable actions; unverified XcodeGen)

**Still open (this finding):**

1. Actions pinned only to mutable major tags: `actions/checkout@v4` (`.github/workflows/release.yml:27`) and `softprops/action-gh-release@v2` (`.github/workflows/release.yml:273`).
2. XcodeGen ZIP download/install without digest/signature verification (`.github/workflows/release.yml:100-105`), then version-gated execution via `scripts/generate-xcodeproj.sh:12-31` (invoked from `scripts/ci-release-build.sh:40`). The script checks the installed version string against `REQUIRED_XCODEGEN_VERSION` but does **not** verify the downloaded archive checksum before `sudo cp` / `xcodegen generate`.

Workflow-scoped `contents: write` (`.github/workflows/release.yml:15-17`) remains the privilege context that makes a compromised action or build tool able to push tags or replace release assets.

**Already present (do not treat as missing):**

- Clean-worktree requirement for release builds (`scripts/ci-release-build.sh:12-22`, re-check `scripts/ci-release-build.sh:97-98`)
- Artifact / `BUILD_REVISION` contracts when `VERIFY_RELEASE_ARTIFACTS=1` (`scripts/verify-release-contract.sh:103-171`)
- Exact `vMAJOR.MINOR.PATCH` tag validation (`scripts/validate-release-tag.sh:9-15`; workflow call sites `.github/workflows/release.yml:53`, `:64`, `:144`)
- Env-based context passing into `run:` blocks (no direct `${{ … }}` interpolation in run scripts; checker `scripts/check-workflow-run-interpolation.sh`, enforced from `scripts/verify-release-contract.sh:71-77`)
- Original tag-object capture, exact remote-ref parser, deferred non-force push, and unconditional final tag identity verification (`.github/workflows/release.yml:73-97`, `:134-269` covering existing- and new-tag branches; parser `scripts/parse-exact-ls-remote-ref.sh:9-25`)

Recommendation:

1. Pin every action to a reviewed full commit SHA (comment the human-readable version).
2. Verify XcodeGen against a repository-controlled SHA-256 before extract/`sudo`/execution, or use a pre-approved immutable tool image.
3. Optionally split build (`contents: read`, `persist-credentials: false`) from a minimal publish job (`contents: write`).
4. Add repository tag protection / immutable-tag rulesets (see residual below).

## Low severity / hardening

### SAF-005 — Narrow same-user profile integrity residual

**Controls that exist today:**

- **Source checks:** `O_NOFOLLOW` open, regular-file / owner / size (1 MiB) validation (`Sources/RazerCore/ProfileSafetyValidator.swift:248-276`, `:364-407`; load `Sources/RazerCore/ProfileStore.swift:350-361`)
- **Owner-only writes:** profile files are written as owner-only regular files (`Sources/RazerCore/ProfileSafetyValidator.swift:278-318`)
- **Semantic validation:** profile count/names, hardware ranges, shortcut masks/key codes, HTTP(S) URLs, absolute `.app` bundles (`Sources/RazerCore/ProfileSafetyValidator.swift:409-556`; save `Sources/RazerCore/ProfileStore.swift:414-427`)
- **Quarantine / write blocking:** unsafe source, malformed JSON, or failed semantic validation quarantine and recover; quarantine failure blocks later writes (`Sources/RazerCore/ProfileStore.swift:357-385`, `:492-512`)
- **Startup load:** `AppModel` loads via `profileStore.loadOutcome()` and surfaces recovered/corrupt-preserved warnings; it does **not** auto-arm remapping (`RazerMenuBarApp/AppModel.swift:109-137`, `:92-93`)
- **Defaults:** `remapperEnabled` defaults / decode-missing / reset are `false` (`Sources/RazerCore/ProfileStore.swift:30`, `:54`, `:79`)
- **Session arming:** `@Published var remapperArmed = false` is session-only and resets every launch; enabling requires explicit confirmation; permission loss clears arming; `syncRemapper` requires both `remapperEnabled` and `remapperArmed` (`RazerMenuBarApp/AppModel.swift:92-93`, `:268-275`, `:708-746`, `:904-921`)

**Residual (supported):** a same-user writer of the owner-only Application Support profile (`Sources/RazerCore/ProfileSafetyValidator.swift:278-318`) can plant a **semantically valid** action-bearing profile. That planted content still needs a later **explicit user arm** (`armRemapperForSession`) before the remapper runs—session arming already resets every launch. There is no external-change detection or mapping-summary shown as part of that existing arm action when startup-loaded action content was changed externally or `remapperEnabled` is already true.

Recommendation:

1. When startup-loaded action-bearing content is externally changed or already enabled, show a mapping summary as part of the existing explicit arm action (`armRemapperForSession` / confirmation UI)—do not add a separate session re-arm mechanism.
2. Defer Keychain/HMAC integrity sealing until a stable Developer ID signing identity is in place for the official distribution path.

### SAF-008 — Notarization password appears on the `notarytool` argument list

`scripts/sign-release.sh` passes `APPLE_APP_PASSWORD` as `--password` to `xcrun notarytool submit` (`scripts/sign-release.sh:122-128`, flag at line 126). Process argument lists are visible to local inspection and some operational tooling. Documented env setup: `README.md:81-88`.

Recommendation: use `xcrun notarytool store-credentials` + `--keychain-profile`, or App Store Connect API-key auth in CI. Treat this as part of the signing/notarization workstream before optional profile hardening.

## Withdrawn findings (stale runtime claims)

IDs **SAF-003, SAF-004, SAF-006, SAF-007** (and the old SAF-005 “no validation” claim) are withdrawn/remediated history. The five stale runtime findings:

### 1. HID write flood / no coalescing — withdrawn (was SAF-003)

`updateProfile` / `updateDraft` only persist, refresh summary/warnings, and `syncRemapper`; they do **not** call `applySelectedProfile` (`RazerMenuBarApp/AppModel.swift:586-631`). Explicit applies issue a `LatestHardwareApplyGate` generation via `issue()` and recheck `isCurrent` before connect/apply (`RazerMenuBarApp/AppModel.swift:523-541`). Reconnect auto-apply snapshots `currentGeneration()` at schedule time and honors/rechecks that generation before and during apply (`RazerMenuBarApp/AppModel.swift:290-303`, `:426-445`; gate API `Sources/RazerCore/HardwareApplyPolicy.swift:62-87`). This is **generation-gated** stale-apply rejection, not a separate coalescing queue that merges edits into one write batch.

### 2. Remapper auto-activation — withdrawn (was SAF-004)

Defaults and reset keep `remapperEnabled = false` (`Sources/RazerCore/ProfileStore.swift:30`, `:54`, `:79`). UI enablement routes through confirmation and `armRemapperForSession` (`RazerMenuBarApp/AppModel.swift:708-746`, `RazerMenuBarApp/SettingsView.swift:303-318`). Permission loss clears `remapperArmed`; restoration alone does not re-arm (`RazerMenuBarApp/AppModel.swift:268-275`, `:912-920`).

### 3. Absent profile semantic/source validation — withdrawn (old SAF-005 claim)

Source opens use `O_NOFOLLOW` plus regular-file/owner/size checks; decode is followed by `validateAndRepair`; failures quarantine (`Sources/RazerCore/ProfileSafetyValidator.swift:248-276`, `:409-556`; `Sources/RazerCore/ProfileStore.swift:350-385`). Retained SAF-005 above is only the same-user integrity / explicit-arm residual.

### 4. Synchronous LaunchServices on the event tap / no timeout circuit breaker — withdrawn (was SAF-006)

`openApp` / `openURL` schedule `DeferredWorkspaceAction` on the main queue asynchronously (`Sources/RazerCore/InputRemapper.swift:14-47`, `:546-553`). Tap-disable recovery uses `TapDisableCircuitBreaker` and fails closed after repeated timeouts (`Sources/RazerCore/TapDisableCircuitBreaker.swift:4-34`, `Sources/RazerCore/InputRemapper.swift:287-319`, `RazerMenuBarApp/AppModel.swift:865-872`).

### 5. Unbounded profile input — withdrawn (was SAF-007)

Reads enforce a 1 MiB source cap before consuming bytes and post-decode limits on profile count/names/URLs/paths (`Sources/RazerCore/ProfileSafetyValidator.swift:3-12`, `:248-276`, `:364-407`, `:409-434`).

## Remediated: workflow `run:`-block tag injection (not an active finding)

There is **no active direct workflow `run:`-block shell injection** claim against the current tree. The following remediate the previously found path:

- Exact `vMAJOR.MINOR.PATCH` validator (`scripts/validate-release-tag.sh:9-15`)
- Env-based context passing into release `run:` steps (`.github/workflows/release.yml:34-54`, `:58-64`, `:135-144`)
- Run-block interpolation checker + fixtures (`scripts/check-workflow-run-interpolation.sh`, `scripts/test-workflow-run-interpolation-checker.sh`; contract `scripts/verify-release-contract.sh:64-77`)
- Original tag-object capture (`.github/workflows/release.yml:73-97`)
- Exact remote ref parser (`scripts/parse-exact-ls-remote-ref.sh:9-25`; workflow `:162-183`)
- Deferred non-force push and unconditional final tag identity verification for both existing- and new-tag branches (`.github/workflows/release.yml:134-269`)

**External residual (not claimed as an open in-repo injection):** enforce immutable/protected GitHub tag rulesets, and rely on hosted-runner verification (ShellCheck/actionlint/CI release job) rather than local-only checks.

## Positive controls observed

- HID discovery/writes restricted to the target vendor/product interface (`Sources/RazerCore/HIDDeviceDiscovery.swift:71-95`)
- Fixed-length responses validated for CRC, IDs, status, and data size (`Sources/RazerCore/RazerCommandClient.swift:393-406`, `Sources/RazerCore/RazerResponseValidator.swift:4-65`)
- DPI/polling validated before command construction (`Sources/RazerCore/RazerReport.swift:174-186`, `:254-257`, `:428-446`)
- Generation-gated hardware applies; software-only edits do not apply HID (`RazerMenuBarApp/AppModel.swift:523-541`, `:586-631`, `Sources/RazerCore/HardwareApplyPolicy.swift:62-87`)
- Remapper defaults off; session arming explicit (`Sources/RazerCore/ProfileStore.swift:30-54`, `RazerMenuBarApp/AppModel.swift:92-93`, `:708-746`)
- Profile I/O: `O_NOFOLLOW`, owner/size checks, semantic validation, quarantine (`Sources/RazerCore/ProfileSafetyValidator.swift`, `Sources/RazerCore/ProfileStore.swift:350-385`)
- Deferred `NSWorkspace` work; tap-disable circuit breaker fails closed (`Sources/RazerCore/InputRemapper.swift:38-47`, `:287-319`)
- Held synthetic buttons released on pause, stop, permission loss, **profile replacement**, and tap disable; recovery mouse-ups are posted in `publishHeldOutputRelease` (`Sources/RazerCore/InputRemapper.swift:82-114`, `:117-143`, `:196-203`, `:287-319`, `:366-388`)
- Emergency pause consumes the triggering key-down (`Sources/RazerCore/InputRemapper.swift:426-429`)
- Diagnostic capture: mouse/scroll only, bounded-entry enforcement, coalesced UI publish (`Sources/RazerCore/InputCaptureSession.swift:108-141`, `:208-217`, `:306-339`)
- Diagnostic hardware mutations restore independently (`Sources/RazerCore/HardwareStateTransaction.swift:103-188`, `:192-337`)
- HTTP(S)-only URL actions (`Sources/RazerCore/InputRemapperEngine.swift:304-320`)
- Release clean-tree / revision / path-safety contracts (`scripts/ci-release-build.sh:12-40`, `:97-131`, `scripts/package-dmg.sh:67-85`)

## Suggested remediation sequence

1. **SAF-001 + SAF-002 + SAF-008:** trusted signing/notarization path, pin actions + checksum XcodeGen, move notarization credentials off the process argument list, and add protected/immutable tag rulesets for the external residual.
2. **SAF-005 (optional):** show a mapping summary in the existing explicit arm action when startup-loaded action content is externally changed or already enabled; defer Keychain/HMAC until Developer ID identity is stable.
