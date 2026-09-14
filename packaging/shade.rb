cask "shade" do
  version "0.2.5"
  sha256 "763c6c4ba897ef7238bf588a3a42c92a8b27ee28f4a8baaf530ccc4297bf741f"

  url "https://github.com/don-san-sec/shade/releases/download/v#{version}/Shade-#{version}-macos-arm64.zip"
  name "Shade"
  desc "One-key (Cmd+§) fullscreen, GPU-rendered drop-down terminal (libghostty)"
  homepage "https://github.com/don-san-sec/shade"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Shade.app"

  postflight_steps do
    # Ad-hoc signed (no Developer ID): clear the quarantine bit so
    # Gatekeeper lets it launch. Remove once the app is notarized.
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Shade.app"]

    # Install/preserve the raw LaunchAgent plist and restart shade. Invoke
    # the new binary directly: immediately after Homebrew replaces a bundle,
    # LaunchServices can resolve `open -a` to its stale removed executable
    # (kLSNoExecutableErr). The helper no longer calls launchctl, so it can
    # run inside this sandbox; explicitly allow its one home-directory write.
    run "{{appdir}}/Shade.app/Contents/MacOS/Shade",
        args: ["--install-agent"],
        writable_paths: ["Library/LaunchAgents"],
        writable_base: :home
  end

  # Do not delete the LaunchAgent plist here: uninstall runs during every
  # upgrade, and the newly installed app needs the preserved plist to let
  # the already-loaded KeepAlive job restart it. A full zap removes it.
  zap trash: [
    "~/.config/shade",
    "~/Library/LaunchAgents/dev.shade.agent.plist",
  ]
end
