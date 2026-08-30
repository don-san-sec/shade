# quake

A fullscreen, §-toggle terminal. libghostty (Metal, GPU-rendered) core,
Rust logic, tiny ObjC shim for AppKit/Carbon. No tabs, no splits, no chrome.

Press `§` (the ISO section key left of `Z`, or `Option+6` which types `§`
on the British layout) or `Esc` to toggle. Fullscreen, no animation, covers
the menu bar, floats over fullscreen apps, follows the mouse's screen.

The dropdown runs your login shell. Your shell's own config attaches tmux
(e.g. fish: `exec tmux new-session -A -s main`), so sessions persist. The
surface is killed on hide and respawned on show. Detaching (`prefix d`)
auto-hides the panel.

Theme/font/keybinds come from your existing `~/.config/ghostty/config`
(the bundle ships ghostty's resources so `theme = ...` resolves, and
terminfo for `xterm-ghostty` is compiled in via `tic`).

## Config (optional)

`~/.config/quake/config`:

```
session=work              # run `tmux new-session -A -s work` instead of the shell
# or
command=htop              # any command; replaces the login shell entirely
```

Without these, quake spawns the login shell (whose config typically
attaches tmux).

## Prerequisites

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode NOT needed
- `brew install rust zig@0.15`

## Build / install / uninstall

```sh
git clone --recurse-submodules <this repo>
cd quake
make lib      # one-time: patched zig + ghostty patches + libghostty.a (~20-40 min)
make          # build Quake.app into build/
make run      # run without installing
make install  # /Applications/Quake.app + system login item (SMAppService)
make uninstall
```

`make install` registers quake with Background Task Management — it shows up
as a normal entry in System Settings → General → Login Items (toggleable
there), starts at login, and respawns if killed. `make uninstall` unregisters
it cleanly (no ghost entries left in the list).

`make lib` is slow once: it compiles libghostty from the vendored ghostty
source. Everything after is seconds. The vendored ghostty is pinned to
v1.3.1 with two build patches in `patches/` (applied automatically), and
the zig toolchain is copied into `build/zig` with a libcxx patch
(`tools/prepare-zig.sh`).

## Layout

- `src/main.rs` — libghostty lifecycle, event translation, toggle logic
- `src/ffi.rs` — libghostty C ABI bindings
- `src/shim.m` — AppKit panel/view, Carbon hotkey, clipboard, pasteboard
- `tools/fix-lib.sh` — rebuilds libghostty.a (works around Xcode 26+
  libtool dropping zig objects)
- `vendor/ghostty` — ghostty v1.3.1 (patched: xcframework/app build made
  optional for CLT-only hosts; metallib embedded from a prebuilt blob
  because CLT has no `metal` compiler)

## Notes / gotchas discovered

- Xcode CLT has no `metal`/`metallib` compilers: the build embeds a
  metallib extracted from an official Ghostty.app of the same version
  (see `QUAKE_METALLIB` in `src/build/SharedDeps.zig` patch).
- macOS 27 SDK `math.h` hides `INFINITY` under `-std=c++20`+; the vendored
  zig copy in `build/zig` has a one-line libcxx fallback patch.
- **macOS 26.3 RC / 26.4 beta / 27.0 beta regression**: genuinely
  `borderless` windows can never become key (Apple forums 814798/814875).
  quake uses a *titled* window with a fully hidden titlebar instead
  (titleVisibility hidden, transparent titlebar, hidden traffic lights,
  `fullSizeContentView`). Same look, working keyboard input.
- On macOS 14+ ("cooperative activation"), self-activation from a hotkey
  is only honored when requested via `NSRunningApplication.activateWithOptions:`,
  and it's async — the panel is (re)made key from
  `NSApplicationDidBecomeActiveNotification`.
- `RegisterEventHotKey` returns `paramErr` if you pass a NULL out-ref.
- Debug logging: `QUAKE_DEBUG=1` in the environment → unified log
  (`log show --predicate 'process == "Quake"'`).
- `GHOSTTY_RESOURCES_DIR` must be set before `ghostty_init` for
  `theme = ...` to resolve; the compiled terminfo must live at
  `Contents/Resources/terminfo` (sibling of `ghostty/`) because that is
  where libghostty points `TERMINFO`. Without it, tmux exits instantly
  with "missing or unsuitable terminal".
- Shell integration is disabled for the embedded surface
  (`~/.config/quake/ghostty-override`, written at startup) — pointless
  for a tmux dropdown and was implicated in early-exit debugging.
