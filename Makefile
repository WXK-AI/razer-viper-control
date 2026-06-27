.PHONY: build test cli-list cli-integration xcode xcode-run check-xcode release-dmg

# Prefer default install, then common alternate locations (e.g. external drive).
XCODE_APP := $(firstword $(wildcard /Applications/Xcode.app) $(wildcard /Volumes/*/Applications/Xcode.app))
DEVELOPER_DIR := $(XCODE_APP)/Contents/Developer

build:
	swift build

test: check-xcode
	swift test

cli-list:
	swift run RazerProbeCLI list

cli-integration:
	swift run RazerProbeCLI integration 1600 500

# Menu bar app requires full Xcode (not Command Line Tools alone).
check-xcode:
	@if [ -z "$(XCODE_APP)" ] || [ ! -d "$(DEVELOPER_DIR)" ]; then \
		echo "error: Full Xcode is required to build RazerMenuBarApp."; \
		echo ""; \
		echo "  Install Xcode from the App Store, or ensure Xcode.app is at:"; \
		echo "    /Applications/Xcode.app"; \
		echo "    /Volumes/<YourDrive>/Applications/Xcode.app"; \
		echo ""; \
		echo "Then run:"; \
		echo "  sudo xcode-select -s /path/to/Xcode.app/Contents/Developer"; \
		echo "  make xcode"; \
		echo ""; \
		echo "RazerCore + RazerProbeCLI work with Command Line Tools only (swift build)."; \
		exit 1; \
	fi
	@if [ -n "$$(xcode-select -p 2>/dev/null)" ] && [ -d "$$(xcode-select -p 2>/dev/null)" ]; then \
		: ; \
	elif [ "$$(xcode-select -p 2>/dev/null)" != "$(DEVELOPER_DIR)" ]; then \
		echo "note: xcode-select is not pointing at your Xcode install."; \
		echo "Found: $(XCODE_APP)"; \
		echo "Run: sudo xcode-select -s $(DEVELOPER_DIR)"; \
		exit 1; \
	fi

xcode: check-xcode
	DEVELOPER_DIR="$(DEVELOPER_DIR)" bash scripts/xcode-build.sh

xcode-run: xcode
	open "build/DerivedData/Build/Products/Debug/RazerMenuBarApp.app"

release-dmg: check-xcode
	bash scripts/ci-release-build.sh
	bash scripts/package-dmg.sh
	@echo "Release artifacts in build/Release/"

sign-release: check-xcode
	bash scripts/sign-release.sh
