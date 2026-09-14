cask "shade" do
  version "0.2.4"
  sha256 "cfa82b3a1556ee57b64bc2eab6aa42d15ebb3beec19b32d52d41a3dcd14788d8"

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

  # NOTE: /Applications/Shade.app must NOT be in uninstall delete: — the
  # app stanza above already owns it. Listing it in both places makes
  # `brew upgrade` fail deterministically: the uninstall stanza deletes the
  # app before Homebrew backs it up to staging ("It seems the App source
  # ... is not there").
  uninstall launchctl: "dev.shade.app",
            delete:    [
              "~/Library/LaunchAgents/dev.shade.agent.plist",
            ]

  zap trash: "~/.config/shade"
end
