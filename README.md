# shade

**A one-key dropdown terminal for macOS.** Press `Cmd+§` and a fullscreen,
GPU-rendered terminal drops over whatever you're doing. Press it again and
it's gone.

![shade running tmux](assets/screenshot.png)

shade is built on [Ghostty](https://ghostty.org)'s terminal engine (Metal,
GPU-rendered), wrapped in a tiny Rust + Objective-C shell. No tabs, no splits,
no window chrome — just your shell, instantly.

## Why shade?

- **One key, from anywhere** — `Cmd+§` (British/ISO) or ``Cmd+` `` (US)
  summons it on the screen your mouse is on. It floats over fullscreen apps
  and covers the menu bar.
- **Your shell, your sessions** — it runs your login shell, so your existing
  config attaches tmux (e.g. fish: `exec tmux new-session -A -s main`) and
  sessions persist between toggles. Detaching (`prefix d`) hides the panel.
- **Fast and quiet** — no animation, no blur, no Dock icon. Starts at login.
- **Ghostty-grade input** — same key translation as the Ghostty app, so
  `ctrl-[`, `ctrl-i` and friends reach tmux and vim intact.
- **Uses your Ghostty config** — theme, font and keybinds from
  `~/.config/ghostty/config` just work.

## Install

```sh
brew tap don-san-sec/tap
brew install --cask don-san-sec/tap/shade
```

Or grab `Shade-<version>-macos-arm64.zip` from
[Releases](../../releases), unzip, and move `Shade.app` to `/Applications`.

It's ad-hoc signed, so Gatekeeper warns on first launch. The Homebrew cask
handles this for you; a manual install needs one command:

```sh
xattr -dr com.apple.quarantine /Applications/Shade.app
```

**First launch** registers shade as a login item (so the toggle shortcut works
after reboot) — just open it once. No other setup.

## Use it

Show / hide with:

| Key | Layout |
|---|---|
| `Cmd+§` | British / ISO (the key left of `Z`) |
| ``Cmd+` `` | US / ANSI (the key left of `1`) |

Everything else is your normal shell and tmux.

- `Cmd+Q` hides the panel (dismisses the overlay) — it never quits the app
  and never kills your shell, so the tmux session persists. To end the shell
  deliberately, use `Ctrl+D`. (shade has no menu shortcuts, so `Cmd+C` /
  `Cmd+V` / `Cmd+A` all reach the terminal.)

Only one binding is registered, chosen by your physical layout — so on a
British board ``Cmd+` `` stays free for macOS's window cycling. Plain `§` is
deliberately not a toggle, so the `§` character stays typeable.

### Optional config

`~/.config/shade/config`:

```
session=work      # run `tmux new-session -A -s work` instead of the shell
# or
command=htop      # run any command instead of the shell
```

## How it works

- `src/main.rs` — libghostty lifecycle, key/mouse translation, toggle logic
- `src/shim.m` — the AppKit panel and the global hotkey
- `vendor/ghostty` — Ghostty's engine, pinned

## Credits

- [Ghostty](https://ghostty.org) (MIT) — the terminal engine and key handling.
- shade is MIT licensed — see `LICENSE`.
