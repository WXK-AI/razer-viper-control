# AGENTS.md

## Cursor Cloud specific instructions

### Platform requirement (read first)

This repository is a **macOS-only** project and **cannot be built, tested, or run on the Linux Cloud Agent VM**. There is no Linux/Docker fallback.

- `RazerCore` (a single SwiftPM module) unconditionally imports Apple-only system frameworks: `IOKit.hid`, `AppKit`, `CoreGraphics`, `ServiceManagement`, `ApplicationServices`. Because it is one module, *all* of its files must compile together, so even the pure-`Foundation` logic (`RazerReport`, `ProfileStore`) and its tests (`Tests/RazerCoreTests`) cannot be compiled on Linux.
- `RazerProbeCLI` depends on `RazerCore`, so it inherits the same limitation.
- `RazerMenuBarApp` is a SwiftUI/AppKit menu-bar app that requires **full Xcode** (`xcodebuild` + `XCTest`), generated via `xcodegen` (`make xcode`). None of these exist on Linux.
- There are **no `#if os(macOS)` guards**, so nothing degrades gracefully off-Apple platforms.
- CI (`.github/workflows/release.yml`) runs exclusively on `runs-on: macos-15`.

On Linux, `swift build` / `swift test` fail immediately with `error: no such module 'IOKit.hid'`. This is expected and is not a bug in the code or the environment setup.

### What the environment provides

The Swift 6.x toolchain is installed via [`swiftly`](https://www.swift.org/install/linux/) at `~/.local/share/swiftly/bin`, so the `swift` CLI is available for inspecting the package, syntax-checking pure-`Foundation` files in isolation, and reproducing the platform error above. If `swift` is missing on a fresh VM, reinstall it:

```bash
cd /tmp && curl -fsSL -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz \
  && tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init --assume-yes --quiet-shell-followup
# then add ~/.local/share/swiftly/bin to PATH for the current shell
export PATH="$HOME/.local/share/swiftly/bin:$PATH"
```

### Standard commands (must be run on macOS 13+)

These are documented in `README.md` and `Makefile`; do not duplicate them, just run them on a real Mac:

- Core + CLI (Command Line Tools enough): `swift build`, `swift run RazerProbeCLI list`
- Unit tests (needs full Xcode): `make test` (`swift test`)
- Menu-bar app (needs full Xcode + `xcodegen`): `make xcode`, then `make xcode-run`

### Working on this repo from a Linux Cloud Agent

You can edit and reason about the Swift source, but you cannot produce build/test/run evidence here. Any change that touches `RazerCore`, `RazerProbeCLI`, or `RazerMenuBarApp` must be validated on a macOS host (or macOS CI) before it can be considered verified.
