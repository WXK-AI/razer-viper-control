# DriverKit Spike — Razer Viper V3 HyperSpeed (`1532:00B8`)

**Status: SCAFFOLD ONLY — physical acceptance incomplete.**  
Do not start Task 9+ remapper work until every acceptance row below is **PASS**.

## Goal

Prove a HID DriverKit system extension can be the sole owner of the Viper V3 HyperSpeed mouse/control path while leaving other pointing devices alone, supporting 90-byte feature-report round trips, and surviving unplug/replug and sleep/wake.

## Scaffold (in repo)

| Piece | Location |
|-------|----------|
| Driver target | `RazerHIDDriver/` + `project.yml` `RazerViperHIDDriver` |
| Matching | `VendorID=0x1532` (5426), `ProductID=0x00B8` (184), mouse `PrimaryUsagePage=1` / `PrimaryUsage=2` |
| Passthrough | `RazerHIDDriver::handleReport` → `super::handleReport` |
| Host activation | `RazerMenuBarApp/SystemExtensionManager.swift` |
| Entitlements | Candidate keys in host + driver plists; see `docs/driverkit-entitlements.md` |

## Prerequisites

1. Apple DriverKit entitlement group approved **or** DriverKit developer mode enabled for local spike only.
2. Host + driver App IDs / profiles selectable in Xcode.
3. Wire `CODE_SIGN_ENTITLEMENTS` in Xcode to:
   - `RazerMenuBarApp/RazerMenuBarApp.entitlements`
   - `RazerHIDDriver/RazerHIDDriver.entitlements`  
   (candidate keys; see `docs/driverkit-entitlements.md`).
4. Uncomment the `RazerViperHIDDriver` embed dependency in `project.yml`, set `DEVELOPMENT_TEAM`, regenerate with `bash scripts/generate-xcodeproj.sh`, and confirm a DriverKit App Development profile exists for `com.razermenubar.RazerViperHIDDriver`.
5. Physical Razer Viper V3 HyperSpeed (`1532:00B8`) plus a trackpad and a second USB/Bluetooth mouse.
6. Build/run a development- or Developer ID–signed app that embeds the dext (ad-hoc cannot activate for end users).

## Acceptance matrix

| # | Proof | Result | Evidence / notes |
|---|-------|--------|------------------|
| 1 | Extension activates via `OSSystemExtensionRequest` | PENDING | |
| 2 | Extension is the only event producer for the matched Viper interface (no duplicate pointer/button/scroll) | PENDING | |
| 3 | Trackpad remains on its normal driver | PENDING | |
| 4 | Second mouse remains on its normal driver | PENDING | |
| 5 | Passthrough covers motion, L/R/M, side buttons, DPI button (if emitted), vertical + horizontal wheel | PENDING | Record report IDs / button numbers |
| 6 | 90-byte feature-report set/get round trip while extension owns the device | PENDING | May require a second personality for the control interface |
| 7 | Dongle unplug/replug recovers without reboot/reinstall | PENDING | |
| 8 | Sleep/wake recovers without reboot/reinstall | PENDING | |

If any row fails: **stop**, revise matching/architecture, and do **not** restore a global `CGEvent` remapper fallback.

## Capture log (fill during physical run)

### Interface matching keys that actually matched

```
(pending)
```

### Input report descriptor summary

```
(pending — lengths, report IDs, button bits, wheel axes)
```

### Feature-report behavior under dext ownership

```
(pending — set/get status, dataSize observations vs docs/testing/response-datasize-policy.md)
```

### Duplicate-event / second-device observations

```
(pending)
```

## Operator steps

1. `make xcode` and run `RazerMenuBarApp` signed for system-extension development.
2. Diagnostics → **DriverKit spike** → Activate Driver.
3. Approve the extension in System Settings if prompted.
4. Exercise the acceptance matrix; paste evidence into this file.
5. Only after all rows are PASS, commit an update marking status **PASS** and proceed to Task 9.
