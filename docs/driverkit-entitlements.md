# DriverKit Entitlements And Signing Gates

This document tracks the Apple Developer Program prerequisites for Razer-only remapping via a HID DriverKit system extension. It intentionally omits certificates, credentials, and provisioning profile files.

**Status label:** All entitlement key names below are **candidate keys — unconfirmed until Apple approval**. Do not treat them as granted.

## Identifiers

| Target | Bundle ID | Notes |
|--------|-----------|--------|
| Host app | `com.razermenubar.RazerMenuBarApp` | Menu bar app; activates and talks to the extension |
| Driver extension | `com.razermenubar.RazerViperHIDDriver` | Sole owner of USB HID `1532:00B8` |

Team ID and signing identity are supplied at build time via CI secrets / local Keychain. Do not commit them.

## Required Entitlements

### Driver extension (`RazerViperHIDDriver`) — minimum spike set

Request (and ship for the ownership spike) only:

| Entitlement (candidate) | Purpose | Official docs |
|-------------------------|---------|---------------|
| `com.apple.security.app-sandbox` | Required by default DriverKit entitlement set | [docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox) |
| `com.apple.developer.driverkit` | DriverKit base | [docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit) |
| `com.apple.developer.driverkit.transport.hid` | HID transport matching | [docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.hid) |
| `com.apple.developer.driverkit.family.hid.eventservice` | HID event service | [docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.eventservice) |

### Deferred until implemented

Do **not** request or embed these until the corresponding code exists (Apple aborts activation on entitlement/implementation mismatch):

| Entitlement (candidate) | Add when |
|-------------------------|----------|
| `com.apple.developer.driverkit.family.hid.device` | HID device family service is implemented |
| `com.apple.developer.hid.virtual.device` | Virtual HID output is implemented |
| `com.apple.developer.driverkit.userclient-access` (host) | Driver exposes an `IOUserClient` |

Request guidance: [Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development).

### Host app (`RazerMenuBarApp`) — minimum spike set

| Entitlement (candidate) | Purpose | Official docs |
|-------------------------|---------|---------------|
| `com.apple.developer.system-extension.install` | Activate / deactivate the embedded DriverKit extension | [docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install) |

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
| DriverKit entitlement group request | **Not submitted** | Submit via Apple Developer → Certificates, Identifiers & Profiles; keys above are candidates only |
| System extension install entitlement on host App ID | **Not enabled** | Enable after App ID exists |
| `userclient-access` for driver bundle ID | **Deferred** | Add only when an IOUserClient exists |
| Development provisioning profiles selectable in Xcode | **Blocked** | Depends on entitlement approval |
| Distribution / notarization CI secrets | **Not configured** | Certificate, keychain password, profiles, Apple ID / app-specific password / Team ID |

Until the DriverKit entitlement group is approved, local work may use DriverKit developer mode for spike builds only. Ad-hoc signed builds cannot activate the extension for end users and are not a distributable substitute.

## Request Checklist (operator)

1. Confirm Team ID and Developer ID Application certificate in Keychain.
2. Register App IDs for host and driver if missing.
3. Request the DriverKit entitlement group listed above for the driver App ID (candidate keys; Apple may rename or subset).
4. Enable `com.apple.developer.system-extension.install` on the host App ID. Add `userclient-access` only when the driver exposes an IOUserClient.
5. Create development and Developer ID profiles; install locally and confirm Xcode can select them.
6. Update the Approval Status table with request date, approval date, **exact approved entitlement keys**, profile names, and renewal dates.
7. Configure GitHub Actions encrypted secrets for release signing and notarization (Task 16).

## Related Docs

- Plan: `docs/plans/2026-07-10-razer-only-remapping-and-hardening.md` (Tasks 1, 8, 16)
- Response `dataSize` policy: `docs/testing/response-datasize-policy.md`
- Spike notes (after Task 8): `docs/testing/driverkit-spike.md`
