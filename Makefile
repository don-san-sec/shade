# quake — §-toggle fullscreen libghostty terminal.

GHOSTTY   := vendor/ghostty
ZIG       := build/zig/bin/zig
METALLIB  := vendor/Ghostty.metallib
LIBFIXED  := build/libghostty-fixed.a
APP       := build/Quake.app
BIN       := $(APP)/Contents/MacOS/Quake
UID       := $(shell id -u)
AGENT     := $(HOME)/Library/LaunchAgents/dev.quake.agent.plist

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
	cd $(GHOSTTY) && QUAKE_METALLIB=$(abspath $(METALLIB)) $(abspath $(ZIG)) build \
		-Doptimize=ReleaseFast -Demit-xcframework=false -Demit-macos-app=false
	./tools/fix-lib.sh $(LIBFIXED)

$(LIBFIXED):
	$(MAKE) lib

build: $(LIBFIXED)
	cargo build --release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources \
		$(APP)/Contents/Library/LaunchAgents
	cp target/release/quake $(BIN)
	cp assets/Info.plist $(APP)/Contents/Info.plist
	cp assets/dev.quake.agent.plist $(APP)/Contents/Library/LaunchAgents/
	cp -R $(GHOSTTY)/zig-out/share/ghostty $(APP)/Contents/Resources/ghostty
	mkdir -p $(APP)/Contents/Resources/terminfo
	tic -x -o $(APP)/Contents/Resources/terminfo \
		$$(find $(GHOSTTY)/.zig-cache -name ghostty.terminfo | head -1)
	codesign --force --sign - $(APP)

run: build
	$(BIN)

# Install: copy the app and open it once. The app registers its bundled
# agent with SMAppService (System Settings → Login Items → Quake) and BTM
# starts it. Also cleans up the legacy raw LaunchAgent from older installs.
install: build
	-pkill -x Quake
	# Unregister BEFORE replacing the bundle: BTM pins the agent to the
	# ad-hoc cdhash, so swapping binaries under a live registration gets
	# the job killed with a launch-constraint violation (EX_CONFIG).
	-/Applications/Quake.app/Contents/MacOS/Quake --unregister-agent
	-launchctl bootout gui/$(UID)/dev.quake.app
	sleep 1
	rm -f $(HOME)/Library/LaunchAgents/dev.quake.agent.plist
	rm -rf /Applications/Quake.app
	cp -R $(APP) /Applications/Quake.app
	# Open once to self-register the login item, then let the agent own it.
	open /Applications/Quake.app
	sleep 2
	-pkill -x Quake
	sleep 1
	launchctl kickstart gui/$(UID)/dev.quake.app

uninstall:
	-/Applications/Quake.app/Contents/MacOS/Quake --unregister-agent
	-pkill -x Quake
	-launchctl bootout gui/$(UID)/dev.quake.app
	rm -f $(HOME)/Library/LaunchAgents/dev.quake.agent.plist
	rm -rf /Applications/Quake.app

clean:
	rm -rf target $(APP)
