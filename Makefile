# shade — §-toggle fullscreen libghostty terminal.

GHOSTTY   := vendor/ghostty
ZIG       := build/zig/bin/zig
METALLIB  := vendor/Ghostty.metallib
LIBFIXED  := build/libghostty-fixed.a
APP       := build/Shade.app
BIN       := $(APP)/Contents/MacOS/Shade
UID       := $(shell id -u)
AGENT     := $(HOME)/Library/LaunchAgents/dev.shade.agent.plist

.PHONY: all lib build install uninstall run clean

all: build

# One-time vendoring prep: patched zig toolchain + ghostty build patches.
build/.prepared:
	./tools/prepare-zig.sh
	cd $(GHOSTTY) && git apply ../../patches/ghostty-clt-build.patch
	touch $@

# Build libghostty.a from the vendored ghostty source, then rebuild the
# archive to work around Xcode 26+ libtool dropping zig objects.
lib: build/.prepared $(METALLIB)
	cd $(GHOSTTY) && SHADE_METALLIB=$(abspath $(METALLIB)) $(abspath $(ZIG)) build \
		-Doptimize=ReleaseFast -Demit-xcframework=false -Demit-macos-app=false
	./tools/fix-lib.sh $(LIBFIXED)

$(LIBFIXED):
	$(MAKE) lib

build: $(LIBFIXED)
	cargo build --release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources \
		$(APP)/Contents/Library/LaunchAgents
	cp target/release/shade $(BIN)
	cp assets/Info.plist $(APP)/Contents/Info.plist
	cp assets/dev.shade.agent.plist $(APP)/Contents/Library/LaunchAgents/
	cp -R $(GHOSTTY)/zig-out/share/ghostty $(APP)/Contents/Resources/ghostty
	mkdir -p $(APP)/Contents/Resources/terminfo
	tic -x -o $(APP)/Contents/Resources/terminfo \
		$$(find $(GHOSTTY)/.zig-cache -name ghostty.terminfo | head -1)
	codesign --force --sign - $(APP)

run: build
	$(BIN)

# Install: copy the app, install a raw LaunchAgent, start it.
# (SMAppService/BTM agents get launch-constraint-killed for ad-hoc signed
# apps on macOS 27 beta; a plain LaunchAgent is reliable and still shows
# under System Settings → Background App Activity.)
install: build
	-pkill -x Shade
	# Clean up any BTM-registered agent from the SMAppService experiment.
	-/Applications/Shade.app/Contents/MacOS/Shade --unregister-agent
	-launchctl bootout gui/$(UID)/dev.shade.app
	sleep 1
	rm -rf /Applications/Shade.app
	cp -R $(APP) /Applications/Shade.app
	sed 's#@BIN@#/Applications/Shade.app/Contents/MacOS/Shade#' \
		assets/dev.shade.agent.plist > $(AGENT)
	launchctl bootstrap gui/$(UID) $(AGENT)

uninstall:
	-launchctl bootout gui/$(UID)/dev.shade.app
	-pkill -x Shade
	-/Applications/Shade.app/Contents/MacOS/Shade --unregister-agent
	rm -f $(AGENT)
	rm -rf /Applications/Shade.app

clean:
	rm -rf target $(APP)
