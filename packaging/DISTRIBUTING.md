# Distributing shade

shade is an **arm64-only, ad-hoc-signed** `.app`. That combination drives every
packaging choice below.

## The one decision that matters: signing

| | Ad-hoc (now) | Apple Developer ID ($99/yr) |
|---|---|---|
| Cost | free | paid |
| Download & run | Gatekeeper blocks it until `xattr -dr com.apple.quarantine` | opens cleanly |
| Homebrew cask | works, needs the `postflight` quarantine strip (already in `packaging/shade.rb`) | works, no strip needed |
| Notarization | n/a | `make notarize` |

If this stays a personal / small-audience tool, ad-hoc + the cask's
quarantine strip is fine. If you want strangers to install it without a
warning, you need the Developer ID program — there is no free workaround.

## Release flow

```sh
# 1. bump CFBundleShortVersionString in assets/Info.plist
# 2. build + zip + sha256
make package
# 3. create the GitHub release and attach the zip
git tag v0.1.0 && git push --tags
gh release create v0.1.0 dist/Shade-0.1.0-macos-arm64.zip
# 4. update version + sha256 in packaging/shade.rb (sha256 is printed by make package)
```

## Homebrew (recommended install UX)

Casks live in a separate **tap** repo, not this one. Create
`github.com/don-san-sec/homebrew-tap`, put `packaging/shade.rb` in its `Casks/`
dir, then users run:

```sh
brew tap don-san-sec/tap
brew install --cask shade
```

Why a cask (prebuilt binary) and not a formula (build from source):
`make lib` compiles libghostty from the vendored source and takes 20–40 min.
A cask installs the prebuilt app in seconds.

## What not to bother with

- **Mac App Store** — needs the paid program, and shade's private-API corner
  squaring + Carbon hotkey would likely be rejected anyway.
- **A source formula** — the 20–40 min libghostty build makes it a bad
  experience; only reconsider if the lib build ever gets fast.
- **A DMG** — a zip is simpler and `ditto`-produces a Gatekeeper-clean
  bundle; DMG adds nothing here.
