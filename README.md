# quake

**A one-key dropdown terminal for macOS.** Press `§` and a fullscreen,
GPU-rendered terminal drops over whatever you're doing. Press it again and
it's gone. That's the whole idea.

![quake running tmux](assets/screenshot.png)

quake wraps [libghostty](https://ghostty.org) (Metal, GPU-rendered) in a tiny
Rust + Objective-C shell — no tabs, no splits, no chrome, no settings pane.
It borrows Ghostty's own renderer and key handling, so your existing
`~/.config/ghostty/config` (theme, font, keybinds) just works.

## Why you might like it

- **One key, zero friction** — `§` (the ISO key left of `Z`) or `Option+6`
  (which types `§` on the British layout) summons it from anywhere, on the
  screen your mouse is on. It floats over fullscreen apps and covers the
  menu bar.
- **Your shell, your sessions** — the dropdown runs your login shell, so
  your own config attaches tmux (e.g. fish: `exec tmux new-session -A -s main`)
  and sessions persist across toggles. Detaching (`prefix d`) auto-hides
  the panel.
- **Fast and quiet** — no animation, no blur, no shadows; the surface is
  killed on hide and respawned on show. It registers as a normal login
  item, starts at login, and stays out of your Dock.
- **Ghostty-grade input** — key events are translated exactly the way
  Ghostty's own AppKit surface does, including fixterms CSI u encoding, so
  `ctrl-[`, `ctrl-i` and friends arrive intact in tmux and vim.

## Quick start

Prerequisites:

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode NOT needed
- `brew install rust zig@0.15`

```sh
git clone --recurse-submodules <this repo>
cd quake
make lib      # one-time: patched zig + ghostty patches + libghostty.a (~20-40 min)
make          # build Quake.app into build/
make run      # try it without installing
make install  # /Applications/Quake.app + login item
make uninstall
```

`make install` copies the app to `/Applications`, installs a LaunchAgent
(a plain agent is used because SMAppService/BTM entries get
launch-constraint-killed for ad-hoc signed apps on macOS 27 beta — it still
shows up under System Settings → General → Background App Activity), and
starts it. It respawns if killed.

`make lib` is slow once: it compiles libghostty from the vendored source.
Everything after is seconds.

## Config (optional)

`~/.config/quake/config`:

```
session=work              # run `tmux new-session -A -s work` instead of the shell
# or
command=htop              # any command; replaces the login shell entirely
```

Without these, quake spawns the login shell (whose config typically
attaches tmux).

## How it works

- `src/main.rs` — libghostty lifecycle, AppKit key/mouse event translation
  (mirroring Ghostty's own macOS surface), toggle logic
- `src/ffi.rs` — libghostty C ABI bindings
- `src/shim.m` — AppKit panel/view, Carbon global hotkey, clipboard
- `tools/fix-lib.sh` — rebuilds libghostty.a (works around Xcode 26+
  libtool dropping zig objects)
- `vendor/ghostty` — ghostty v1.3.1, pinned, with two build patches in
  `patches/` applied automatically
- The bundle ships Ghostty's resources so `theme = ...` resolves, and
  terminfo for `xterm-ghostty` is compiled in via `tic`

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
- Key translation detail: macOS delivers `ctrl-[` as a literal ESC
  character. Ghostty's macOS surface re-translates such events without
  control and passes the plain character as text, which the core encoder
  needs for fixterms CSI u sequences (`ctrl-[` → `ESC [ 91;5 u`). quake
  mirrors this in `event_text()` in `src/main.rs`.

## Credits

- [Ghostty](https://ghostty.org) by Mitchell Hashimoto & contributors
  (MIT) — the terminal core, renderer, and the event-translation logic
  quake borrows.
- quake itself: see `LICENSE`.
