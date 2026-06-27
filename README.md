# Razer Viper Control

Native macOS menu bar app for the **Razer Viper V3 HyperSpeed** (`1532:00B8`). Configure DPI, polling rate, profiles, and software input remapping without Razer Synapse.

**macOS 13+** · **Apple Silicon (arm64)** · **Swift 5.9**

> Community project — not affiliated with or endorsed by Razer Inc. Protocol behavior is based on [OpenRazer](https://github.com/openrazer/openrazer) documentation, implemented as fresh Swift over user-space `IOHID` feature reports.

---

## Download

Get the latest release from **[GitHub Releases](https://github.com/WXK-AI/razer-viper-control/releases)**.

| Asset | Purpose |
|-------|---------|
| `RazerMenuBarApp-macOS.dmg` | **Recommended** — drag-and-drop install |
| `RazerMenuBarApp-macOS.zip` | Alternate zip install |
| `RazerProbeCLI-macOS.zip` | Optional command-line diagnostics |
| `SHA256SUMS.txt` | Checksums for all release files |

---

## Features

- **Menu bar status** — battery %, charging state, active profile, DPI, polling rate, remapper state
- **Profiles** — multiple local profiles (JSON), quick switching, auto-reapply on reconnect
- **Hardware control** — DPI stages, active stage, polling rate (125 / 500 / 1000 Hz)
- **Software remapping** — per-button actions (mouse targets, shortcuts, URL, app launch, DPI/profile cycling)
- **Scroll tuning** — speed, direction, shift-to-scroll-horizontal, wheel up/down actions
- **Safety** — emergency remapper pause via **⌃⌥⌘R**; mapping warnings when primary clicks are unavailable
- **Diagnostics** — live input capture, wheel capability probe, permission shortcuts
- **Launch at login** — optional menu bar startup
- **CLI** — `RazerProbeCLI` for device probing and integration tests

---

## Install (DMG)

1. Download `RazerMenuBarApp-macOS.dmg` from [Releases](https://github.com/WXK-AI/razer-viper-control/releases) and open it.
2. Drag **RazerMenuBarApp** into **Applications**.
3. **First launch:** right-click the app → **Open** (bypasses Gatekeeper for ad-hoc signed builds).
4. Click the menu bar icon → **Settings…** and grant permissions when prompted (see below).
5. Connect your mouse, then click **Apply Profile** or enable **Auto-reapply profile on launch/reconnect**.

### Install (zip)

1. Download `RazerMenuBarApp-macOS.zip`, unzip, move **RazerMenuBarApp.app** to **Applications**.
2. Follow steps 3–5 above.

---

## Quick start

1. Plug in the Razer Viper V3 HyperSpeed.
2. Open **Settings…** from the menu bar (⌘,).
3. On the **Profile** tab, set DPI stages and polling rate, then click **Apply Profile**.
4. On **Buttons** / **Wheel**, configure remaps as needed; enable **Enable software remapper**.
5. If remapping is active, grant **Input Monitoring** and **Accessibility** (Diagnostics tab has shortcuts).

---

## Permissions

| Permission | Why it's needed |
|------------|-----------------|
| **Input Monitoring** | Read HID feature reports to apply DPI/polling and run diagnostics |
| **Accessibility** | Software button/scroll remapping via event tap |

Open **System Settings → Privacy & Security** and allow **RazerMenuBarApp** for both. The app surfaces shortcuts when permission errors are detected.

---

## Profiles

Stored locally at:

`~/Library/Application Support/RazerMenuBarApp/profiles-1532:00B8.json`

Each profile includes: name, DPI stages, active stage, polling rate, button mappings, wheel settings, remapper toggle, and auto-reapply flag. Profiles are authoritative on disk in v1; there is no onboard-memory save UI.

---

## CLI (optional)

```bash
chmod +x RazerProbeCLI
./RazerProbeCLI list
./RazerProbeCLI battery
./RazerProbeCLI charging
./RazerProbeCLI dpi
./RazerProbeCLI stages
./RazerProbeCLI polling
./RazerProbeCLI wheel
./RazerProbeCLI wheel-probe
./RazerProbeCLI input-capture 15
./RazerProbeCLI integration 1600 500
```

`input-capture` requires **Input Monitoring**. `integration` temporarily sets DPI and polling, then restores prior values.

---

## Build from source

### Requirements

- macOS 13+
- **Full Xcode** (App Store) for `RazerMenuBarApp` and unit tests
- Swift Command Line Tools suffice for `RazerCore` + `RazerProbeCLI` only

### Core + CLI

```bash
swift build
swift run RazerProbeCLI list
swift test --disable-sandbox
```

### Menu bar app

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make xcode        # build Debug app
make xcode-run    # launch built app
make test         # unit tests (requires Xcode)
```

Or open `RazerViperControl.xcodeproj` in Xcode and run the **RazerMenuBarApp** scheme.

### Local release + DMG

```bash
make release-dmg
# artifacts in build/Release/
```

---

## Project layout

| Path | Purpose |
|------|---------|
| `Sources/RazerCore/` | HID discovery, 90-byte report codec, command client, remapper, profiles |
| `RazerMenuBarApp/` | SwiftUI menu bar app and settings UI |
| `Sources/RazerProbeCLI/` | Command-line probe and integration tool |
| `scripts/` | CI release build and DMG packaging |
| `Tests/RazerCoreTests/` | Unit tests |
| `design/` | App icon source artwork |

---

## Scope and limitations

- **Supported device:** Razer Viper V3 HyperSpeed (`1532:00B8`) only in v1
- **Hardware wheel modes** (scroll mode, acceleration, smart reel) are probed but not supported on this mouse
- **No** RGB, onboard profile save, DriverKit, or Mac App Store distribution
- **Signing:** releases are ad-hoc signed; first launch requires right-click → Open
- **Platform:** CI builds **arm64** only; Intel Macs are not built in CI yet
- Transaction ID `0x1F`, ~60 ms response wait for feature reports

---

## Credits

- [OpenRazer](https://github.com/openrazer/openrazer) — device protocol and report layout
- [Viper V3 HyperSpeed support PR](https://github.com/openrazer/openrazer/pull/2149)
- Packet layout: `driver/razercommon.h` · Command builders: `driver/razerchromacommon.c`

---

## License

No license file is bundled yet. Treat as source-available community software until a license is added.
