# ChillPill — build + bundle targets.
#
# `make`           — debug build, assembles build/ChillPill.app, ad-hoc signs.
# `make release`   — release build (same, -c release).
# `make run`       — build, then open the .app.
# `make install`   — copy the .app into ~/Applications/.
# `make clean`     — drop build/ and .build/.
#
# No Homebrew dependencies. Relies only on `swift` (from Xcode Command Line
# Tools) and `codesign` (ships with macOS).

SWIFT    := swift
CONFIG   := debug
BUILD    := .build/$(CONFIG)
APP_DIR  := build
APP      := $(APP_DIR)/ChillPill.app
UI_BIN   := $(BUILD)/ChillPill
HLP_BIN  := $(BUILD)/ChillPillHelper

PLIST_UI     := Resources/Info.plist
PLIST_HELPER := Resources/dev.chillpill.helper.plist

.PHONY: all release run install clean compile bundle sign

all: bundle

release:
	$(MAKE) CONFIG=release bundle

compile:
	$(SWIFT) build -c $(CONFIG)

bundle: compile
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	@mkdir -p $(APP)/Contents/Library/LaunchDaemons
	@cp $(UI_BIN)  $(APP)/Contents/MacOS/ChillPill
	@cp $(HLP_BIN) $(APP)/Contents/MacOS/ChillPillHelper
	@cp $(PLIST_UI) $(APP)/Contents/Info.plist
	@cp $(PLIST_HELPER) $(APP)/Contents/Library/LaunchDaemons/dev.chillpill.helper.plist
	@$(MAKE) sign
	@echo ""
	@echo "  Built: $(APP)"
	@echo ""
	@echo "  First-time install:"
	@echo "    open $(APP)"
	@echo "    Then approve the helper in: System Settings → Login Items & Extensions."
	@echo ""

sign:
	@# Explicit identifiers so codesign doesn't auto-generate a
	@# hash-based one for the loose helper Mach-O — SMAppService matches
	@# the helper's signed identifier against the daemon plist's Label.
	@codesign --force --sign - --identifier dev.chillpill.helper $(APP)/Contents/MacOS/ChillPillHelper
	@codesign --force --sign - --identifier dev.chillpill.ChillPill $(APP)/Contents/MacOS/ChillPill
	@codesign --force --sign - --identifier dev.chillpill.ChillPill $(APP)

run: bundle
	@open $(APP)

install: release
	@mkdir -p $$HOME/Applications
	@rm -rf $$HOME/Applications/ChillPill.app
	@cp -R $(APP) $$HOME/Applications/
	@echo "  Installed: $$HOME/Applications/ChillPill.app"

clean:
	@rm -rf build .build
