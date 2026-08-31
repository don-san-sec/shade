cask "shade" do
  version "0.2.2"
  sha256 "100fcf62954096d8a7e1e7a817d393d3b7a8762905f5f237bf61a36773a746d9"

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
