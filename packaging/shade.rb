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

    # Install/preserve the raw LaunchAgent plist and restart shade. `open`
    # crosses the install-steps seatbelt boundary through LaunchServices;
    # invoking launchctl directly here is blocked with EIO. -n guarantees a
    # dedicated maintenance helper even when shade is already running.
    run "/usr/bin/open",
        args: ["-n", "-a", "{{appdir}}/Shade.app", "--args", "--install-agent"]
  end

  # Do not delete the LaunchAgent plist here: uninstall runs during every
  # upgrade, and the newly installed app needs the preserved plist to let
  # the already-loaded KeepAlive job restart it. A full zap removes it.
  zap trash: [
    "~/.config/shade",
    "~/Library/LaunchAgents/dev.shade.agent.plist",
  ]
end
