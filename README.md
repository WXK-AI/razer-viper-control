# Razer Viper V3 HyperSpeed Control (macOS)

Native Swift menu-bar app for the **Razer Viper V3 HyperSpeed** (`1532:00B8`). Protocol behavior is based on the [OpenRazer](https://github.com/openrazer/openrazer) documentation and driver semantics, implemented as fresh Swift using user-space `IOHID` feature reports.

## Targets

| Target | Purpose |
|--------|---------|
| `RazerCore` | HID discovery, 90-byte report codec, command client, profile storage |
| `RazerProbeCLI` | Diagnostics and safe integration read/write tests |
| `RazerMenuBarApp` | Menu-bar UI, settings window, profile reapply |

## Requirements

- macOS 13+
- **Full Xcode** (from the App Store) for `RazerMenuBarApp` and `swift test`
- Swift Command Line Tools are enough for `RazerCore` + `RazerProbeCLI`

## Build

### Core + CLI (Command Line Tools only)

```bash
swift build
swift run RazerProbeCLI list
swift run RazerProbeCLI integration 1600 500
```

### Menu bar app (requires full Xcode)

Command Line Tools provide `swift` and `clang`, but not `xcodebuild` or `XCTest`. Install **Xcode** from the App Store, then:

```bash
# One-time setup — use YOUR Xcode path (find with mdfind if needed)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# External drive example:
# sudo xcode-select -s /Volumes/Xk-Drive/Applications/Xcode.app/Contents/Developer

sudo xcodebuild -license accept   # if prompted

# Build (XcodeGen is already installed via Homebrew)
make xcode

# Launch the built app
make xcode-run
```

Or open `RazerViperControl.xcodeproj` in Xcode and run the **RazerMenuBarApp** scheme (⌘R).

### Unit tests

```bash
make test    # requires full Xcode
```

## CLI usage

```bash
swift run RazerProbeCLI list
swift run RazerProbeCLI battery
swift run RazerProbeCLI charging
swift run RazerProbeCLI dpi
swift run RazerProbeCLI stages
swift run RazerProbeCLI polling
swift run RazerProbeCLI integration 1600 500
```

## Permissions

If feature-report access is denied, open **System Settings → Privacy & Security → Input Monitoring** and allow the app. The settings UI includes a shortcut when permission errors are detected.

## Profiles

Profiles are stored as JSON in:

`~/Library/Application Support/RazerMenuBarApp/profiles-1532:00B8.json`

Fields: name, DPI stages, active stage, polling rate, auto-reapply flag. Local profiles are authoritative in v1; there is no onboard-memory save UI.

## v1 scope

- Battery, DPI, DPI stages, polling (125/500/1000 Hz)
- Transaction ID `0x1F`, ~60 ms response wait
- No RGB, macros, button remap, DriverKit, or background daemon

## References

- OpenRazer device support: [Viper V3 HyperSpeed PR](https://github.com/openrazer/openrazer/pull/2149)
- Packet layout: `driver/razercommon.h` in OpenRazer
- Command builders: `driver/razerchromacommon.c` in OpenRazer
