# DriverKit Entitlements And Signing Gates

This document tracks the Apple Developer Program prerequisites for Razer-only remapping via a HID DriverKit system extension. It intentionally omits certificates, credentials, and provisioning profile files.

## Identifiers

| Target | Bundle ID | Notes |
|--------|-----------|--------|
| Host app | `com.razermenubar.RazerMenuBarApp` | Menu bar app; activates and talks to the extension |
| Driver extension | `com.razermenubar.RazerViperHIDDriver` | Sole owner of USB HID `1532:00B8` |

Team ID and signing identity are supplied at build time via CI secrets / local Keychain. Do not commit them.

## Required Entitlements

### Driver extension (`RazerViperHIDDriver`)

Request an entitlement group containing at least:

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.developer.driverkit` | DriverKit base |
| `com.apple.developer.driverkit.transport.hid` | HID transport matching |
| `com.apple.developer.driverkit.family.hid.eventservice` | HID event service / virtual HID output |
| Virtual-HID entitlement required by the final event-service design | Emit translated pointer/button/scroll events |

Exact virtual-HID key name is confirmed when Apple returns the approved entitlement group.

### Host app (`RazerMenuBarApp`)

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.developer.system-extension.install` | Activate / deactivate the embedded DriverKit extension |
| Restricted driver user-client access for `com.razermenubar.RazerViperHIDDriver` | App ↔ driver IPC |

## App IDs And Profiles

Create explicit App IDs and both development and Developer ID distribution profiles for:

1. `com.razermenubar.RazerMenuBarApp`
2. `com.razermenubar.RazerViperHIDDriver`

| Profile purpose | Expected name pattern | Status |
|-----------------|----------------------|--------|
| App development | `RazerMenuBarApp Development` | Not created |
| App Developer ID | `RazerMenuBarApp Developer ID` | Not created |
| Driver development | `RazerViperHIDDriver Development` | Not created |
| Driver Developer ID | `RazerViperHIDDriver Developer ID` | Not created |

Renewal dates: fill in after profiles are issued (typically one year from creation).

## Approval Status

| Gate | Status | Notes |
|------|--------|--------|
| Apple Developer Program membership | Assumed available | External release gate |
| Developer ID Application certificate | Pending verification | Required for notarized DMG |
| DriverKit entitlement group request | **Not submitted** | Submit via Apple Developer → Certificates, Identifiers & Profiles → Identifiers / Additional Capabilities, or the DriverKit entitlement request form |
| System extension install entitlement on host App ID | **Not enabled** | Enable after App ID exists |
| Development provisioning profiles selectable in Xcode | **Blocked** | Depends on entitlement approval |
| Distribution / notarization CI secrets | **Not configured** | Certificate, keychain password, profiles, Apple ID / app-specific password / Team ID |

Until the DriverKit entitlement group is approved, local work may use DriverKit developer mode for spike builds only. Ad-hoc signed builds cannot activate the extension for end users and are not a distributable substitute.

## Request Checklist (operator)

1. Confirm Team ID and Developer ID Application certificate in Keychain.
2. Register App IDs for host and driver if missing.
3. Request the DriverKit entitlement group listed above for the driver App ID.
4. Enable `com.apple.developer.system-extension.install` (and restricted user-client access) on the host App ID.
5. Create development and Developer ID profiles; install locally and confirm Xcode can select them.
6. Update the Approval Status table with request date, approval date, profile names, and renewal dates.
7. Configure GitHub Actions encrypted secrets for release signing and notarization (Task 16).

## Related Docs

- Plan: `docs/plans/2026-07-10-razer-only-remapping-and-hardening.md` (Tasks 1, 8, 16)
- Spike notes (after Task 8): `docs/testing/driverkit-spike.md`
