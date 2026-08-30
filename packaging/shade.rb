cask "shade" do
  version "0.1.0"
  sha256 "287b792743c4a3ddd4c489a2c76ed8d9a255ac1eaa0fd206a0970ddb572dddc6"

  url "https://github.com/don-san-sec/shade/releases/download/v#{version}/Shade-#{version}-macos-arm64.zip"
  name "Shade"
  desc "§-toggle, fullscreen, GPU-rendered drop-down terminal (libghostty)"
  homepage "https://github.com/don-san-sec/shade"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

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
