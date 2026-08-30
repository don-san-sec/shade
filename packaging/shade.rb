cask "shade" do
  version "0.2.1"
  sha256 "0e2e2f3f8d6cc9c2a5b99f4f68ae09c97596cbecdacd58771113008e8b63a546"

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
