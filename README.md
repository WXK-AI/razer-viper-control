<p align="center">
  <img src="docs/icon.png" alt="Razer Viper Control icon" width="128" height="128">
</p>

<h1 align="center">Razer Viper Control</h1>

<p align="center">
  Native macOS menu bar app for the <strong>Razer Viper V3 HyperSpeed</strong> (<code>1532:00B8</code>)
</p>

<p align="center">
  <strong>macOS 13+</strong> · <strong>Apple Silicon (arm64)</strong> · <strong>Swift 5.9</strong> · <strong>MIT License</strong>
</p>

<p align="center">
  Configure DPI, polling rate, profiles, and software input remapping — without Razer Synapse.
</p>

> **Disclaimer:** Community project — not affiliated with or endorsed by Razer Inc. Protocol behavior is based on [OpenRazer](https://github.com/openrazer/openrazer) documentation, implemented as fresh Swift over user-space `IOHID` feature reports.

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
2. Drag **RazerMenuBarApp** to the **Applications** folder (shortcut on the right).
3. Eject the disk image.
4. Open **Applications** and launch **RazerMenuBarApp**.
5. Grant **Input Monitoring** and **Accessibility** when prompted (Settings → Diagnostics has shortcuts).

### First launch and Gatekeeper

GitHub CI builds are **ad-hoc signed** (not notarized). macOS may block the first launch:

- **Right-click** the app → **Open** → **Open** again, or
- **System Settings → Privacy & Security** → **Open Anyway**

After the first successful launch, double-click works normally.

### Install (zip)

1. Download `RazerMenuBarApp-macOS.zip`, unzip, move **RazerMenuBarApp.app** to **Applications**.
2. Follow the Gatekeeper and permission steps above.

---

## Sign and notarize yourself (no Gatekeeper warning)

You **can** sign the app and DMG locally with an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year). This removes the “unidentified developer” warning for you and anyone you distribute the signed build to (after notarization).

```bash
# One-time: install your Developer ID Application certificate in Keychain Access.

export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="XXXXXXXXXX"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password

bash scripts/sign-release.sh
# Produces a signed + notarized build/Release/RazerMenuBarApp-macOS.dmg
```

The script:

1. Builds a Release `.app`
2. Signs the app with **Developer ID Application** + hardened runtime
3. Packages the DMG with drag-to-Applications layout
4. Signs the DMG
5. Submits to Apple **notarization** and staples the ticket

Upload that DMG to your own release or share directly — users can drag to Applications and open without right-click workarounds.

See [`scripts/sign-release.sh`](scripts/sign-release.sh) for the full flow.

---

## Quick start

1. Plug in the Razer Viper V3 HyperSpeed.
2. Open **Settings…** from the menu bar (⌘,).
3. On the **Profile** tab, set DPI stages and polling rate, then click **Apply Profile**.
4. On **Buttons** / **Wheel**, configure remaps as needed; enable **Enable software remapper**.
5. If remapping is active, grant **Input Monitoring** and **Accessibility**.

---

## Permissions

| Permission | Why it's needed |
|------------|-----------------|
| **Input Monitoring** | Read HID feature reports to apply DPI/polling and run diagnostics |
| **Accessibility** | Software button/scroll remapping via event tap |

Open **System Settings → Privacy & Security** and allow **RazerMenuBarApp** for both.

---

## Profiles

Stored locally at:

`~/Library/Application Support/RazerMenuBarApp/profiles-1532:00B8.json`

Each profile includes: name, DPI stages, active stage, polling rate, button mappings, wheel settings, remapper toggle, and auto-reapply flag.

---

## CLI (optional)

```bash
chmod +x RazerProbeCLI
./RazerProbeCLI list
./RazerProbeCLI battery
./RazerProbeCLI integration 1600 500
./RazerProbeCLI wheel-probe
./RazerProbeCLI input-capture 15
```

---

## Build from source

### Core + CLI

```bash
swift build
swift test --disable-sandbox
```

### Menu bar app

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make xcode
make test
make release-dmg    # unsigned release + DMG in build/Release/
```

---

## Project layout

| Path | Purpose |
|------|---------|
| `Sources/RazerCore/` | HID, remapper, profiles |
| `RazerMenuBarApp/` | Menu bar app + settings UI |
| `Sources/RazerProbeCLI/` | CLI probe tool |
| `scripts/` | Release build, DMG packaging, optional signing |
| `design/` | Icon and DMG artwork sources |
| `docs/` | README assets |

---

## Scope and limitations

- **Device:** Razer Viper V3 HyperSpeed (`1532:00B8`) only in v1
- **No** RGB, onboard profile save, or Mac App Store distribution
- **CI builds:** ad-hoc signed, arm64 only
- **Unofficial:** not affiliated with Razer Inc.

---

## Credits

- [OpenRazer](https://github.com/openrazer/openrazer) — device protocol
- [Viper V3 HyperSpeed PR](https://github.com/openrazer/openrazer/pull/2149)

---

## License

[MIT License](LICENSE) — Copyright (c) 2026 WXK-AI.

See [LICENSE](LICENSE) for full terms.
