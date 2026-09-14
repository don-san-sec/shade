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

  # NOTE: on stanza choice: the newer `postflight_steps` runs inside
  # Homebrew's seatbelt sandbox, which blocks launchctl's Mach IPC to
  # launchd (EIO) - fine for xattr, fatal for bootout/bootstrap of the
  # login agent. Classic flight blocks run unsandboxed, so postflight is
  # used here despite being the older DSL.

  postflight do
    # Ad-hoc signed (no Developer ID): clear the quarantine bit so
    # Gatekeeper lets it launch. Remove once the app is notarized.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Shade.app"]

    # An upgrade runs `uninstall` first, which boots the agent out - bring
    # it straight back so the new binary is running with no manual step.
    # Stray instances (e.g. GUI-launched while the agent was down) are
    # killed first, or the relaunched agent would lose the global hotkey to
    # them. The plist is created by the app's first launch (or `make
    # install`), not by this cask - on a fresh install before first launch
    # it does not exist yet, so tolerate failure.
    system_command "/bin/launchctl",
                   args:         ["bootout", "gui/#{Process.uid}", "dev.shade.app"],
                   must_succeed: false
    system_command "/usr/bin/pkill",
                   args:         ["-x", "Shade"],
                   must_succeed: false
    system_command "/bin/launchctl",
                   args:         ["bootstrap", "gui/#{Process.uid}",
                                  "#{Dir.home}/Library/LaunchAgents/dev.shade.agent.plist"],
                   must_succeed: false
  end

  # NOTE: /Applications/Shade.app must NOT be in uninstall delete: - the
  # app stanza above already owns it. Listing it in both places makes
  # `brew upgrade` fail deterministically: the uninstall stanza deletes the
  # app before Homebrew backs it up to staging.
  # The LaunchAgents plist is likewise NOT in uninstall delete: - uninstall
  # also runs on every `brew upgrade`, and deleting it there silently
  # killed the login agent on each upgrade until the app was relaunched by
  # hand. zap (the full wipe) removes it instead. Cost: a plain
  # `brew uninstall` leaves the plist and a running (or throttled-respawn)
  # agent behind, pointing at a removed app - `brew zap` clears it.

  zap trash: [
    "~/.config/shade",
    "~/Library/LaunchAgents/dev.shade.agent.plist",
  ]
end
