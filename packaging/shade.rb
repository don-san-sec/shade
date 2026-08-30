cask "shade" do
  version "0.1.0"
  sha256 "d8afb817f58e82dbece91aeeaf915549593ee1dbec8486fd19acd8a996481fa0"

  url "https://github.com/don-san-sec/shade/releases/download/v#{version}/Shade-#{version}-macos-arm64.zip"
  name "Shade"
  desc "One-key (Cmd+§) fullscreen, GPU-rendered drop-down terminal (libghostty)"
  homepage "https://github.com/don-san-sec/shade"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Shade.app"

  # Ad-hoc signed (no Developer ID): clear the quarantine bit so Gatekeeper
  # lets it launch. Remove this once the app is notarized.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Shade.app"]
  end

  uninstall launchctl: "dev.shade.app",
            delete:    [
              "/Applications/Shade.app",
              "~/Library/LaunchAgents/dev.shade.agent.plist",
            ]

  zap trash: "~/.config/shade"
end
